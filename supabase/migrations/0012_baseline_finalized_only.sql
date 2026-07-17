-- ============================================================================
-- Moffy 追補マイグレーション (0012_baseline_finalized_only.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-07-16 / 起因: Codex 第5次レビュー (PR #55)
-- 準拠: docs/PRD.md §S4-2 / §S11 (基準値 = 当日を含まない直近window日平均・欠損除外)
--       supabase/migrations/0005_economy_exploit_fix.sql (C-2 fail-closed の原則)
--       supabase/migrations/0011_server_authoritative_finalize_date.sql (確定経路の一本化)
--
-- ----------------------------------------------------------------------------
-- 解決する問題（Codex 第5次レビュー #5）:
--   fn_finalize_day の基準値クエリは `is_anomaly = false` しか要求しておらず、
--   **未確定 (is_finalized=false) の行を平均の母集団に入れていた**。
--   直接 INSERT された行の既定値は is_finalized=false / is_anomaly=false なので、
--   注入行がそのまま基準値に効く。欠損日は除外される仕様のため、窓内に1行あれば
--   その値が平均そのものになる。total_minutes には非負制約しかないので、例えば
--   3360分の過去日を1行入れれば最大7日間、日次480pt上限まで加点を押し上げられた。
--
--   0011 で usage_daily への直接書込は剥奪したが、REVOKE は対象テーブルをロックしない
--   ため、権限検査を通過済みの INSERT が REVOKE 後にコミットする窓が残る。また 0011
--   適用**前**に注入された行は残り続ける。ACL だけでは塞ぎきれない。
--
--   ⇒ 本質的な修正は「未確定行を報酬計算の信頼済み入力として扱わない」こと。
--     これは 0005 の quest_condition_met が既に採用している C-2 fail-closed と同じ原則で、
--     fn_finalize_day 本体だけがこの原則から漏れていた（設計の内部矛盾）。
--
-- 適用前の既存行について（Codex #5c）:
--   無条件削除はしない（正当な行と不正な行を DB 列だけでは区別できず、本番データを
--   壊す）。本修正により、**未確定の注入行は削除せず安全に基準値から除外**される。
--   既に is_finalized=true の旧行が存在する場合は列だけでは判別不能なため、適用前に
--   バックアップ + 件数確認（下記の点検クエリ）を行い、区別不能なら削除せず 7日窓が
--   流れるのを待つ。本アプリは提出経路が未配線だった（クライアントは usage_daily に
--   一度も書いていない）ため、本番は実質空である**はず**だが、authenticated は REST を
--   直接呼べたので「空である」は実DBで確認するまで仮説にすぎない。
--
--   点検クエリ（適用前に手動実行して件数を確認する）:
--     select is_finalized, is_anomaly, count(*), min(usage_date), max(usage_date)
--       from public.usage_daily group by 1,2 order by 1,2;
--
-- 本ファイルの作り方（転記事故の防止）:
--   下記の関数定義は 0005 の fn_finalize_day を**スクリプトで機械的に抽出**し、基準値
--   クエリの1箇所だけを書き換えて生成した（手写ししていない）。差分は「is_finalized=true
--   の追加」とそのコメントのみ。
--
-- ⚠️ 0005 の末尾にあった `grant execute ... to authenticated` は**意図的に含めない**。
--    0011 で本体の直接実行権限は剥奪済みで、クライアントの入口は
--    fn_submit_and_finalize_day だけ。ここで再付与すると 0011 のガードが無効化される。
--    create or replace は既存 ACL を維持するが、再実行安全のため明示的に revoke する。
--
-- 冪等性: create or replace / revoke ＝ 再実行安全。
-- 前提: 0001〜0011 適用済み。**0011 より後に適用すること**。
-- ============================================================================

create or replace function public.fn_finalize_day(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid           uuid := auth.uid();
  v_tz            text;
  v_server_today  date;
  v_today_minutes integer;
  v_is_anomaly    boolean;
  v_minutes_max   integer;       -- daily_minutes_max (異常値しきい値)
  v_window_days   integer;
  v_floor_min     integer;
  v_ppm           integer;       -- point_per_minute
  v_cap           integer;       -- daily_point_cap
  v_raw_avg       numeric(8,2);
  v_sample_days   integer;
  v_applied_min   integer;
  v_stage         public.baseline_stage;
  v_reduced       integer;
  v_base_points   integer;
  v_mult          numeric;
  v_final_points  integer;
  v_capped        boolean := false;
  v_idem          text;
  v_rowcount      integer := 0;
  v_inserted      boolean := false;
  v_streak_cur    integer;
  v_streak_last   date;
  v_streak_after  integer;
  v_egg_result    jsonb := 'null'::jsonb;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  -- S11/S4: 日付境界の正は「サーバー時刻 + ユーザー登録TZ」。
  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid;
  if v_tz is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;
  v_server_today := (now() at time zone v_tz)::date;

  -- 遡及・未来加点不可 (S4-2): 未来日は拒否。
  if p_date > v_server_today then
    raise exception 'future_date_not_allowed' using errcode = '22023';
  end if;

  -- 当日 (= p_date) の利用生データ。未提出なら確定できない (端末からの提出が前提)。
  --   ★H4-1: is_anomaly はもはやクライアント申告ではない (G-4 で書込不可)。ここでは
  --   生データ total_minutes のみ読み、anomaly はサーバーが算出する (下記)。
  select total_minutes
    into v_today_minutes
    from public.usage_daily
   where user_id = v_uid and usage_date = p_date
   for update;   -- 行ロック (同時 finalize の競合防止)

  if not found then
    return jsonb_build_object('finalized', false, 'reason', 'no_usage_data');
  end if;

  -- SSOT 読み取り (マジックナンバー禁止)。
  v_minutes_max := public.cfg_int('daily_minutes_max', 1440);
  v_window_days := public.cfg_int('baseline_window_days', 7);
  v_floor_min   := public.cfg_int('baseline_floor_min', 30);
  v_ppm         := public.cfg_int('point_per_minute', 1);
  v_cap         := public.cfg_int('daily_point_cap', 480);

  -- ★H4-1 / S4-3 異常値: サーバー権威で anomaly を判定 (端末の自己申告を信用しない)。
  --   物理的にありえない値 (total_minutes > daily_minutes_max = 24h) は anomaly として
  --   確定しない。is_anomaly を definer 権限で書き込み記録する (列GRANT G-4 の対象外)。
  v_is_anomaly := (v_today_minutes > v_minutes_max);
  if v_is_anomaly then
    update public.usage_daily
      set is_anomaly = true
      where user_id = v_uid and usage_date = p_date;
    return jsonb_build_object('finalized', false, 'reason', 'anomaly');
  end if;

  -- 基準値 = 本日(p_date)を含まない直近 window 日平均 (欠損除外 / S11)。
  -- anomaly 日は分母からも除外する。
  select avg(total_minutes)::numeric(8,2), count(*)::integer
    into v_raw_avg, v_sample_days
    from public.usage_daily
   where user_id = v_uid
     and usage_date < p_date
     and usage_date >= p_date - v_window_days
     and is_anomaly = false
     -- ★0012 (Codex 第5次レビュー): サーバーが確定した日だけを基準値の母集団にする
     --   (fail-closed)。0011 適用前 / 適用時の権限切替レースで直接 INSERT された行は
     --   is_finalized=false のまま残り得る。旧実装はそれを平均に入れていたため、
     --   高い total_minutes の過去日を1行注入するだけで基準値が上がり、削減量が水増し
     --   されて加点できた (欠損日は除外されるので、窓内に1行あればその値が平均になる)。
     --   is_finalized は fn_finalize_day (definer) のみが立てるため偽造できない。
     --   quest_condition_met の C-2 fail-closed (0005) と同じ原則をここにも適用する
     --   (本体だけがこの原則から漏れていた = 設計の内部矛盾)。
     and is_finalized = true;

  -- S1 ウォームアップ: 実データ日数で stage を決定。
  if v_sample_days = 0 then
    v_stage := 'warmup';
  elsif v_sample_days < v_window_days then
    v_stage := 'provisional';
  else
    v_stage := 'confirmed';
  end if;

  -- 適用基準値: 平均を 30分でクランプ (§4-5 / S2)。warmup(データ無)は基準0扱い→削減0。
  if v_sample_days = 0 then
    v_applied_min := 0;
  else
    v_applied_min := greatest(round(v_raw_avg)::integer, v_floor_min);
  end if;

  -- 削減pt: max(0, baseline - today) * ppm。マイナス日は0 (S2)。
  v_reduced := greatest(v_applied_min - v_today_minutes, 0);
  v_base_points := v_reduced * v_ppm;

  -- ストリーク現状取得 (倍率算出のため。streaks 行が無ければ0)。
  select current_streak, last_progress_date
    into v_streak_cur, v_streak_last
    from public.streaks where user_id = v_uid
   for update;
  if not found then
    insert into public.streaks(user_id, current_streak, longest_streak)
      values (v_uid, 0, 0)
      on conflict (user_id) do nothing;
    v_streak_cur := 0;
    v_streak_last := null;
  end if;

  -- S14: 倍率は「今日を含めた到達段」で適用する (off-by-one 修正 / F-02)。
  if v_reduced > 0 then
    v_mult := public.streak_multiplier(v_streak_cur + 1);
  else
    v_mult := public.streak_multiplier(v_streak_cur);
  end if;

  -- 倍率適用 → 上限クランプ (S4,S14: 上限は倍率適用後の最終値で判定)。
  v_final_points := floor(v_base_points * v_mult)::integer;
  if v_final_points > v_cap then
    v_final_points := v_cap;
    v_capped := true;
  end if;

  -- baselines スナップショット (監査 / 再計算)。冪等 upsert。
  insert into public.baselines(
    user_id, baseline_date, raw_average_minutes, applied_minutes, sample_days, stage)
  values (v_uid, p_date, v_raw_avg, v_applied_min, v_sample_days, v_stage)
  on conflict (user_id, baseline_date) do update
    set raw_average_minutes = excluded.raw_average_minutes,
        applied_minutes     = excluded.applied_minutes,
        sample_days         = excluded.sample_days,
        stage               = excluded.stage;

  -- 冪等加算: idempotency_key = uid × date × 'reduction'。二重実行で2行目を作らない。
  v_idem := v_uid::text || ':' || p_date::text || ':reduction';

  if v_final_points > 0 then
    insert into public.point_ledger(
      user_id, ledger_date, source, amount, idempotency_key, meta)
    values (
      v_uid, p_date, 'reduction', v_final_points, v_idem,
      jsonb_build_object(
        'reduced_minutes', v_reduced,
        'baseline_minutes', v_applied_min,
        'today_minutes', v_today_minutes,
        'base_points', v_base_points,
        'multiplier', v_mult,
        'capped', v_capped,
        'stage', v_stage))
    on conflict (idempotency_key) do nothing;
    get diagnostics v_rowcount = row_count;
    v_inserted := (v_rowcount > 0);
    if v_inserted then
      update public.profiles
        set point_balance = point_balance + v_final_points
        where id = v_uid;
    end if;
  end if;

  -- usage_daily を確定済みに (再確定でも安全)。
  --   ★H4-1: is_anomaly はサーバーが正常と判定済みなので false を明示書込 (definer 権限)。
  --   is_finalized=true 化はサーバー専管 (列GRANT G-4 でクライアントは書けない)。
  update public.usage_daily
    set is_finalized = true,
        is_anomaly = false
    where user_id = v_uid and usage_date = p_date;

  -- ストリーク更新 (S2,S14): その日の削減プラス(reduced>0)なら継続、0/マイナスならリセット。
  if v_streak_last is distinct from p_date then
    if v_reduced > 0 then
      v_streak_after := v_streak_cur + 1;
      update public.streaks
        set current_streak = v_streak_after,
            longest_streak = greatest(longest_streak, v_streak_after),
            last_progress_date = p_date
        where user_id = v_uid;
    else
      v_streak_after := 0;
      update public.streaks
        set current_streak = 0,
            last_progress_date = p_date
        where user_id = v_uid;
    end if;
  else
    v_streak_after := v_streak_cur;
  end if;

  -- 連動: 確定ptをアクティブ卵へ反映 (新規確定時のみ / 二重反映しない)。
  if v_inserted and v_final_points > 0 then
    v_egg_result := public.fn_apply_growth(null, v_final_points, p_date);
  end if;

  return jsonb_build_object(
    'finalized', true,
    'points_awarded', case when v_inserted then v_final_points else 0 end,
    'base_points', v_base_points,
    'multiplier', v_mult,
    'baseline_minutes', v_applied_min,
    'reduced_minutes', v_reduced,
    'capped', v_capped,
    'stage', v_stage,
    'streak_after', v_streak_after,
    'egg_applied', v_egg_result,
    'already_finalized', not v_inserted and v_final_points > 0
  );
end;
$$;

-- 本体の直接実行権限は 0011 のまま維持する（create or replace は ACL を維持するが、
-- 0005 の末尾で grant していた経緯があるため、ここで明示的に revoke して固定する）。
revoke execute on function public.fn_finalize_day(date) from public, anon, authenticated;

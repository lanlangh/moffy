-- ============================================================================
-- 0016: 成長充当の冪等キーに「発生源」を含める (v1.1 / S5 = 消える削減ptの修復)
-- ============================================================================
-- 真因 (0002:404-405 / 第三者レビューで確定):
--   fn_apply_growth は控除(spend_incubation)の台帳キーを
--       uid × 暦日 × 'spend_incubation'
--   だけで作る。一方、**加算側のキーは発生源ごとに細粒度**である:
--       削減確定     … uid:D:reduction            (0012:160)
--       ウォームアップ … uid:warmup:N (日付非依存)   (0003:67)
--       クエスト報酬  … uid:period:quest:<id>      (0005)
--   そのため「同じ暦日に2つ以上の源からptが入る」と、2件目の控除記帳が
--   一意制約に弾かれ、fn_apply_growth は**卵を探す前に early return** する:
--
--       if not v_inserted then
--         return jsonb_build_object('applied_to','already_applied', ...);   -- 0002:414-417
--       end if;
--
--   ＝ 台帳には加算が載り point_balance も増えるのに、**卵の growth_points には
--   1ptも入らず、エラーも出ない**。ユーザーからは「ポイントは増えたのに卵が育たない」
--   に見える。
--
--   確定的に踏むシナリオ (新規ユーザー全員):
--     Day2 に fn_claim_warmup(2) が 300pt を付与 → 控除キー uid:2026-08-07:spend_incubation
--     同じ日に前日ぶんの削減確定が走る          → 控除キー uid:2026-08-07:spend_incubation ← 衝突
--     後から来たほうの pt が卵に届かず黙って消える。
--
-- 対処:
--   fn_apply_growth に p_source_key を追加し、控除キーを
--       coalesce(p_source_key, uid || ':' || date) || ':spend_incubation'
--   にする。**p_source_key を渡さなければ 0002 と完全に同じ文字列**になるため、
--   既存行と衝突せず、ロールバック地点にもなる。
--   呼び出し側は加算側で既に持っている冪等キー(v_idem)をそのまま渡す。
--
-- 既存データへの影響: **なし**。
--   * 台帳の書き換え・削除は一切しない。過去に消えたptの遡及補填もしない
--     (どの日に何が消えたかを事後に再構成すると二重付与のリスクがあるため)。
--   * profiles.point_balance / pooled_points を1ptも動かさない。
--     db-apply-v11.yml が適用の前後で全行を突き合わせて証跡を残す。
--   * 新旧キーは文字列として絶対に衝突しない
--     (旧 'uid:D:spend_incubation' vs 新 'uid:D:reduction:spend_incubation')。
--
-- ロールバック: 0002 の3引数版と 0012/0003 の元定義を create or replace で戻すだけ。
--
-- ⚠️ 本ファイルの3関数の本体は、既存マイグレーション
--    (0002 の fn_apply_growth / 0012 の fn_finalize_day / 0003 の fn_claim_warmup)
--    から**スクリプトで機械抽出**し、下記の該当行だけを置換して生成した。
--    手で転記していないので、既存ロジックの取りこぼしは無い。
--    置換したのは ★0016 と注記した箇所のみ。
--
-- 冪等: 関数は create or replace / drop は if exists / 権限は再実行安全。
-- 適用: .github/workflows/db-apply-v11.yml (0013→0014→0015→0016 の順)
-- 前提: 0001〜0015 適用済み。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. fn_apply_growth — p_source_key を追加した4引数版
--    (0002:376 の定義を機械抽出し、シグネチャと冪等キー生成のみ変更)
-- ----------------------------------------------------------------------------
create or replace function public.fn_apply_growth(
  p_egg_id uuid,
  p_points integer,
  p_date date default null,
  p_source_key text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_egg_id       uuid;
  v_growth_after integer;
  v_pooled_after integer;
  v_date         date;
  v_idem         text;
  v_rowcount     integer := 0;
  v_inserted     boolean := false;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  if p_points is null or p_points <= 0 then
    return jsonb_build_object('applied_to', 'none', 'reason', 'no_points');
  end if;

  v_date := coalesce(p_date, (now())::date);

  -- 控除台帳の冪等記録 (同日同源は1行)。先に台帳を立て、二重充当を防ぐ。
  -- ★0016: 発生源(p_source_key)をキーに含める。null なら 0002 と完全に同じ旧キー
  --   (= ロールバック地点 / 既存行と衝突しない)。
  v_idem := coalesce(p_source_key, v_uid::text || ':' || v_date::text)
            || ':spend_incubation';
  insert into public.point_ledger(
    user_id, ledger_date, source, amount, idempotency_key, meta)
  values (v_uid, v_date, 'spend_incubation', -p_points, v_idem,
          jsonb_build_object('reason', 'egg_growth'))
  on conflict (idempotency_key) do nothing;
  get diagnostics v_rowcount = row_count;
  v_inserted := (v_rowcount > 0);

  if not v_inserted then
    -- 同日分は既に充当済み (冪等)。状態だけ返す。
    return jsonb_build_object('applied_to', 'already_applied', 'date', v_date);
  end if;

  -- 対象卵: 明示指定 or アクティブ卵。
  if p_egg_id is not null then
    select id into v_egg_id from public.eggs
      where id = p_egg_id and user_id = v_uid
        and location = 'incubating'
      for update;
  else
    select id into v_egg_id from public.eggs
      where user_id = v_uid and is_active = true
        and location = 'incubating'
      for update;
  end if;

  if v_egg_id is not null then
    update public.eggs
      set growth_points = growth_points + p_points
      where id = v_egg_id
      returning growth_points into v_growth_after;
    return jsonb_build_object(
      'applied_to', 'egg', 'egg_id', v_egg_id, 'growth_after', v_growth_after);
  else
    -- S6: アクティブ卵なし → プールへ (最大日数の管理は表示側 + 充当時調整。
    --     ここでは取りこぼし防止のため単純加算)。
    update public.profiles
      set pooled_points = pooled_points + p_points
      where id = v_uid
      returning pooled_points into v_pooled_after;
    return jsonb_build_object(
      'applied_to', 'pool', 'pooled_after', v_pooled_after);
  end if;
end;
$$;

-- 旧3引数版を撤去する。4引数版は p_source_key/p_date にデフォルトを持つので、
-- 既存の3引数呼び出し fn_apply_growth(egg, pts, date) はそのまま4引数版に解決される
-- (両方が存在すると解決が紛らわしくなるため1本に統一する)。
drop function if exists public.fn_apply_growth(uuid, integer, date);

-- 内部専用 (0002:869 と同方針。クライアントには公開しない)。
revoke all on function public.fn_apply_growth(uuid, integer, date, text)
  from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. fn_finalize_day — 削減確定ぶんの控除キーを uid:D:reduction 系にする
--    (0012 の定義を機械抽出し、fn_apply_growth 呼び出し1行のみ変更)
-- ----------------------------------------------------------------------------
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
    -- ★0016: 削減確定ぶんの控除キーを加算側と同じ粒度にする (v_idem = uid:D:reduction)。
    v_egg_result := public.fn_apply_growth(null, v_final_points, p_date, v_idem);
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

-- ⚠️ 0012:288 の剥奪を必ず再掲する。create or replace は ACL を保持するが、
--    0002:876 が authenticated に grant しているため、ここを書き忘れると
--    「本体を直接呼んで任意の過去日を確定させる」経路 (0011 の日付境界ガード迂回) が
--    復活する。
revoke execute on function public.fn_finalize_day(date)
  from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. fn_claim_warmup — ウォームアップ付与の控除キーを uid:warmup:N にする
--    (0003 の定義を機械抽出し、fn_apply_growth 呼び出し1行のみ変更)
--
--    副次的な効果: 0003 のヘッダが自認している「Day1 と Day2 が同じサーバー暦日に
--    落ちると2回目の充当が効かない」問題も、これで同時に解消する
--    (キーが日付ではなく day 番号ベースになるため)。
-- ----------------------------------------------------------------------------
create or replace function public.fn_claim_warmup(p_day integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_tz           text;
  v_today        date;
  v_grants       jsonb;
  v_grant        integer;
  v_idem         text;
  v_rowcount     integer := 0;
  v_inserted     boolean := false;
  v_egg_id       uuid;
  v_has_active   boolean;
  v_balance      integer;
  v_egg_result   jsonb := 'null'::jsonb;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  if p_day is null or p_day not in (1, 2) then
    raise exception 'invalid_warmup_day' using errcode = '22023';
  end if;

  -- ユーザーTZの暦日 (台帳 ledger_date 用 / S11)。
  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid;
  if v_tz is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;
  v_today := (now() at time zone v_tz)::date;

  -- SSOT: 付与額を app_config.warmup_grants から読む (マジックナンバー禁止)。
  v_grants := public.cfg('warmup_grants', '{"day1":200,"day2":300}'::jsonb);
  if p_day = 1 then
    v_grant := coalesce((v_grants->>'day1')::integer, 0);
  else
    v_grant := coalesce((v_grants->>'day2')::integer, 0);
  end if;

  -- 初回ボーナス卵を先に確保する (付与pt の充当先)。
  -- starter 卵が既にあれば再生成しない。無く、かつアクティブ卵も無い場合のみ生成。
  select id into v_egg_id
    from public.eggs
   where user_id = v_uid and acquired_source = 'starter'
   limit 1;

  if v_egg_id is null then
    select exists(
      select 1 from public.eggs where user_id = v_uid and is_active = true
    ) into v_has_active;

    if not v_has_active then
      -- 冪等生成: uq_eggs_one_active (部分一意) と uq_eggs_slot に整合する形で1個だけ作る。
      insert into public.eggs(
        user_id, rarity, location, slot_index, is_active, acquired_source)
      values (
        v_uid, 'normal', 'incubating', 1, true, 'starter')
      returning id into v_egg_id;
    end if;
  end if;

  -- 冪等付与: 生涯1回キー = uid × 'warmup' × day (日付を使わない)。
  v_idem := v_uid::text || ':warmup:' || p_day::text;

  if v_grant > 0 then
    insert into public.point_ledger(
      user_id, ledger_date, source, amount, idempotency_key, meta)
    values (
      v_uid, v_today, 'warmup', v_grant, v_idem,
      jsonb_build_object('day', p_day))
    on conflict (idempotency_key) do nothing;
    get diagnostics v_rowcount = row_count;
    v_inserted := (v_rowcount > 0);

    if v_inserted then
      -- 初回のみ残高反映 (point_balance は導出キャッシュ。台帳が真)。
      update public.profiles
        set point_balance = point_balance + v_grant
        where id = v_uid
        returning point_balance into v_balance;

      -- 付与pt を starter 卵へ充当 (= 卵成長へ積む / S1)。
      -- fn_apply_growth は対象卵明示 (v_egg_id) で incubating の卵へ加算する。
      if v_egg_id is not null then
        -- ★0016: v_idem = uid:warmup:N (日付非依存の生涯1回キー)。これにより
        --   Day1/Day2 が同じ暦日に落ちても互いを打ち消さない。
        v_egg_result := public.fn_apply_growth(v_egg_id, v_grant, v_today, v_idem);
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'claimed', true,
    'day', p_day,
    'granted', case when v_inserted then v_grant else 0 end,
    'egg_id', v_egg_id,
    'egg_applied', v_egg_result,
    'balance_after', v_balance,
    'already_claimed', (v_grant > 0 and not v_inserted));
end;
$$;

-- fn_claim_warmup の権限は 0003 のまま (authenticated が呼ぶ入口)。
-- create or replace は ACL を保持するため再付与は不要だが、初適用環境との
-- 差異を無くすために明示する。
grant execute on function public.fn_claim_warmup(integer) to authenticated;

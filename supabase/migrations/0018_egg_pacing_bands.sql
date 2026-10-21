-- ============================================================================
-- 0018: たまごの孵化ペースと5段階の見た目（評価制 ◎/○/△・計測なし・R・2日目「残り全部」）
-- ============================================================================
-- 仕様: docs/design/EGG_PACING_DESIGN.md（§2 評価 / §3 数値 / §5 移行 / §6 変更範囲）
-- 前提: docs/design/EGG_PACING_REDESIGN.md（現状の式と数字はコードで確認済み）
--
-- 何を変えるか（オーナー決定 2026-10-21）:
--   * 数え方を「前の週より何分減らしたか（変化）」から「ふだんよりどれだけ離れていたか
--     （状態）」へ。基準 R = 「ふだんのSNS時間」は本人申告（30/60/120/180/300 分・既定 120）。
--     実測で**上げる方向にだけ**直す（計測ありの確定日が 7 日たまったら直近 7 日の中央値）。
--     → 減らした状態が続く限り、毎日報われる。
--   * 1日の評価: ◎ (m <= max(30, R/2)) = 100pt / ○ (m <= max(60, R*3/4)) = 70pt /
--     △ = 15pt / 計測なし = 0pt（卵は進まない・連続日数は据え置き）。
--   * 孵化は 500pt のまま。段階の区切りは 0/100/200/300/500（egg_thresholds.stages）。
--     既存の卵は**換算しない**（しきい値が変わらないので移行SQLは不要 / §5-1）。
--   * 連続倍率は廃止（×1.0 固定）。連続日数の表示とクエスト streak_keep は残る。
--   * 初回ボーナス: 1日目 300 → 2日目「孵化までの残り全部」（初回ボーナス卵が育成中なら）。
--     初日の 200pt で止まっている既存ユーザーの卵も、次に開いた日に残り 300 が入って孵る。
--   * 「計測なし」を usage_daily.is_measured で明示する（iOS で対象アプリ未選択の
--     「永久0分」から出続けていた幻の 30pt/日が消える）。
--
-- 変更一覧:
--   DDL   profiles.usual_minutes / usual_minutes_source / usual_minutes_updated_at
--         usage_daily.is_measured（default true = 既存行は計測あり扱い）
--   設定  app_config: egg_thresholds(+stages) / daily_bands / usual_minutes_default /
--         usual_minutes_choices / warmup_grants / streak_multipliers / daily_point_cap
--   関数  fn_submit_and_finalize_day(+p_is_measured) … 0011 版を抽出して置換
--         fn_finalize_day（評価制）                     … 0016 版を抽出して置換
--         fn_claim_warmup（2日目=残り全部・生涯合計は hatch まで・行ロック）… 0016 版を抽出して置換
--         quest_condition_met（reduce_total の計測なし判定 → is_measured）… 0015 版を抽出して置換
--         fn_set_usual_minutes（新設 / 本人申告の保存）
--
-- ⚠️ このファイルは tools/db/gen_migration_0018.py が生成する。
--    既存関数の本体は 0011 / 0015 / 0016 からスクリプトで機械抽出し、★0018 と注記した
--    箇所だけを置換した（手で転記していない）。直すときはスクリプトを直して再生成する。
--
-- 既存データへの影響:
--   * 台帳・残高・卵の growth_points は**1行も書き換えない**（データ行への UPDATE は無い。
--     add column の default による埋めのみ）。
--   * 古いアプリ（1.2.1）との共存: fn_submit_and_finalize_day の新引数にはデフォルトがあり、
--     4引数の既存呼び出しはそのまま通る（PostgREST は同名の関数が1本なら既定値で解決する。
--     **そのため旧4引数版は drop する**＝2本並ぶと呼び出しが曖昧になる）。
--     egg_thresholds の新キー stages は古いアプリに無視される。hatch は 500 のまま。
--   * 適用の順序: **アプリ更新と同時に当てる**（§5-3）。値だけ先に当てると、古いアプリの
--     端末側の暫定表示（分×倍率）が確定値と食い違う期間が長くなるだけで、確定値は常にこの
--     サーバーが正。逆にアプリだけ先に出すと、新アプリが送る p_is_measured が無い関数に
--     当たって提出が失敗する（PostgREST が未知の引数名を 404 にする）ため、**DB が先**。
--
-- ロールバック手順（この順で実行すること）:
--   ① drop function if exists public.fn_set_usual_minutes(integer);
--   ② drop function if exists public.fn_submit_and_finalize_day(date, integer, jsonb, text, boolean);
--      → 0011 の4引数版 fn_submit_and_finalize_day を create or replace で復元し、
--        revoke all from public, anon, authenticated → grant execute to authenticated を再実行
--   ③ 0016 の fn_finalize_day / fn_claim_warmup を create or replace で復元
--      → revoke execute on function public.fn_finalize_day(date) from public, anon, authenticated;
--        （0002 が grant しているので、復元しただけだと剥奪が外れる / 0016 末尾の注意）
--   ④ 0015 の quest_condition_met を create or replace で復元
--   ⑤ app_config を戻す:
--        egg_thresholds     = {"crack1":100,"crack2":250,"hatch":500}
--        warmup_grants      = {"day1":200,"day2":300}
--        streak_multipliers = [{"days":1,"mult":1.0},{"days":3,"mult":1.2},{"days":7,"mult":1.5},{"days":30,"mult":2.0}]
--        daily_point_cap    = 480
--        daily_bands / usual_minutes_default / usual_minutes_choices は delete してよい（旧関数は読まない）
--   ⑥ 追加した列（profiles.usual_minutes* / usage_daily.is_measured）は残して無害
--      （旧関数は読まない。消すなら alter table ... drop column）。
--
-- 冪等: add column if not exists / create or replace / drop if exists / on conflict do update /
--       revoke・grant は再実行安全。
-- 適用: .github/workflows/db-apply-0018.yml（手動 / 1トランザクション / 適用前スナップショット）
-- 前提: 0001〜0017 適用済み。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. DDL
-- ----------------------------------------------------------------------------
-- R = ふだんのSNS時間（分）。null = 未申告（関数側で usual_minutes_default に倒す）。
alter table public.profiles
  add column if not exists usual_minutes integer
    check (usual_minutes is null or usual_minutes > 0);
alter table public.profiles
  add column if not exists usual_minutes_source text not null default 'default'
    check (usual_minutes_source in ('default', 'reported', 'measured'));
alter table public.profiles
  add column if not exists usual_minutes_updated_at timestamptz;

comment on column public.profiles.usual_minutes is
  '0018: ふだんのSNS時間(分)。本人申告(reported)→実測で上方修正のみ(measured)。null=未申告';
comment on column public.profiles.usual_minutes_source is
  '0018: usual_minutes の出どころ。default / reported / measured';

-- その日を評価してよいか。false = 権限なし / iOS で対象アプリ未選択 / 古い iOS アプリ。
-- 既存行は true（計測あり扱い）。0pt の既存日を遡って消すことはしない。
alter table public.usage_daily
  add column if not exists is_measured boolean not null default true;

comment on column public.usage_daily.is_measured is
  '0018: 計測できていた日か。false の日は 0pt・卵は進まない・連続日数は据え置き';

-- 列権限: profiles の新列はクライアントから書けない（0011 で UPDATE は display_name のみ /
-- INSERT は剥奪済み）。読むのは本人 select で可。usage_daily は 0011 で書込全面剥奪済み。


-- ----------------------------------------------------------------------------
-- 2. app_config（設計書 §3-4）
-- ----------------------------------------------------------------------------
insert into public.app_config (key, value, description) values
  ('egg_thresholds',
    '{"crack1":100,"crack2":250,"stages":[0,100,200,300,500],"hatch":500}'::jsonb,
    '§4-5 卵成長しきい値(累積pt)。stages=5段階の区切り(0018)。crack1/2 は古いアプリ向けに残す'),
  ('daily_bands',
    '{"great":{"abs_min":30,"ratio":0.5,"points":100},"good":{"abs_min":60,"ratio":0.75,"points":70},"poor":{"points":15}}'::jsonb,
    '0018 1日の評価。great: m<=max(abs_min,R*ratio) / good: 同 / poor: それ以外。points は卵に入るpt'),
  ('usual_minutes_default', '120'::jsonb,
    '0018 未申告ユーザーの「ふだんのSNS時間」(分)'),
  ('usual_minutes_choices', '[30,60,120,180,300]'::jsonb,
    '0018 本人申告の選択肢(分)。iOS のしきい値と同じ刻み。fn_set_usual_minutes が検証に使う'),
  ('warmup_grants', '{"day1":300,"day2":200}'::jsonb,
    'S1 初回ボーナス。day1=固定 / day2=初回ボーナス卵が無いときの値(育成中なら孵化までの残り全部 / 0018)'),
  ('streak_multipliers', '[{"days":1,"mult":1.0}]'::jsonb,
    'S14 ストリーク倍率。0018 で廃止(全段×1.0)。連続日数の表示とクエストは残る'),
  ('daily_point_cap', '100'::jsonb,
    'S4 1日ポイント上限。0018: ◎の100pt と同値')
on conflict (key) do update
  set value = excluded.value,
      description = excluded.description,
      updated_at = now();


-- ----------------------------------------------------------------------------
-- 3. fn_set_usual_minutes — 本人申告の保存（新設）
-- ----------------------------------------------------------------------------
-- 選択肢（usual_minutes_choices）の値だけを受け付ける。source は 'reported'。
-- 実測で 'measured' に上がった後に再申告すると 'reported' に戻る（Phase 3 の設定画面用）。
create or replace function public.fn_set_usual_minutes(p_minutes integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_choices jsonb;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  v_choices := public.cfg('usual_minutes_choices', '[30,60,120,180,300]'::jsonb);
  if p_minutes is null
     or not exists (
       select 1 from jsonb_array_elements_text(v_choices) e
        where e::integer = p_minutes) then
    raise exception 'invalid_usual_minutes' using errcode = '22023';
  end if;

  update public.profiles
     set usual_minutes = p_minutes,
         usual_minutes_source = 'reported',
         usual_minutes_updated_at = now()
   where id = v_uid;
  if not found then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'usual_minutes', p_minutes,
    'usual_minutes_source', 'reported');
end;
$$;

revoke all on function public.fn_set_usual_minutes(integer) from public, anon, authenticated;
grant execute on function public.fn_set_usual_minutes(integer) to authenticated;


-- ----------------------------------------------------------------------------
-- 4. fn_submit_and_finalize_day — p_is_measured を追加（0011 版を機械抽出して置換）
-- ----------------------------------------------------------------------------
-- 旧4引数版は drop する（同名2本だと PostgREST の解決が曖昧になる）。4引数の既存呼び出しは
-- 新版のデフォルト（null → source_mode で決める）で通る。
drop function if exists public.fn_submit_and_finalize_day(date, integer, jsonb, text);

create or replace function public.fn_submit_and_finalize_day(
  p_date            date,
  p_total_minutes   integer,
  p_per_app_minutes jsonb,
  p_source_mode     text,
  p_is_measured     boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_tz           text;
  v_server_today date;
  v_target       date;
  v_finalized    boolean;
  v_measured     boolean;   -- ★0018: その日を評価してよいか（計測できていたか）
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid;
  if v_tz is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;
  v_server_today := (now() at time zone v_tz)::date;
  v_target := v_server_today - 1;

  -- ★#1: 対象日はサーバー権威。クライアント申告と一致しなければ拒否する。
  --   (a) 当日・未来日 → 進行中の日を確定できない（削減量は時間とともに減るだけなので、
  --       朝に確定すると満額を取ってその後使い放題になる）。
  --   (b) 前日より古い日 → 遡及加点不可（PRD §S4-2）。
  --   日跨ぎでズレた場合もここで弾かれ、クライアントは次回の起動/復帰で正しい日を再取得する。
  if p_date is distinct from v_target then
    return jsonb_build_object(
      'finalized', false,
      'reason', 'wrong_finalize_date',
      'target_date', v_target
    );
  end if;

  -- 入力検証（CHECK 制約違反を例外ではなく理由付きの戻りにする＝クライアントが再試行地獄に
  -- 陥らないように）。
  if p_total_minutes is null or p_total_minutes < 0 then
    return jsonb_build_object('finalized', false, 'reason', 'invalid_total_minutes');
  end if;
  if p_source_mode is null
     or p_source_mode not in ('exact-minutes', 'threshold-achievement') then
    return jsonb_build_object('finalized', false, 'reason', 'invalid_source_mode');
  end if;

  -- ★0018: 計測できていたか。新しいアプリは明示で送る（iOS = 対象アプリ選択済みか、
  --   Android = true）。送ってこない古いアプリは source_mode で決める:
  --     exact-minutes（Android）     … 分が正確なので計測あり
  --     threshold-achievement（iOS） … 対象未選択の「永久0分」と区別できないので計測なし
  --                                   （fail-closed。更新後のアプリは選択済みなら true を送る）
  v_measured := coalesce(p_is_measured, p_source_mode = 'exact-minutes');

  -- ★#4: 生データ書込は definer 権限のサーバー側で行う（列GRANT の非対称を回避）。
  --   まず行を確実に存在させる（競合時は何もしない＝後段のロックで直列化する）。
  insert into public.usage_daily(
    user_id, usage_date, total_minutes, per_app_minutes, source_mode, is_measured)
  values (
    v_uid, v_target, p_total_minutes,
    coalesce(p_per_app_minutes, '{}'::jsonb), p_source_mode, v_measured)
  on conflict (user_id, usage_date) do nothing;

  -- ★#3/#5: 行ロックを取ってから確定判定する（原子的）。
  --   READ COMMITTED では、先行トランザクションのコミット待ちで解除された後に
  --   最新版で WHERE を再評価するため、後発の要求は is_finalized=true を読む。
  select is_finalized into v_finalized
    from public.usage_daily
   where user_id = v_uid and usage_date = v_target
   for update;

  if v_finalized then
    -- 確定済み日の生データは上書きしない（確定値の再計算・streak 巻き戻しを防ぐ）。
    return jsonb_build_object(
      'finalized', true,
      'already_finalized', true,
      'points_awarded', 0,
      'reason', 'already_finalized'
    );
  end if;

  -- 未確定なら生データを最新値へ更新（definer / 生データ列のみ）。
  update public.usage_daily
     set total_minutes   = p_total_minutes,
         per_app_minutes = coalesce(p_per_app_minutes, '{}'::jsonb),
         source_mode     = p_source_mode,
         is_measured     = v_measured
   where user_id = v_uid and usage_date = v_target;

  -- 本体へ委譲（同一トランザクション＝行ロック保持のまま）。
  -- 基準値・ウォームアップ判定・倍率・上限・冪等加算・異常値判定はすべて本体の責務。
  return public.fn_finalize_day(v_target);
end;
$$;

revoke all on function public.fn_submit_and_finalize_day(date, integer, jsonb, text, boolean)
  from public, anon, authenticated;
grant execute on function public.fn_submit_and_finalize_day(date, integer, jsonb, text, boolean)
  to authenticated;


-- ----------------------------------------------------------------------------
-- 5. fn_finalize_day — 評価制（0016 版を機械抽出して置換）
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
  v_is_measured   boolean;
  v_source_mode   text;
  v_is_anomaly    boolean;
  v_minutes_max   integer;       -- daily_minutes_max (異常値しきい値)
  v_window_days   integer;       -- ★0018: 実測で R を上方修正する母数（7日）
  v_cap           integer;       -- daily_point_cap
  v_bands         jsonb;         -- ★0018: daily_bands（◎/○/△ の条件と pt）
  v_usual         integer;       -- ★0018: R = ふだんのSNS時間（分）
  v_usual_source  text;          -- ★0018: 'default' / 'reported' / 'measured'
  v_great_limit   integer;       -- ★0018: ◎ になる上限（分）
  v_good_limit    integer;       -- ★0018: ○ になる上限（分）
  v_band          text;          -- ★0018: 'great' / 'good' / 'poor' / 'unmeasured'
  v_raw_avg       numeric(8,2);  -- baselines スナップショット互換（常に null）
  v_sample_days   integer;       -- baselines スナップショット互換（計測ありの確定日数）
  v_applied_min   integer;       -- baselines スナップショット互換（= R）
  v_stage         public.baseline_stage;
  v_reduced       integer;
  v_base_points   integer;
  v_mult          numeric := 1.0; -- ★0018: 倍率は廃止（互換のため 1.0 固定で記録）
  v_final_points  integer;
  v_capped        boolean := false;
  v_idem          text;
  v_rowcount      integer := 0;
  v_inserted      boolean := false;
  v_streak_cur    integer;
  v_streak_last   date;
  v_streak_after  integer;
  v_median        numeric;
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
  select total_minutes, is_measured, source_mode
    into v_today_minutes, v_is_measured, v_source_mode
    from public.usage_daily
   where user_id = v_uid and usage_date = p_date
   for update;   -- 行ロック (同時 finalize の競合防止)

  if not found then
    return jsonb_build_object('finalized', false, 'reason', 'no_usage_data');
  end if;

  -- SSOT 読み取り (マジックナンバー禁止)。
  -- ★0018: baseline_floor_min / point_per_minute は使わない（評価制）。
  v_minutes_max := public.cfg_int('daily_minutes_max', 1440);
  v_window_days := public.cfg_int('baseline_window_days', 7);
  v_cap         := public.cfg_int('daily_point_cap', 100);
  v_bands       := public.cfg('daily_bands',
                     '{"great":{"abs_min":30,"ratio":0.5,"points":100},"good":{"abs_min":60,"ratio":0.75,"points":70},"poor":{"points":15}}'::jsonb);

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

  -- ★0018: 基準 R = 「ふだんのSNS時間」（本人申告 → 実測で上方修正のみ）。
  --   以前の「直近7日平均との差」は、減らした状態が続くほど基準が下がって報われなく
  --   なる構造だった（docs/design/EGG_PACING_REDESIGN.md §3-B）。R は自動では下げない。
  select usual_minutes, usual_minutes_source
    into v_usual, v_usual_source
    from public.profiles where id = v_uid;
  if v_usual is null then
    v_usual := public.cfg_int('usual_minutes_default', 120);
    v_usual_source := 'default';
  end if;
  v_usual_source := coalesce(v_usual_source, 'default');

  -- ストリーク現状取得 (streaks 行が無ければ0)。
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

  -- ★0018: 計測なし（権限なし / iOS で対象アプリ未選択 / 古い iOS アプリ）は評価しない。
  --   0pt・卵は進まない・連続日数は据え置き（責めない）。確定済みにはする（再提出させない）。
  --   これで「計測できていない日から出続ける幻の 30pt」（0分 − 下限30分）が消える。
  if v_is_measured is not true then
    update public.usage_daily
      set is_finalized = true,
          is_anomaly = false
      where user_id = v_uid and usage_date = p_date;
    return jsonb_build_object(
      'finalized', true,
      'points_awarded', 0,
      'base_points', 0,
      'multiplier', 1.0,
      'baseline_minutes', v_usual,
      'reduced_minutes', 0,
      'capped', false,
      'stage', 'unmeasured',
      'band', 'unmeasured',
      'is_measured', false,
      'usual_minutes', v_usual,
      'usual_minutes_source', v_usual_source,
      'today_minutes', v_today_minutes,
      'streak_after', v_streak_cur,
      'egg_applied', 'null'::jsonb,
      'already_finalized', false
    );
  end if;

  -- ★0018: 1日の評価（docs/design/EGG_PACING_DESIGN.md §2-2）。
  --   ◎ しっかり離れた日: m <= max(30, R/2)      → 100pt
  --   ○ 減らした日      : m <= max(60, R*3/4)    →  70pt
  --   △ 多めだった日    : それ以外               →  15pt
  --   絶対ライン（30分/60分）は、ふだんから少ない人（R=30/60）が ◎○ を取れるようにするため。
  v_great_limit := greatest(
    coalesce((v_bands->'great'->>'abs_min')::integer, 30),
    floor(v_usual * coalesce((v_bands->'great'->>'ratio')::numeric, 0.5))::integer);
  v_good_limit := greatest(
    coalesce((v_bands->'good'->>'abs_min')::integer, 60),
    floor(v_usual * coalesce((v_bands->'good'->>'ratio')::numeric, 0.75))::integer);

  if v_today_minutes <= v_great_limit then
    v_band := 'great';
    v_base_points := coalesce((v_bands->'great'->>'points')::integer, 100);
  elsif v_today_minutes <= v_good_limit then
    v_band := 'good';
    v_base_points := coalesce((v_bands->'good'->>'points')::integer, 70);
  else
    v_band := 'poor';
    v_base_points := coalesce((v_bands->'poor'->>'points')::integer, 15);
  end if;

  -- 互換値: 削減量 = max(R − m, 0)（クエスト reduce_total / 統計の「総削減時間」が使う）。
  v_reduced := greatest(v_usual - v_today_minutes, 0);
  v_applied_min := v_usual;
  v_raw_avg := null;
  select count(*)::integer into v_sample_days
    from public.usage_daily
   where user_id = v_uid
     and usage_date < p_date
     and is_finalized = true
     and is_measured = true
     and is_anomaly = false;
  -- baselines.stage は enum（warmup/provisional/confirmed）。申告・実測済みなら confirmed、
  -- 既定値のままなら provisional と記録する（監査用の互換。計算には使わない）。
  if v_usual_source in ('reported', 'measured') then
    v_stage := 'confirmed';
  else
    v_stage := 'provisional';
  end if;

  -- 1日上限（倍率は廃止＝ v_mult は 1.0 固定）。
  v_final_points := v_base_points;
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
        'stage', v_stage,
        'band', v_band,
        'is_measured', true,
        'usual_minutes', v_usual,
        'usual_minutes_source', v_usual_source))
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

  -- ストリーク更新: ★0018 ◎/○ なら継続、△ ならリセット（計測なしは上で据え置き）。
  if v_streak_last is distinct from p_date then
    if v_band in ('great', 'good') then
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

  -- ★0018: R の実測上方修正（上げる方向だけ / 自動では下げない）。
  --   計測ありの確定日（今日を含む）が window 日（7）以上たまったら、直近 window 日の
  --   中央値が R より大きいときだけ R をその値に上げる。一度 'measured' になったら再修正しない。
  --   下げない理由: 減らした状態が続いて基準が下がると報われなくなる（本設計の核心）。
  if v_inserted and v_usual_source is distinct from 'measured' then
    select percentile_cont(0.5) within group (order by t.total_minutes)
      into v_median
      from (
        select total_minutes
          from public.usage_daily
         where user_id = v_uid
           and usage_date <= p_date
           and is_finalized = true
           and is_measured = true
           and is_anomaly = false
         order by usage_date desc
         limit v_window_days
      ) t;
    if (select count(*) from public.usage_daily
         where user_id = v_uid and usage_date <= p_date
           and is_finalized = true and is_measured = true and is_anomaly = false) >= v_window_days
       and v_median is not null
       and round(v_median)::integer > v_usual then
      update public.profiles
        set usual_minutes = round(v_median)::integer,
            usual_minutes_source = 'measured',
            usual_minutes_updated_at = now()
        where id = v_uid;
    end if;
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
    'already_finalized', not v_inserted and v_final_points > 0,
    'band', v_band,
    'is_measured', true,
    'usual_minutes', v_usual,
    'usual_minutes_source', v_usual_source,
    'today_minutes', v_today_minutes
  );
end;
$$;

-- ⚠️ 0012:288 / 0016 の剥奪を必ず再掲する。create or replace は ACL を保持するが、
--    0002:876 が authenticated に grant しているため、ここを書き忘れると
--    「本体を直接呼んで任意の過去日を確定させる」経路 (0011 の日付境界ガード迂回) が復活する。
revoke execute on function public.fn_finalize_day(date)
  from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 6. fn_claim_warmup — 2日目を「孵化までの残り全部」へ（0016 版を機械抽出して置換）
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
  v_hatch        integer;              -- ★0018: 孵化しきい値（残り全部の計算用）
  v_starter_pts  integer;              -- ★0018: 初回ボーナス卵の現在の成長pt
  v_starter_loc  public.egg_location;  -- ★0018: 初回ボーナス卵の所在
  v_mode         text := 'day1';       -- ★0018: 'day1' / 'top_up' / 'active'
  v_target_egg   uuid;                 -- ★0018: 充当先（null = アクティブ卵 or プール）
  v_warmup_total integer := 0;         -- ★0018: これまでの初回ボーナス付与の合計（生涯上限用）
  v_grant_raw    integer := 0;         -- ★0018: 上限を当てる前の付与額（already_claimed 判定用）
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  if p_day is null or p_day not in (1, 2) then
    raise exception 'invalid_warmup_day' using errcode = '22023';
  end if;

  -- ユーザーTZの暦日 (台帳 ledger_date 用 / S11)。
  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid
    for update;  -- ★0018: 同一ユーザーの day1/day2 同時呼び出しを直列化（生涯上限の読み書きを守る）
  if v_tz is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;
  v_today := (now() at time zone v_tz)::date;

  -- SSOT: 付与額を app_config.warmup_grants から読む (マジックナンバー禁止)。
  -- ★0018: day1 は固定値。day2 の量は初回ボーナス卵の状態で決める（下記）。
  v_grants := public.cfg('warmup_grants', '{"day1":300,"day2":200}'::jsonb);
  v_hatch  := coalesce(
    (public.cfg('egg_thresholds', '{"hatch":500}'::jsonb)->>'hatch')::integer, 500);

  -- 初回ボーナス卵を先に確保する (付与pt の充当先)。
  -- starter 卵が既にあれば再生成しない。無く、かつアクティブ卵も無い場合のみ生成。
  select id, growth_points, location
    into v_egg_id, v_starter_pts, v_starter_loc
    from public.eggs
   where user_id = v_uid and acquired_source = 'starter'
   order by created_at
   limit 1;

  -- ★0018: 付与額と充当先を決める。
  --   day1    … 固定（300）。初回ボーナス卵へ（無ければ下で生成 / それも無理ならアクティブ卵）。
  --   day2    … 初回ボーナス卵が育成中なら「孵化までの残り全部」= max(hatch − 成長pt, 0) を
  --             その卵へ（初日で止まっている既存ユーザーの卵もこれで孵る＝移行SQL不要）。
  --             初回ボーナス卵が無い／孵化済み／保管中なら warmup_grants.day2 をアクティブ卵へ。
  if p_day = 1 then
    v_mode  := 'day1';
    v_grant := coalesce((v_grants->>'day1')::integer, 0);
  elsif v_egg_id is not null and v_starter_loc = 'incubating' then
    v_mode  := 'top_up';
    v_grant := greatest(v_hatch - coalesce(v_starter_pts, 0), 0);
  else
    v_mode  := 'active';
    v_grant := coalesce((v_grants->>'day2')::integer, 0);
  end if;

  -- ★0018（第三者レビュー #1）: 初回ボーナスの生涯合計は hatch（500）を超えない。
  --   day2 を day1 より先に呼ぶ（RPC を直接叩けば可能）と、残り全部(500)+day1(300)=800 に
  --   なるのを防ぐ。上の profiles 行ロックで同時呼び出しも直列化される。
  select coalesce(sum(amount), 0) into v_warmup_total
    from public.point_ledger
   where user_id = v_uid and source = 'warmup';
  v_grant_raw := v_grant;
  v_grant := least(v_grant, greatest(v_hatch - v_warmup_total, 0));

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
      jsonb_build_object(
        'day', p_day,
        'mode', v_mode,
        'starter_points_before', v_starter_pts))
    on conflict (idempotency_key) do nothing;
    get diagnostics v_rowcount = row_count;
    v_inserted := (v_rowcount > 0);

    if v_inserted then
      -- 初回のみ残高反映 (point_balance は導出キャッシュ。台帳が真)。
      update public.profiles
        set point_balance = point_balance + v_grant
        where id = v_uid
        returning point_balance into v_balance;

      -- 付与pt を充当する (= 卵成長へ積む / S1)。
      -- ★0018: 'active' モード（初回ボーナス卵が無い/孵化済み/保管中）は対象を明示せず、
      --   fn_apply_growth にアクティブ卵（無ければプール）を選ばせる。
      --   ★0016: v_idem = uid:warmup:N (日付非依存の生涯1回キー)。これにより
      --   Day1/Day2 が同じ暦日に落ちても互いを打ち消さない。
      v_target_egg := case when v_mode = 'active' then null else v_egg_id end;
      v_egg_result := public.fn_apply_growth(v_target_egg, v_grant, v_today, v_idem);
    end if;
  end if;

  return jsonb_build_object(
    'claimed', true,
    'day', p_day,
    'granted', case when v_inserted then v_grant else 0 end,
    'egg_id', v_egg_id,
    'egg_applied', v_egg_result,
    'balance_after', v_balance,
    'mode', v_mode,
    'already_claimed', (v_grant_raw > 0 and not v_inserted));
end;
$$;

-- fn_claim_warmup の権限は 0003 のまま (authenticated が呼ぶ入口)。再掲。
grant execute on function public.fn_claim_warmup(integer) to authenticated;


-- ----------------------------------------------------------------------------
-- 7. quest_condition_met — reduce_total の「計測なし」判定を is_measured へ
--    （0015 版を機械抽出して置換）
-- ----------------------------------------------------------------------------
create or replace function public.quest_condition_met(
  p_uid       uuid,
  p_condition jsonb,
  p_kind      public.quest_kind,
  p_period    date)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type      text := p_condition->>'type';
  v_target    integer := coalesce(
                 (p_condition->>'target')::integer,
                 (p_condition->>'minutes')::integer, 0);
  v_package   text := p_condition->>'package';
  v_period_lo date;
  v_period_hi date;
  v_val       integer;
  v_used      integer;
  v_baseline  integer;
  v_today     integer;
  v_finalized boolean;
  v_per_app   jsonb;
  v_streak    integer;
  v_source_mode text;
  v_measured  boolean;   -- ★0018
  v_tz        text;
begin
  if v_type is null then
    return false;
  end if;

  -- 期間範囲: daily は当日のみ、weekly は period_start を含む7日窓 (PRD §S14 週初日基準)。
  v_period_lo := p_period;
  if p_kind = 'weekly' then
    v_period_hi := p_period + 6;
  else
    v_period_hi := p_period;
  end if;

  case v_type
    when 'app_under' then
      -- 合計型 (package なし) はサーバー未実装。実装するまで未達に倒す (0015 ヘッダ参照)。
      if v_package is null then
        return false;
      end if;
      -- fail-closed 3段:
      --   ① usage_daily 行が存在すること         (未提出の日で報酬を得させない / 0005 C-2)
      --   ② サーバーが確定した日であること        (端末の暫定値で判定しない / 0005 C-2)
      --   ③ per_app_minutes[package] が**数値**であること (0015)
      --      キー欠落・null 値・文字列を「0分」と読み替えない。iOS は per-app キーを
      --      構造的に持たないので、この判定で常に未達になる (＝正しい)。
      select is_finalized, per_app_minutes
        into v_finalized, v_per_app
        from public.usage_daily
       where user_id = p_uid and usage_date = p_period;
      if not found or v_finalized is not true then
        return false;
      end if;
      if jsonb_typeof(v_per_app -> v_package) is distinct from 'number' then
        return false;
      end if;
      -- ★型が number でも整数とは限らない。jsonb の number は numeric なので
      --   {"pkg": 0.5} は typeof='number' を通り、'0.5'::integer が 22P02 で落ちる
      --   （落ちると受取が「受け取りに失敗しました」になり、その期間ずっと詰まる）。
      --   numeric 経由で受けて範囲を検証し、切り捨てて整数化する。
      if (v_per_app ->> v_package)::numeric
           not between 0 and public.cfg_int('daily_minutes_max', 1440) then
        return false;
      end if;
      v_used := floor((v_per_app ->> v_package)::numeric)::integer;
      return v_used < v_target;

    when 'reduce_total' then
      -- 削減量 = その日の適用基準(baselines.applied_minutes) - その日の利用(total_minutes)。
      -- fail-closed: usage_daily 行が確定済みで baselines も存在する場合のみ判定。
      select b.applied_minutes, u.total_minutes, u.is_finalized, u.source_mode,
             u.is_measured
        into v_baseline, v_today, v_finalized, v_source_mode, v_measured
        from public.usage_daily u
        join public.baselines b
          on b.user_id = u.user_id and b.baseline_date = u.usage_date
       where u.user_id = p_uid and u.usage_date = p_period;
      if not found or v_finalized is not true
         or v_baseline is null or v_today is null then
        return false;
      end if;
      -- ★0018: 「計測できていない日」は usage_daily.is_measured で判定する。
      --   0015 は iOS の 0 分を一律「計測なし」と読んでいた（対象アプリ未選択の永久0分と
      --   区別できなかったため）。0018 からは端末が is_measured を送る（iOS は対象アプリ
      --   選択済みなら true）ので、**計測ありの 0 分（15分未満）は本当に離れた日**として
      --   達成させる。計測なし（権限なし / 未選択 / 古い iOS アプリ）は未達のまま。
      --   ⚠️ is_measured も端末申告なので細工した端末への防御ではない（0015 と同じ前提）。
      if v_measured is not true then
        return false;
      end if;
      return greatest(v_baseline - v_today, 0) >= v_target;

    when 'streak_keep' then
      -- その period にストリークが**維持された**こと。
      -- ★0015: last_progress_date の一致だけでは足りない。0012:245-263 は削減が
      --   0/マイナスでストリークをリセットする場合にも last_progress_date を立てるため、
      --   「切った日」まで達成になっていた。current_streak > 0 を要求する。
      select current_streak into v_streak
        from public.streaks
       where user_id = p_uid and last_progress_date = p_period;
      return found and coalesce(v_streak, 0) > 0;

    when 'hatch_count' then
      -- 当該 period 窓内に孵化した卵数。
      -- ★0015: updated_at ではなく hatched_at で数える。updated_at は
      --   set_updated_at (0001:27-35) が無条件に now() を入れるうえ、authenticated は
      --   is_active を UPDATE できる (0004:97) ため、no-op UPDATE 1回で過去の卵を
      --   「今週孵化した」ことにできた (weekly_hatch_3 = 100pt + 10ジェムの farm)。
      --   hatched_at はトリガー専管で列GRANT外＝クライアントから動かせない。
      --   ★週窓はユーザーTZで切る。period 側は fn_sync_quests が
      --     (now() at time zone <profiles.timezone>)::date を週初日にして作るのに、
      --     判定を UTC 日付でしていたため JST 月曜 00:00〜09:00 の孵化が前週に落ちていた。
      --     hatched_at が権威列になるぶん、このズレは恒久化する。
      select coalesce(timezone, 'Asia/Tokyo') into v_tz
        from public.profiles where id = p_uid;   -- definer なので RLS に妨げられない
      select count(*)::integer into v_val
        from public.eggs
       where user_id = p_uid
         and location = 'hatched'
         and hatched_at is not null
         and (hatched_at at time zone coalesce(v_tz, 'Asia/Tokyo'))::date
             between v_period_lo and v_period_hi;
      return coalesce(v_val, 0) >= v_target;

    when 'points_earn' then
      -- 当該 period 窓内の基礎pt獲得 (source='reduction')。固定報酬は含めない (S14)。
      select coalesce(sum(amount), 0)::integer into v_val
        from public.point_ledger
       where user_id = p_uid
         and source = 'reduction'
         and ledger_date between v_period_lo and v_period_hi;
      return coalesce(v_val, 0) >= v_target;

    else
      -- 未知type は未達。
      return false;
  end case;
end;
$$;

-- 内部専用（0005 / 0015 と同方針）。再掲。
revoke all on function public.quest_condition_met(uuid, jsonb, public.quest_kind, date)
  from public, anon, authenticated;

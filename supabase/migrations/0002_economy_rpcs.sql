-- ============================================================================
-- Moffy 経済RPC (0002_economy_rpcs.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-06-19
-- 準拠: docs/PRD.md (§4抽選確率表 / S1〜S14) / docs/ARCHITECTURE.md (§1-4信頼境界 / §2-3)
--       supabase/migrations/0001_init.sql (スキーマ / RLS / seed / 末尾RPCシグネチャ)
--
-- ============================================================================
-- 信頼境界の核 (= このファイルの存在意義):
--   * ポイント確定・卵成長・孵化抽選・報酬付与・通貨消費・退会は **すべてここ**
--     (PostgreSQL関数 / security definer) でのみ実行する。クライアントの直接書込みは
--     0001 の RLS で封鎖済み (point_ledger/mofi_collection/entitlements は書込ポリシー無し)。
--   * security definer: 関数の所有者 (= postgres / migration実行ロール) の権限で実行される。
--     よって RLS をバイパスして書込めるが、**関数内で必ず auth.uid() を起点**にし、
--     呼び出しユーザー本人の行しか触らない (= 他人のデータを書き換えられない)。
--   * set search_path = '' (空) を全関数に付与。security definer 関数の search_path 乗っ取り
--     (= 悪意あるスキーマを先頭に差し込んで関数を上書きする攻撃) を防ぐ。スキーマは全て
--     完全修飾 (public.xxx / auth.uid()) で記述する。
--   * 冪等 (idempotent): 同じ入力で何度呼んでも結果が1回ぶんに収束する。
--     point_ledger.idempotency_key の unique 制約 + on conflict do nothing、
--     user_quests.reward_granted フラグ、eggs.location 状態チェックで二重実行を防ぐ。
--   * マジックナンバー禁止 / SSOT: 抽選確率・しきい値・上限・倍率は **app_config /
--     drop_tables から読む**。この SQL に 480 や 0.02 を直書きしない。
--
-- 適用方法 (ライブDBが無いため本ファイルは未実行 / 手順は docs/BACKEND_SETUP.md):
--   supabase db push   または   psql -f 0001_init.sql -f 0002_economy_rpcs.sql
--
-- 冪等性 (このマイグレーション自体の再適用安全性):
--   * 関数は create or replace。型 (ENUM/composite) は do-block で存在チェック。
--   * revoke/grant は再実行しても安全 (重複付与でエラーにならない)。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 孵化結果を返す composite 型 (HatchResult の wire 形)
--    クライアント egg_models.dart の HatchResult.fromJson が読む形に合わせる。
--    Supabase RPC は composite/jsonb を JSON で返す。ここでは jsonb を返す方針にし、
--    型はドキュメント目的で残さず、関数戻り値を jsonb に統一する (パース容易)。
-- ----------------------------------------------------------------------------
-- (composite 型は使わず jsonb を返す。理由: PostgREST 経由で List/Map に素直に展開でき、
--  クライアントの fromJson と1:1で対応するため。)

-- ============================================================================
-- 共通ヘルパ (private): app_config / drop_tables 読み取り
-- ----------------------------------------------------------------------------
-- SSOT を一箇所で読む。security definer 関数群はこれ経由でのみ経済値を取得する。
-- search_path='' のため public. を完全修飾。
-- ============================================================================

-- app_config の単一キーを jsonb で返す (欠損時は p_default)。
create or replace function public.cfg(p_key text, p_default jsonb default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select value from public.app_config where key = p_key),
    p_default
  );
$$;

-- app_config の整数値を返す。
create or replace function public.cfg_int(p_key text, p_default integer)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select (value)::text::integer from public.app_config where key = p_key),
    p_default
  );
$$;

-- app_config の numeric 値を返す。
create or replace function public.cfg_num(p_key text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select (value)::text::numeric from public.app_config where key = p_key),
    p_default
  );
$$;

-- ============================================================================
-- ストリーク倍率の解決 (S14)
-- ----------------------------------------------------------------------------
-- streak_multipliers = [{"days":1,"mult":1.0},{"days":3,"mult":1.2},...] (昇順)。
-- 連続達成日数 p_streak_days に対し「直下段の倍率」を返す (例 5日目=×1.2)。
-- マジックナンバー禁止: テーブル値のみ参照。空/不正時は 1.0。
-- ============================================================================
create or replace function public.streak_multiplier(p_streak_days integer)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select (elem->>'mult')::numeric
      from jsonb_array_elements(
        public.cfg('streak_multipliers', '[{"days":1,"mult":1.0}]'::jsonb)
      ) as elem
      where (elem->>'days')::integer <= greatest(p_streak_days, 0)
      order by (elem->>'days')::integer desc
      limit 1
    ),
    1.0
  );
$$;

-- ============================================================================
-- fn_finalize_day(p_date) — 当日(= サーバー基準のその日)の削減pt確定
-- ----------------------------------------------------------------------------
-- 責務 (PRD §4-5 / S1,S2,S4,S11,S14 / ARCHITECTURE §2-3):
--   1. 認証ユーザー本人 (auth.uid()) の確定処理のみ。p_date はユーザーTZの暦日。
--   2. 遡及不可: p_date がサーバー基準の「今日」より未来なら拒否。過去日は当日含め確定済み
--      なら冪等スキップ (idempotency_key で二重加算防止)。
--   3. 基準値 = 本日除く直近 window 日平均 (欠損日除外 = 分母は実データ日数)、下限30分クランプ。
--   4. 削減pt = max(0, baseline.applied_minutes - today.total_minutes) * point_per_minute。
--      マイナス(使い過ぎ)日は 0 (S2)。
--   5. ストリーク倍率を **基礎ptにのみ** 適用 (S14)。固定報酬には掛けない。
--   6. 上限 daily_point_cap (480) で「倍率適用後の最終値」をクランプ (S4,S14)。
--   7. point_ledger へ idempotency_key = user×date×'reduction' で冪等加算。
--   8. baselines にスナップショット (監査・再計算用) を upsert。
--   9. streaks 更新 (削減プラス日は継続、マイナス/0日はリセット / S2,S14)。
--   10. usage_daily.is_finalized を true 化。
--      ※ 連動して当該日のアクティブ卵へ成長pt反映 (fn_apply_growth 相当) も行う。
-- 戻り値: jsonb {finalized, points_awarded, base_points, multiplier, baseline_minutes,
--                reduced_minutes, capped, streak_after, egg_applied}
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
  select total_minutes, is_anomaly
    into v_today_minutes, v_is_anomaly
    from public.usage_daily
   where user_id = v_uid and usage_date = p_date
   for update;   -- 行ロック (同時 finalize の競合防止)

  if not found then
    return jsonb_build_object('finalized', false, 'reason', 'no_usage_data');
  end if;

  -- S4-3 異常値: anomaly 日は確定しない (破棄済みフラグ)。
  if v_is_anomaly then
    return jsonb_build_object('finalized', false, 'reason', 'anomaly');
  end if;

  -- SSOT 読み取り (マジックナンバー禁止)。
  v_window_days := public.cfg_int('baseline_window_days', 7);
  v_floor_min   := public.cfg_int('baseline_floor_min', 30);
  v_ppm         := public.cfg_int('point_per_minute', 1);
  v_cap         := public.cfg_int('daily_point_cap', 480);

  -- 基準値 = 本日(p_date)を含まない直近 window 日平均 (欠損除外 / S11)。
  -- anomaly 日は分母からも除外する。
  select avg(total_minutes)::numeric(8,2), count(*)::integer
    into v_raw_avg, v_sample_days
    from public.usage_daily
   where user_id = v_uid
     and usage_date < p_date
     and usage_date >= p_date - v_window_days
     and is_anomaly = false;

  -- S1 ウォームアップ: 実データ日数で stage を決定。
  --   0日       -> warmup    (基準計算しない。warmup_grants は別途付与のためここでは0pt)
  --   1〜(w-1)日 -> provisional (暫定基準 = それまでの平均)
  --   w日以上    -> confirmed
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
  --   継続条件 (v_reduced>0) が成立する日は、今日の継続を含めた日数
  --   (v_streak_cur + 1) の到達段で乗算する。例: 関数突入時 v_streak_cur=2 (=継続3日目)
  --   なら streak_multiplier(3)=×1.2。これにより「3日=×1.2 / 7日=×1.5」(PRD §S14・§4表)
  --   およびクライアント表示 (streaks.current_streak は維持後の値で StreakTier.multiplierFor)
  --   と段が一致する。
  --   v_reduced=0 の日は base_points=0 のため倍率は最終値 (0) に影響しない。便宜上
  --   現在ストリークの段を引いておく (どちらでも 0 のままなので結果は不変)。
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
    -- 実際に insert されたか (= 初回確定か) を判定。
    get diagnostics v_rowcount = row_count;
    v_inserted := (v_rowcount > 0);
    -- S8: 確定済みptを減らす上書きはしない。初回のみ profiles.point_balance に反映。
    if v_inserted then
      update public.profiles
        set point_balance = point_balance + v_final_points
        where id = v_uid;
    end if;
  end if;

  -- usage_daily を確定済みに (再確定でも安全)。
  update public.usage_daily
    set is_finalized = true
    where user_id = v_uid and usage_date = p_date;

  -- ストリーク更新 (S2,S14): その日の削減プラス(reduced>0)なら継続、0/マイナスならリセット。
  --   ※ デイリークエスト達成による継続は fn_grant_quest_reward 側でも維持しうる (OR条件)。
  --   同一日二重加算防止: last_progress_date = p_date なら何もしない。
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

-- ============================================================================
-- fn_apply_growth(p_egg_id, p_points, p_date) — アクティブ卵へ成長pt反映
-- ----------------------------------------------------------------------------
-- 責務 (S6 / §4-5):
--   * p_egg_id が null の場合は本人のアクティブ卵 (is_active) を対象にする。
--     アクティブ卵が無い場合は profiles.pooled_points にプール (最大 N 日分 / S6)。
--   * 成長pt加算は不可逆・蓄積 (S2)。500ptを超えても加算は止めない (孵化時に判定)。
--   * spend_incubation の控除台帳を冪等記録 (idempotency_key = uid×date×'spend_incubation')。
--   * 冪等性: fn_finalize_day が「新規確定時のみ」呼ぶため二重充当しない。直接呼び出し時も
--     同日の控除台帳が既にあれば二重加算しない設計 (台帳 on conflict)。
-- 戻り値: jsonb {applied_to, egg_id, growth_after, pooled_after}
-- ============================================================================
create or replace function public.fn_apply_growth(
  p_egg_id uuid,
  p_points integer,
  p_date date default null)
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
  v_idem := v_uid::text || ':' || v_date::text || ':spend_incubation';
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

-- ============================================================================
-- fn_hatch_egg(p_egg_id) — サーバー抽選による孵化 (S5,S13 / §4-1〜4-3)
-- ----------------------------------------------------------------------------
-- 責務 (信頼境界の核: 抽選は必ずサーバー):
--   1. 本人の卵で hatch しきい値 (egg_thresholds.hatch=500) 到達済みのみ孵化。
--   2. 二重孵化防止: for update で行ロック + location='hatched' なら拒否。
--   3. 抽選順序 (S5):
--      ① 卵レアリティは入手時確定済 (eggs.rarity) → 再抽選しない。
--      ② drop_tables[卵レア].distribution の重みで Mofiレアリティ抽選。
--      ③ そのレアリティの mofi_species から均等に1個体。
--      ④ shiny_rate (2.0%) の独立判定 (S13)。
--   4. mofi_collection に upsert (色違い別エントリ / uq_collection_dex)。重複は count++。
--   5. eggs を hatched 化し hatched_into を図鑑行に紐付け。
--   6. 抽選は drop_tables / app_config のみ参照 (マジックナンバー禁止)。
--   7. 乱数は server-side (random())。クライアントは結果を受け取るだけ。
-- 戻り値: jsonb (egg_models.dart HatchResult.fromJson が読む形)
--   {species:{id,family,rarity,name,sort_order}, is_shiny, is_new_dex_entry, from_egg_id}
-- ============================================================================
create or replace function public.fn_hatch_egg(p_egg_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_rarity       public.egg_rarity;
  v_growth       integer;
  v_location     public.egg_location;
  v_hatch_thr    integer;
  v_shiny_rate   numeric;
  v_dist         jsonb;
  v_roll         numeric;
  v_cum          numeric := 0;
  v_picked_rar   public.mofi_rarity;
  v_species      public.mofi_species%rowtype;
  v_is_shiny     boolean;
  v_existing_id  uuid;
  v_collection_id uuid;
  v_is_new       boolean := false;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  -- 行ロックで二重孵化防止 (同時2リクエストの片方を待たせる)。
  select rarity, growth_points, location
    into v_rarity, v_growth, v_location
    from public.eggs
   where id = p_egg_id and user_id = v_uid
   for update;

  if not found then
    raise exception 'egg_not_found' using errcode = 'P0002';
  end if;
  if v_location = 'hatched' then
    raise exception 'already_hatched' using errcode = '23505';
  end if;

  -- しきい値到達チェック (SSOT)。
  v_hatch_thr := (public.cfg('egg_thresholds', '{"hatch":500}'::jsonb)->>'hatch')::integer;
  if v_growth < v_hatch_thr then
    raise exception 'not_ready_to_hatch' using errcode = '22023';
  end if;

  -- ② Mofiレアリティ抽選: drop_tables[卵レア] の重み付き。
  select distribution into v_dist
    from public.drop_tables where egg_rarity = v_rarity;
  if v_dist is null then
    raise exception 'drop_table_missing' using errcode = 'P0002';
  end if;

  v_roll := random();   -- [0,1)
  -- common -> rare -> sr -> ssr の累積で判定。欠損キーは0扱い。
  v_cum := v_cum + coalesce((v_dist->>'common')::numeric, 0);
  if v_roll < v_cum then
    v_picked_rar := 'common';
  else
    v_cum := v_cum + coalesce((v_dist->>'rare')::numeric, 0);
    if v_roll < v_cum then
      v_picked_rar := 'rare';
    else
      v_cum := v_cum + coalesce((v_dist->>'sr')::numeric, 0);
      if v_roll < v_cum then
        v_picked_rar := 'sr';
      else
        v_picked_rar := 'ssr';   -- 残余 (浮動小数の端数も ssr に寄せる)
      end if;
    end if;
  end if;

  -- ③ そのレアリティの個体から均等抽選 (is_active のみ)。
  select * into v_species
    from public.mofi_species
   where rarity = v_picked_rar and is_active = true
   order by random()
   limit 1;
  if not found then
    -- フォールバック: 万一その レアリティ個体が居なければ全体から1体 (落とさない)。
    select * into v_species
      from public.mofi_species where is_active = true
      order by random() limit 1;
    if not found then
      raise exception 'no_species' using errcode = 'P0002';
    end if;
  end if;

  -- ④ 色違い独立判定 (S13: shiny_rate = 2.0%)。
  v_shiny_rate := public.cfg_num('shiny_rate', 0.02);
  v_is_shiny := random() < v_shiny_rate;

  -- ④ 図鑑 upsert (色違い別エントリ / uq_collection_dex)。重複は count++。
  select id into v_existing_id
    from public.mofi_collection
   where user_id = v_uid and species_id = v_species.id and is_shiny = v_is_shiny;

  -- 事前 select で存在有無を確定 (同一Tx・行ロック下なので競合しない)。
  if v_existing_id is null then
    -- 新規発見。on conflict は二重防御 (理論上発火しないが安全側)。
    insert into public.mofi_collection(user_id, species_id, is_shiny, obtained_count)
    values (v_uid, v_species.id, v_is_shiny, 1)
    on conflict (user_id, species_id, is_shiny) do update
      set obtained_count = public.mofi_collection.obtained_count + 1
    returning id into v_collection_id;
    v_is_new := true;
  else
    -- 既発見 → 累計回数のみ加算 (図鑑エントリは増えない)。
    update public.mofi_collection
      set obtained_count = obtained_count + 1
      where id = v_existing_id
      returning id into v_collection_id;
    v_is_new := false;
  end if;

  -- ⑤ 卵を hatched 化し図鑑行へ紐付け。is_active も解除。
  update public.eggs
    set location = 'hatched',
        is_active = false,
        slot_index = null,
        hatched_into = v_collection_id
    where id = p_egg_id;

  -- HatchResult wire 形で返す。
  return jsonb_build_object(
    'species', jsonb_build_object(
      'id', v_species.id,
      'family', v_species.family,
      'rarity', v_species.rarity,
      'name', v_species.name,
      'sort_order', v_species.sort_order),
    'is_shiny', v_is_shiny,
    'is_new_dex_entry', v_is_new,
    'from_egg_id', p_egg_id::text);
end;
$$;

-- ============================================================================
-- fn_grant_quest_reward(p_user_quest_id) — クエスト報酬の冪等付与
-- ----------------------------------------------------------------------------
-- 責務 (S7,S14 / §5-3 二重付与しない):
--   1. 本人の user_quests 行で is_completed=true のみ付与可。
--   2. 二重受取防止: for update + reward_granted フラグ。既付与なら冪等で何もしない。
--   3. 報酬 (quest_definitions.reward) の pt/gems/egg を付与。
--      固定報酬はストリーク倍率を掛けない (S14)。
--      pt は point_ledger(source='quest_reward', idem=uid×period×quest) で冪等加算。
--   4. 報酬卵があれば eggs に storage で生成。
--   5. デイリー達成によるストリーク維持 (S14 OR条件) も同時に処理。
-- 戻り値: jsonb {granted, points, gems, egg_rarity, quest_id}
-- ============================================================================
create or replace function public.fn_grant_quest_reward(p_user_quest_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid         uuid := auth.uid();
  v_quest_def   text;
  v_kind        public.quest_kind;
  v_period      date;
  v_completed   boolean;
  v_granted     boolean;
  v_reward      jsonb;
  v_points      integer;
  v_gems        integer;
  v_egg_rarity  text;
  v_idem        text;
  v_rowcount    integer := 0;
  v_streak_cur  integer;
  v_streak_last date;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  select quest_id, kind, period_start, is_completed, reward_granted
    into v_quest_def, v_kind, v_period, v_completed, v_granted
    from public.user_quests
   where id = p_user_quest_id and user_id = v_uid
   for update;

  if not found then
    raise exception 'quest_not_found' using errcode = 'P0002';
  end if;
  if not v_completed then
    raise exception 'quest_not_completed' using errcode = '22023';
  end if;
  if v_granted then
    -- 既付与 (冪等)。
    return jsonb_build_object('granted', false, 'reason', 'already_granted',
                              'quest_id', v_quest_def);
  end if;

  select reward into v_reward
    from public.quest_definitions where id = v_quest_def;
  if v_reward is null then
    raise exception 'quest_def_missing' using errcode = 'P0002';
  end if;

  v_points := coalesce((v_reward->>'points')::integer, 0);
  v_gems   := coalesce((v_reward->>'gems')::integer, 0);
  v_egg_rarity := nullif(v_reward->>'egg_rarity', 'null');

  -- 先に reward_granted を立てる (このTx内で原子的。失敗時は全体ロールバック)。
  update public.user_quests
    set reward_granted = true
    where id = p_user_quest_id;

  -- pt付与 (固定報酬: 倍率なし / S14)。冪等キー = uid×period×quest_id。
  -- F-04: fn_finalize_day と対称に「台帳へ実挿入できた初回のみ」残高反映。
  --   point_balance は導出キャッシュ (台帳が真 / 0001 §profiles) なので、
  --   on conflict で台帳が増えなかった場合に残高だけ加算すると不変条件が破れる。
  --   reward_granted フラグだけに整合を依存させず、ledger の unique で二重加算を物理封鎖。
  if v_points > 0 then
    v_idem := v_uid::text || ':' || v_period::text || ':quest:' || v_quest_def;
    insert into public.point_ledger(
      user_id, ledger_date, source, amount, idempotency_key, meta)
    values (v_uid, v_period, 'quest_reward', v_points, v_idem,
            jsonb_build_object('quest_id', v_quest_def, 'kind', v_kind))
    on conflict (idempotency_key) do nothing;
    get diagnostics v_rowcount = row_count;
    if v_rowcount > 0 then
      update public.profiles
        set point_balance = point_balance + v_points
        where id = v_uid;
    end if;
  end if;

  -- ジェム付与 (S7)。
  -- gem付与・卵生成は reward_granted の原子性下 (このTx内で先に true 化済み・再入は
  -- 関数冒頭の v_granted ガードで弾く) で1回しか到達しない。pt の様な台帳冪等キーは
  -- 持たないが、reward_granted=false の初回到達でのみ実行されるため二重化しない。
  if v_gems > 0 then
    update public.profiles
      set gem_balance = gem_balance + v_gems
      where id = v_uid;
  end if;

  -- 報酬卵生成 (storage / S6: 自動アクティブ化しない)。
  -- (gem 同様 reward_granted ガードで二重生成しない。)
  if v_egg_rarity is not null then
    insert into public.eggs(user_id, rarity, location, acquired_source)
    values (v_uid, v_egg_rarity::public.egg_rarity, 'storage',
            case when v_kind = 'weekly' then 'quest' else 'quest' end);
  end if;

  -- S14: デイリー達成日はストリーク維持 (削減プラスと OR)。同日二重加算防止。
  if v_kind = 'daily' then
    select current_streak, last_progress_date
      into v_streak_cur, v_streak_last
      from public.streaks where user_id = v_uid for update;
    if not found then
      insert into public.streaks(user_id, current_streak, longest_streak, last_progress_date)
        values (v_uid, 1, 1, v_period)
        on conflict (user_id) do nothing;
    elsif v_streak_last is distinct from v_period then
      update public.streaks
        set current_streak = current_streak + 1,
            longest_streak = greatest(longest_streak, current_streak + 1),
            last_progress_date = v_period
        where user_id = v_uid;
    end if;
  end if;

  return jsonb_build_object(
    'granted', true,
    'points', v_points,
    'gems', v_gems,
    'egg_rarity', v_egg_rarity,
    'quest_id', v_quest_def);
end;
$$;

-- ============================================================================
-- fn_spend_currency(p_kind, p_amount, p_reason) — 残高チェック付き原子的消費
-- ----------------------------------------------------------------------------
-- 責務 (S7,S8 / §5-3 二重消費防止):
--   * p_kind = 'gem' | 'point'。p_amount > 0。
--   * 残高不足なら例外 (insufficient_balance)。原子的: for update で残高ロック。
--   * オフライン消費はクライアント側で既に封鎖 (S8)。サーバーでも本人検証。
--   * point 消費は profiles.point_balance を減算 (台帳は別途設計。MVPは残高直接)。
--   * 返金/ロールバックは呼び出し失敗時の自然なTxロールバックで担保。
-- 戻り値: jsonb {spent, kind, amount, balance_after}
-- ============================================================================
create or replace function public.fn_spend_currency(
  p_kind text,
  p_amount integer,
  p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_balance integer;
  v_after   integer;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if p_kind not in ('gem', 'point') then
    raise exception 'invalid_kind' using errcode = '22023';
  end if;

  if p_kind = 'gem' then
    select gem_balance into v_balance from public.profiles
      where id = v_uid for update;
    if v_balance is null then
      raise exception 'profile_not_found' using errcode = 'P0002';
    end if;
    if v_balance < p_amount then
      raise exception 'insufficient_balance' using errcode = 'P0001';
    end if;
    update public.profiles set gem_balance = gem_balance - p_amount
      where id = v_uid returning gem_balance into v_after;
  else
    select point_balance into v_balance from public.profiles
      where id = v_uid for update;
    if v_balance is null then
      raise exception 'profile_not_found' using errcode = 'P0002';
    end if;
    if v_balance < p_amount then
      raise exception 'insufficient_balance' using errcode = 'P0001';
    end if;
    update public.profiles set point_balance = point_balance - p_amount
      where id = v_uid returning point_balance into v_after;
  end if;

  return jsonb_build_object(
    'spent', true, 'kind', p_kind, 'amount', p_amount, 'balance_after', v_after);
end;
$$;

-- ============================================================================
-- fn_delete_account() — アカウントの論理削除 (S12: 即時論理削除 → 30日パージ)
-- ----------------------------------------------------------------------------
-- 責務 (S12 / §5-4 審査必須 / F-03):
--   * 本人 (auth.uid()) を「論理削除」する: profiles.deleted_at に現在時刻を立てる。
--     即時の物理削除 (delete from auth.users) は行わない。これにより誤操作・サポート
--     復旧の余地を 30日 残す (0001 profiles.deleted_at の設計どおり)。
--   * profiles の SELECT RLS は deleted_at is null 条件付き (追補 0003) のため、
--     論理削除後は本人でも自分のプロフィール行が見えなくなる (= 退会済み扱い)。
--   * 物理削除は service_role 専用バッチ fn_purge_deleted_accounts() が
--     deleted_at < now() - 30日 の auth.users を cascade 削除する (pg_cron / 0003)。
--   * クライアント (account_repository.deleteAccount) は本RPC成功後に
--     supabase.auth.signOut() 済みである (= セッション破棄)。サーバーは状態のみ更新。
--   * サブスク解約はストア管理のため、ここでは行わない (案内はクライアント表示 / S12)。
--   * 単一Txで実行 (失敗時は全ロールバック)。
-- 戻り値: jsonb {deleted, deleted_at}
-- ============================================================================
create or replace function public.fn_delete_account()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_now timestamptz := now();
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  -- 論理削除: deleted_at を立てる (冪等。既に立っていても now() で更新)。
  -- 物理削除は 30日後に fn_purge_deleted_accounts() が cascade で行う。
  update public.profiles
    set deleted_at = v_now
    where id = v_uid;

  return jsonb_build_object('deleted', true, 'deleted_at', v_now);
end;
$$;

-- ============================================================================
-- 権限 (revoke / grant) — authenticated 最小権限
-- ----------------------------------------------------------------------------
-- 原則:
--   * public スキーマの新規関数は既定で PUBLIC に execute が付く。これを revoke し、
--     **authenticated ロールにのみ** 必要な関数の execute を grant する。
--   * anon (未認証) には経済RPCを一切付与しない (auth.uid() が null で弾かれるが、
--     攻撃面を減らすため execute 自体を与えない)。
--   * private ヘルパ (cfg/cfg_int/cfg_num/streak_multiplier/fn_apply_growth) は
--     クライアントから直接呼ばせない (fn_finalize_day/fn_hatch_egg 内部からのみ呼ぶ)。
--     security definer 関数は所有者権限で動くため、内部呼び出しに execute 権限は不要。
-- ============================================================================

-- まず全関数の PUBLIC / anon / authenticated への既定 execute を剥奪。
revoke all on function public.cfg(text, jsonb) from public, anon, authenticated;
revoke all on function public.cfg_int(text, integer) from public, anon, authenticated;
revoke all on function public.cfg_num(text, numeric) from public, anon, authenticated;
revoke all on function public.streak_multiplier(integer) from public, anon, authenticated;
revoke all on function public.fn_finalize_day(date) from public, anon, authenticated;
revoke all on function public.fn_apply_growth(uuid, integer, date) from public, anon, authenticated;
revoke all on function public.fn_hatch_egg(uuid) from public, anon, authenticated;
revoke all on function public.fn_grant_quest_reward(uuid) from public, anon, authenticated;
revoke all on function public.fn_spend_currency(text, integer, text) from public, anon, authenticated;
revoke all on function public.fn_delete_account() from public, anon, authenticated;

-- クライアント (authenticated) から呼ぶ公開RPC のみ execute を付与。
grant execute on function public.fn_finalize_day(date) to authenticated;
grant execute on function public.fn_hatch_egg(uuid) to authenticated;
grant execute on function public.fn_grant_quest_reward(uuid) to authenticated;
grant execute on function public.fn_spend_currency(text, integer, text) to authenticated;
grant execute on function public.fn_delete_account() to authenticated;
-- cfg* / streak_multiplier / fn_apply_growth はクライアント非公開 (内部専用)。grant しない。

-- ============================================================================
-- 補足: ライブ検証は docs/BACKEND_SETUP.md / 分布検証は supabase/tests/ を参照。
-- ============================================================================

-- ============================================================================
-- Moffy 追補マイグレーション (0003_warmup_grants.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-06-23
-- 準拠: docs/REVIEW_0002_economy.md (F-01 / F-03) / docs/PRD.md (§S1 / §S12)
--       supabase/migrations/0001_init.sql (スキーマ / RLS / seed)
--       supabase/migrations/0002_economy_rpcs.sql (経済RPC / 信頼境界)
--
-- このマイグレーションが解決する QA 差し戻し:
--   * F-01: ウォームアップ自動付与 (S1: Day1=200 / Day2=300) + 初回ボーナス卵生成。
--           → fn_claim_warmup(p_day) を新設。生涯1回の冪等付与 + starter 卵を充当。
--   * F-03: 退会の論理削除化に伴う RLS 更新 と 30日パージ関数。
--           → profiles の SELECT RLS を deleted_at is null 条件付きへ更新。
--           → fn_purge_deleted_accounts() (service_role 専用バッチ / pg_cron 運用)。
--
-- 信頼境界 (0002 と同方針):
--   * security definer + set search_path = '' + 完全修飾。auth.uid() 起点で本人限定。
--   * 冪等: point_ledger.idempotency_key の unique + on conflict do nothing +
--     get diagnostics row_count で「初回挿入時のみ残高/卵へ反映」。
--   * SSOT: 付与額は app_config.warmup_grants からのみ読む (マジックナンバー禁止)。
--
-- 冪等性 (このマイグレーション自体の再適用安全性):
--   * 関数は create or replace。RLS は drop policy if exists → create policy。
--   * revoke/grant は再実行しても安全。
-- ============================================================================

-- ============================================================================
-- F-01: fn_claim_warmup(p_day) — 初回ウォームアップ自動付与 (S1)
-- ----------------------------------------------------------------------------
-- 責務 (PRD §S1 / §5 受け入れ「初日で Day1 孵化体験まで到達」):
--   1. 本人 (auth.uid()) のみ。p_day は 1 または 2。
--   2. 付与額は app_config.warmup_grants から読む (day1=200 / day2=300 / SSOT)。
--   3. 冪等キーは **生涯1回**: idempotency_key = uid × 'warmup' × day (日付を使わない)。
--      → 同じ day を何度呼んでも 2回目以降は加算されない。日付に依存しないので
--        端末TZ・再ログインに関係なく「Day1 は生涯1回・Day2 は生涯1回」を保証する。
--   4. point_ledger(source='warmup', amount, idempotency_key) を on conflict do nothing。
--      get diagnostics row_count > 0 の初回のみ profiles.point_balance に反映。
--   5. 初回ボーナス卵: acquired_source='starter' の卵が未存在 かつ アクティブ卵が無い場合
--      のみ、eggs(rarity='normal', location='incubating', slot_index=1, is_active=true,
--      acquired_source='starter') を冪等生成 (uq_eggs_one_active / uq_eggs_slot と整合)。
--   6. 付与pt は fn_apply_growth(starter_egg_id, grant, date) で starter 卵へ充当する
--      (= 卵 growth_points に積む。Day1=200 + Day2=300 = 500 で孵化保証)。
--      fn_apply_growth の控除台帳 (spend_incubation) は日付ベース冪等のため、
--      同日に Day1/Day2 を連続で呼ぶケースでも 1日1控除に収束する点に留意
--      (通常運用は Day1=初日 / Day2=翌日 で別日)。
-- 戻り値: jsonb {claimed, day, granted, egg_id, growth_after, balance_after, already_claimed}
-- ============================================================================
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
        v_egg_result := public.fn_apply_growth(v_egg_id, v_grant, v_today);
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

-- ============================================================================
-- F-03: profiles の SELECT RLS を「本人かつ未削除 (deleted_at is null)」へ更新
-- ----------------------------------------------------------------------------
-- 0001 の profiles_select_own は auth.uid() = id のみ。論理削除 (deleted_at) 後は
-- 退会済みとして本人にも見えないようにする (fn_delete_account / F-03 と整合)。
-- 物理削除されるまでの 30日間、退会ユーザーのプロフィールは参照不可になる。
-- drop → create で冪等に置換 (再適用安全)。
-- ============================================================================
drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id and deleted_at is null);

-- ============================================================================
-- F-03: fn_purge_deleted_accounts() — 30日経過の論理削除アカウントを物理削除
-- ----------------------------------------------------------------------------
-- 責務 (S12):
--   * profiles.deleted_at < now() - interval '30 days' の論理削除アカウントについて、
--     対応する auth.users を物理削除する。
--   * auth.users 削除 → profiles ほか全ユーザー表 (FK on delete cascade / 0001) が連鎖削除。
--   * **service_role 専用**: auth.uid() 文脈に依存しない (バッチ実行)。authenticated には
--     一切 grant しない (= クライアントから呼べない)。security definer で所有者権限実行。
--   * pg_cron で日次起動する (手順は docs/BACKEND_SETUP.md)。
-- 戻り値: jsonb {purged} (削除した件数)
-- ============================================================================
create or replace function public.fn_purge_deleted_accounts()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
begin
  -- 30日経過分の auth.users を物理削除 (cascade で全関連行も消える)。
  delete from auth.users u
   using public.profiles p
   where p.id = u.id
     and p.deleted_at is not null
     and p.deleted_at < now() - interval '30 days';
  get diagnostics v_count = row_count;

  return jsonb_build_object('purged', v_count);
end;
$$;

-- ============================================================================
-- 権限 (revoke / grant) — 0002 と同方針 (authenticated 最小権限)
-- ----------------------------------------------------------------------------
--   * fn_claim_warmup: クライアント (authenticated) から呼ぶ公開RPC。
--   * fn_purge_deleted_accounts: バッチ専用。public/anon/authenticated いずれにも grant
--     しない (= service_role / 所有者のみ実行可)。
-- ============================================================================
revoke all on function public.fn_claim_warmup(integer) from public, anon, authenticated;
revoke all on function public.fn_purge_deleted_accounts() from public, anon, authenticated;

grant execute on function public.fn_claim_warmup(integer) to authenticated;
-- fn_purge_deleted_accounts は意図的に grant しない (service_role 専用)。

-- ============================================================================
-- 補足: pg_cron による日次パージ設定は docs/BACKEND_SETUP.md を参照。
-- ============================================================================

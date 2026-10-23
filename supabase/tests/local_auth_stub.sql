-- ============================================================================
-- local_auth_stub.sql — 素の PostgreSQL で Supabase のマイグレーションを流すための最小の土台
-- ----------------------------------------------------------------------------
-- 目的: CI（GitHub Actions の postgres サービス）で 0001〜 を適用し、関数の動きをテストする。
--       本番の Supabase には **絶対に流さない**（auth スキーマは Supabase が管理している）。
--
-- Supabase が用意していて、素の PostgreSQL に無いもの:
--   * ロール anon / authenticated（grant / revoke / set role の対象）
--   * スキーマ auth と auth.users（FK の参照先・0006 のトリガーの対象）
--   * 関数 auth.uid()（RLS と security definer 関数が呼ぶ。JWT の sub を返す）
-- テストでは `select set_config('request.jwt.claim.sub', '<uuid>', true)` で本人を切り替える。
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin;
  end if;
end $$;

create schema if not exists auth;

create table if not exists auth.users (
  id         uuid primary key,
  created_at timestamptz not null default now()
);

-- Supabase の auth.uid() と同じ読み方（request.jwt.claim.sub → request.jwt.claims.sub）。
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- Supabase は postgres ロールが作るオブジェクトに、anon / authenticated / service_role への
-- 既定権限（テーブル・関数・シーケンス）を付けている。素の PostgreSQL には無いので同じにする。
-- これが無いと「0004 の revoke が効いているか」「grant の再掲を忘れていないか」を
-- 本番と同じ条件で確かめられない（本番では既定で全部許可され、migration が明示的に剥奪する）。
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

-- ============================================================================
-- Moffy 初期スキーマ (0001_init.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-06-19
-- 準拠: docs/PRD.md (S1〜S14・抽選確率表§4・受け入れ条件§5) / ORG_STATE.md
--
-- 設計原則 (= SSOT / 信頼境界):
--   * 利用時間の「生データ」は端末(Drift)がSSOT。サーバーには確定計算の入力として送られる。
--   * 「ポイント確定・卵成長・図鑑・通貨残高」はサーバー(このDB)がSSOT。
--   * クライアントの主張(=「自分はPro」)は信頼しない。entitlements はサーバー検証前提
--     (RevenueCat Webhook 等でサーバー側がのみ更新。クライアントは読み取りのみ)。
--   * 抽選確率・成長しきい値・上限値などの「経済パラメータ」は app_config (リモート設定)
--     に集約し、UI とサーバー RPC の双方がここを参照する (= 単一情報源)。
--
-- 規約:
--   * すべての user データテーブルは user_id uuid (= auth.uid()) を持ち RLS で本人限定。
--   * master/config テーブルは「読み取り公開 (anon/authenticated)」「書き込みは禁止
--     (= service_role / マイグレーションのみ)」。
--   * 金額・ポイントは integer (= 分・pt は整数)。確率は numeric で basis point ではなく
--     0.0〜1.0 の小数で保持し、合計検証は CHECK ではなくアプリ/RPC側の単体テストで担保。
-- ============================================================================

-- 拡張 (uuid生成)
create extension if not exists "pgcrypto";

-- 共通: updated_at 自動更新トリガ関数
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================================
-- 0. 列挙型 (ENUM)
-- ============================================================================

-- Mofiレアリティ
create type public.mofi_rarity as enum ('common', 'rare', 'sr', 'ssr');

-- 卵レアリティ
create type public.egg_rarity as enum ('normal', 'rare', 'epic', 'legend');

-- 種族
create type public.mofi_family as enum ('slime', 'critter', 'dragon');

-- 卵の所在 (育成枠 / 保管枠 / 孵化済み)
create type public.egg_location as enum ('incubating', 'storage', 'hatched');

-- ポイント台帳の発生源 (idempotency key の構成要素)
create type public.ledger_source as enum (
  'reduction',        -- 削減で得た基礎ポイント(倍率適用後)
  'warmup',           -- 初日ウォームアップ自動付与 (Day1=200 / Day2=300)
  'quest_reward',     -- クエスト報酬ポイント
  'login_bonus',      -- デイリーログイン(少額pt)
  'spend_incubation', -- 卵育成への充当(= アクティブ卵への加算時の控除)
  'adjustment'        -- サーバー再計算による調整(増加方向のみ)
);

-- クエスト種別
create type public.quest_kind as enum ('daily', 'weekly');

-- 基準値の確定ステージ (S1 ウォームアップ方式)
create type public.baseline_stage as enum ('warmup', 'provisional', 'confirmed');

-- ============================================================================
-- 1. profiles (= ユーザープロフィール / アカウント設定)
--    auth.users と1:1。匿名認証で行が作られ、後から連携(S10)。
-- ============================================================================
create table public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  -- S11: 確定計算の正となる登録タイムゾーン (IANA名 例 'Asia/Tokyo')
  timezone        text        not null default 'Asia/Tokyo',
  display_name    text,
  -- アカウント連携状態 (S10) — 匿名のままか、連携済みか
  is_linked       boolean     not null default false,
  -- 通貨残高 (S7) — ジェムはサーバーSSOT。ポイント残高は point_ledger の合計で算出するが
  -- 高速参照用にキャッシュ列として持つ (台帳が真、ここは導出キャッシュ)。
  gem_balance     integer     not null default 0 check (gem_balance >= 0),
  point_balance   integer     not null default 0 check (point_balance >= 0),
  -- 空枠時のプールpt (S6: アクティブ卵が無い間のptを最大3日分プール)
  pooled_points   integer     not null default 0 check (pooled_points >= 0),
  -- アカウント削除 (S12): 即時論理削除 → 30日以内に物理削除
  deleted_at      timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create trigger trg_profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ============================================================================
-- 2. tracked_apps (= ポイント計算対象アプリ / S3)
--    MVPは固定4アプリだが「設定で増減できる構造」(S3) のためユーザー別テーブル。
--    初期4件は新規ユーザー作成時に RPC/トリガで投入する想定。
-- ============================================================================
create table public.tracked_apps (
  id           uuid        primary key default gen_random_uuid(),
  user_id      uuid        not null references auth.users(id) on delete cascade,
  -- Android パッケージ名 (例 'com.zhiliaoapp.musically') / iOSは bundle id
  package_name text        not null,
  platform     text        not null check (platform in ('android', 'ios')),
  label        text        not null,  -- 表示名 (TikTok 等)
  is_active    boolean     not null default true,
  created_at   timestamptz not null default now(),
  unique (user_id, package_name, platform)
);

create index idx_tracked_apps_user on public.tracked_apps(user_id);

-- ============================================================================
-- 3. usage_daily (= 日次の対象SNS合計利用時間 / S3,S8)
--    端末(Drift)がSSOTの生データをサーバーに「提出」したもの。
--    日付境界はユーザーTZ基準の日付(S11)。 (user_id, usage_date) で一意。
-- ============================================================================
create table public.usage_daily (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users(id) on delete cascade,
  usage_date      date        not null,  -- ユーザーTZの「その日」
  -- 対象4アプリ合計の利用分数
  total_minutes   integer     not null check (total_minutes >= 0),
  -- アプリ別内訳 (パッケージ名 -> 分) — 分析/監査用。{"com.x":12,...}
  per_app_minutes jsonb       not null default '{}'::jsonb,
  -- 取得元計算モード (S抽象化): 'exact-minutes'(Android) / 'threshold-achievement'(iOS)
  source_mode     text        not null check (source_mode in ('exact-minutes', 'threshold-achievement')),
  -- サーバーで確定済みか (S8: 確定=サーバー、未確定=端末暫定)
  is_finalized    boolean     not null default false,
  -- S4 異常値ガード: 物理的にありえない値(24h超=1440分超)を破棄した記録
  is_anomaly      boolean     not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, usage_date)
);

create index idx_usage_daily_user_date on public.usage_daily(user_id, usage_date desc);

create trigger trg_usage_daily_updated_at
  before update on public.usage_daily
  for each row execute function public.set_updated_at();

-- ============================================================================
-- 4. baselines (= 基準値スナップショット / S1,S11)
--    各日について「その日に適用された基準値」を記録 (監査・再計算用)。
--    7日平均は本日除く直近7日・欠損日除外、下限30分クランプ(§4-5)。
-- ============================================================================
create table public.baselines (
  id                  uuid        primary key default gen_random_uuid(),
  user_id             uuid        not null references auth.users(id) on delete cascade,
  baseline_date       date        not null,  -- この基準値が適用される日(ユーザーTZ)
  -- クランプ前の生平均(分)。欠損日除外後の平均。データ無しは null
  raw_average_minutes numeric(8,2),
  -- 実際に適用した基準値(分)。下限30分クランプ後
  applied_minutes     integer     not null check (applied_minutes >= 0),
  -- 平均計算に使った実データ日数 (分母)
  sample_days         integer     not null default 0 check (sample_days >= 0),
  stage               public.baseline_stage not null,  -- warmup/provisional/confirmed
  created_at          timestamptz not null default now(),
  unique (user_id, baseline_date)
);

create index idx_baselines_user_date on public.baselines(user_id, baseline_date desc);

-- ============================================================================
-- 5. point_ledger (= ポイント台帳 / S4,S8,S14)
--    冪等加算: idempotency_key = (user_id × ledger_date × source) で一意。
--    同じ日・同じ源の二重加算を物理的に防ぐ。確定済みptの減算上書きはしない(S8)。
--    1日上限480pt(S4)は RPC 側で「倍率適用後の最終値」に対して判定。
-- ============================================================================
create table public.point_ledger (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users(id) on delete cascade,
  ledger_date     date        not null,  -- 対象日(ユーザーTZ)
  source          public.ledger_source not null,
  -- 加算(+)/控除(-)。reduction/warmup/quest_reward/login_bonus は + 、
  -- spend_incubation は - (= 卵への充当)。
  amount          integer     not null,
  -- 内訳メタ(監査): 削減分・適用倍率・クランプ・クエストid 等
  meta            jsonb       not null default '{}'::jsonb,
  -- 冪等キー (= 日付×source。同一日の同一源は1行のみ)
  idempotency_key text        not null,
  created_at      timestamptz not null default now(),
  unique (idempotency_key)
);

create index idx_point_ledger_user_date on public.point_ledger(user_id, ledger_date desc);

-- ============================================================================
-- 6. mofi_species (= Mofi個体マスタ / §4-1) ★master(読み取り公開)
--    15種。レアリティは個体ごと固定(S5)。色違いは別エントリーではなく
--    「個体に色違いが存在する」属性として持ち、捕獲側(mofi_collection)で色を区別。
-- ============================================================================
create table public.mofi_species (
  id            text        primary key,  -- 'slime_01' 等 安定キー
  family        public.mofi_family not null,
  rarity        public.mofi_rarity not null,
  name          text        not null,
  sort_order    integer     not null default 0,
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now()
);

create index idx_mofi_species_rarity on public.mofi_species(rarity) where is_active;

-- ============================================================================
-- 7. drop_tables (= 抽選確率テーブル / §4-2,§4-3,§4-4) ★master(読み取り公開)
--    すべてリモート設定で変更可能(S5)。卵レア→Mofiレア分布をJSONで保持し、
--    色違い率・卵入手分布は app_config に置く。RPC(孵化)はここを参照して抽選。
-- ============================================================================
create table public.drop_tables (
  egg_rarity  public.egg_rarity primary key,
  -- §4-2: {"common":0.80,"rare":0.17,"sr":0.027,"ssr":0.003} (合計1.0)
  distribution jsonb       not null,
  -- バージョン管理(調整履歴の識別)
  version     integer     not null default 1,
  updated_at  timestamptz not null default now()
);

-- ============================================================================
-- 8. app_config (= 経済パラメータの単一情報源 / §4-5,S4,S13,S14) ★master公開
--    UI とサーバーRPC が両方ここを参照。コピペで散らさない。
--    key-value(jsonb) で柔軟に。リモート設定で変更可能。
-- ============================================================================
create table public.app_config (
  key         text        primary key,
  value       jsonb       not null,
  description text,
  updated_at  timestamptz not null default now()
);

-- ============================================================================
-- 9. eggs (= ユーザーの卵 / S5,S6)
--    卵レアリティは入手時確定(孵化時は再抽選しない / S5)。
--    成長ポイントは卵ごとに保持(枠を移動しても保持 / S6)。
-- ============================================================================
create table public.eggs (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users(id) on delete cascade,
  rarity          public.egg_rarity not null,  -- 入手時確定
  -- 累積成長pt (§4-5: 100=ヒビ① / 250=ヒビ② / 500=孵化)
  growth_points   integer     not null default 0 check (growth_points >= 0),
  location        public.egg_location not null default 'storage',
  -- 育成枠スロット番号 (1..3) — incubating かつ アクティブ卵のとき
  slot_index      integer     check (slot_index between 1 and 3),
  -- このユーザーで「いま加点される」アクティブ卵か (S6: 加点は1枠のみ)
  is_active       boolean     not null default false,
  -- 孵化で生まれたMofi(collection)への参照。孵化前は null。
  -- FK は mofi_collection 定義後に alter で付与(下記)。
  hatched_into    uuid,
  acquired_source text,  -- 'starter'(初回ボーナス) / 'quest' / 'premium' / 'standard'
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index idx_eggs_user on public.eggs(user_id);
-- アクティブ卵はユーザーにつき最大1個 (S6: 加点は1枠のみ)
create unique index uq_eggs_one_active on public.eggs(user_id) where is_active;
-- 育成枠スロットはユーザー内で一意 (同一スロットに2卵を防ぐ)
create unique index uq_eggs_slot on public.eggs(user_id, slot_index)
  where location = 'incubating' and slot_index is not null;

create trigger trg_eggs_updated_at
  before update on public.eggs
  for each row execute function public.set_updated_at();

-- ============================================================================
-- 10. mofi_collection (= 図鑑 / S5,S13)
--     孵化で得たMofi。色違いは別図鑑エントリー扱い(S13: 図鑑30エントリー)。
--     コンプ率は (取得済みの distinct (species_id, is_shiny)) / 30 で算出。
-- ============================================================================
create table public.mofi_collection (
  id            uuid        primary key default gen_random_uuid(),
  user_id       uuid        not null references auth.users(id) on delete cascade,
  species_id    text        not null references public.mofi_species(id),
  is_shiny      boolean     not null default false,  -- 色違い(S13: 独立2.0%)
  -- 発見日時 (図鑑表示項目)
  discovered_at timestamptz not null default now(),
  -- 何個目か (同一個体を複数回引いた場合のカウント) — 重複は別行で記録
  obtained_count integer    not null default 1 check (obtained_count >= 1),
  created_at    timestamptz not null default now()
);

create index idx_collection_user on public.mofi_collection(user_id);
-- 図鑑の「初回発見」を1行に集約する設計: (user, species, shiny) で一意にし
-- 重複は obtained_count をインクリメント (RPCで upsert)。
create unique index uq_collection_dex on public.mofi_collection(user_id, species_id, is_shiny);

-- eggs.hatched_into の FK を後付け (mofi_collection 定義後)
alter table public.eggs
  add constraint fk_eggs_hatched_into
  foreign key (hatched_into) references public.mofi_collection(id) on delete set null;

-- ============================================================================
-- 11. quest_definitions (= クエスト定義マスタ) ★master(読み取り公開)
--     日替わり/週替わりの自動生成元。報酬はjsonb。
-- ============================================================================
create table public.quest_definitions (
  id            text        primary key,  -- 'daily_tiktok_30' 等
  kind          public.quest_kind not null,
  title         text        not null,
  description   text,
  -- 達成条件 (例 {"type":"app_under","package":"...","minutes":30})
  condition     jsonb       not null,
  -- 報酬 (例 {"points":50,"gems":0,"egg_rarity":null}) — 固定報酬(倍率非適用/S14)
  reward        jsonb       not null,
  is_active     boolean     not null default true,
  created_at    timestamptz not null default now()
);

-- ============================================================================
-- 12. user_quests (= ユーザーのクエスト進捗)
--     自動生成された当日/当週のインスタンス。進捗・達成・報酬付与の冪等管理。
-- ============================================================================
create table public.user_quests (
  id              uuid        primary key default gen_random_uuid(),
  user_id         uuid        not null references auth.users(id) on delete cascade,
  quest_id        text        not null references public.quest_definitions(id),
  kind            public.quest_kind not null,
  -- 対象期間の開始日(ユーザーTZ)。daily=その日, weekly=週初日。冪等キー要素。
  period_start    date        not null,
  progress        jsonb       not null default '{}'::jsonb,
  is_completed    boolean     not null default false,
  completed_at    timestamptz,
  -- 報酬を付与済みか (S受け入れ: 二重付与しない)
  reward_granted  boolean     not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (user_id, quest_id, period_start)
);

create index idx_user_quests_user on public.user_quests(user_id, period_start desc);

create trigger trg_user_quests_updated_at
  before update on public.user_quests
  for each row execute function public.set_updated_at();

-- ============================================================================
-- 13. streaks (= ストリーク / S2,S14)
--     連続達成日数と最長記録。倍率は基礎ptにのみ適用(S14)。
--     継続条件: その日のデイリー1つ以上達成 or 削減プラス。マイナス/未達でリセット(S2)。
-- ============================================================================
create table public.streaks (
  user_id            uuid        primary key references auth.users(id) on delete cascade,
  current_streak     integer     not null default 0 check (current_streak >= 0),
  longest_streak     integer     not null default 0 check (longest_streak >= 0),
  -- 最後にストリークが加算/維持された日(ユーザーTZ)。重複加算防止。
  last_progress_date date,
  updated_at         timestamptz not null default now()
);

create trigger trg_streaks_updated_at
  before update on public.streaks
  for each row execute function public.set_updated_at();

-- ============================================================================
-- 14. entitlements (= サブスク権利状態 / 信頼境界)
--     RevenueCat の真状態をサーバーが検証して保持。クライアントは読み取りのみ。
--     クライアントの「自分はPro」主張は一切信頼しない。
-- ============================================================================
create table public.entitlements (
  user_id        uuid        primary key references auth.users(id) on delete cascade,
  is_premium     boolean     not null default false,
  -- RevenueCat の app_user_id / entitlement識別
  rc_app_user_id text,
  product_id     text,
  -- 失効日時 (null=非課金 or 無期限)
  expires_at     timestamptz,
  -- 最終Webhook受信時刻 (監査)
  last_synced_at timestamptz,
  updated_at     timestamptz not null default now()
);

create trigger trg_entitlements_updated_at
  before update on public.entitlements
  for each row execute function public.set_updated_at();

-- ============================================================================
-- RLS (Row Level Security)
-- ----------------------------------------------------------------------------
-- 原則:
--   * ユーザーデータ: auth.uid() = user_id の行のみ select/insert/update/delete。
--     ただし「ポイント確定・卵成長・通貨・図鑑・権利」は本来サーバーRPC
--     (security definer) 経由でのみ書き換える。クライアントの直接 update は
--     原則禁止とし、ここでは「本人の select は許可・直接書き込みは絞る」方針。
--   * master/config: 誰でも(anon/authenticated) select 可。書き込みは service_role のみ
--     (= RLS有効化 + ポリシー無し ⇒ service_role 以外は書けない)。
-- ============================================================================

-- --- master / config: 読み取り公開、書き込み不可 ---
alter table public.mofi_species     enable row level security;
alter table public.drop_tables      enable row level security;
alter table public.app_config       enable row level security;
alter table public.quest_definitions enable row level security;

create policy "master_species_read"  on public.mofi_species     for select using (true);
create policy "master_drop_read"      on public.drop_tables      for select using (true);
create policy "master_config_read"    on public.app_config       for select using (true);
create policy "master_quest_def_read" on public.quest_definitions for select using (true);
-- 書き込みポリシーは敢えて作らない ⇒ service_role / マイグレーションのみ書き換え可能。

-- --- profiles ---
alter table public.profiles enable row level security;
-- 本人かつ未削除の行のみ参照
create policy "profiles_select_own" on public.profiles
  for select using (auth.uid() = id);
-- 匿名認証直後の初期行作成は許可 (id は自分のuidに限る)
create policy "profiles_insert_own" on public.profiles
  for insert with check (auth.uid() = id);
-- 本人が変更してよいのは「設定系」のみ。通貨/プール残高はRPC(definer)で変更する想定。
-- 列レベル制御はRLSでは不可のため、ここでは行所有のみ担保し、
-- 通貨改ざん防止は「クライアントは通貨列を更新しない」アプリ規約 + RPC集約で担保。
create policy "profiles_update_own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- --- tracked_apps (本人CRUD可: 対象アプリ設定はユーザー操作) ---
alter table public.tracked_apps enable row level security;
create policy "tracked_apps_all_own" on public.tracked_apps
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- --- usage_daily (本人 select / insert / 未確定の自分の行のみ update) ---
alter table public.usage_daily enable row level security;
create policy "usage_select_own" on public.usage_daily
  for select using (auth.uid() = user_id);
-- 端末からの生データ提出(insert)は本人分のみ
create policy "usage_insert_own" on public.usage_daily
  for insert with check (auth.uid() = user_id);
-- 未確定(is_finalized=false)の自分の行のみ上書き可。確定済みはRPC(definer)のみ。
create policy "usage_update_own_unfinalized" on public.usage_daily
  for update using (auth.uid() = user_id and is_finalized = false)
  with check (auth.uid() = user_id);

-- --- point_ledger (本人 select のみ。書き込みはRPC(definer)経由) ---
alter table public.point_ledger enable row level security;
create policy "ledger_select_own" on public.point_ledger
  for select using (auth.uid() = user_id);
-- insert/update ポリシーを作らない ⇒ クライアント直接加算は不可。冪等加算はRPCで。

-- --- eggs (本人 select / 枠の入れ替え等のupdateは本人可、孵化はRPC) ---
alter table public.eggs enable row level security;
create policy "eggs_select_own" on public.eggs
  for select using (auth.uid() = user_id);
-- 枠移動(location/slot/is_active)はユーザー操作なので本人updateを許可。
-- ただし growth_points / hatched_into の改変は信頼できないため、
-- 本番ではこれらの列更新もRPC集約推奨 (MVP: 行所有で許可し、孵化・加点はRPCのみ実施)。
create policy "eggs_update_own" on public.eggs
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
-- 新規卵の付与はRPC(報酬)で行うため insert ポリシーは作らない。

-- --- mofi_collection (本人 select のみ。登録はRPC(孵化)で) ---
alter table public.mofi_collection enable row level security;
create policy "collection_select_own" on public.mofi_collection
  for select using (auth.uid() = user_id);

-- --- user_quests (本人 select / 進捗updateは本人可、報酬付与はRPC) ---
alter table public.user_quests enable row level security;
create policy "user_quests_select_own" on public.user_quests
  for select using (auth.uid() = user_id);
create policy "user_quests_insert_own" on public.user_quests
  for insert with check (auth.uid() = user_id);
create policy "user_quests_update_own" on public.user_quests
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- --- streaks (本人 select のみ。更新はRPC) ---
alter table public.streaks enable row level security;
create policy "streaks_select_own" on public.streaks
  for select using (auth.uid() = user_id);

-- --- entitlements (本人 select のみ。書き込みはWebhook(service_role)) ---
alter table public.entitlements enable row level security;
create policy "entitlements_select_own" on public.entitlements
  for select using (auth.uid() = user_id);
-- insert/update ポリシー無し ⇒ クライアントは is_premium を一切書けない(信頼境界)。

-- ============================================================================
-- マスタ初期データ (§4 の MVP初期値を投入)
-- ----------------------------------------------------------------------------
-- これらは「経済パラメータの単一情報源」。Android実数値検証後に
-- (drop_tables / app_config の) value を更新して調整する。
-- ============================================================================

-- §4-1 Mofi個体マスタ (15種・レアリティ固定)
-- スライム系: Common2 / Rare2 / SR1 / SSR0
-- 小動物系  : Common2 / Rare2 / SR0 / SSR1
-- ドラゴン系: Common1 / Rare1 / SR2 / SSR1
insert into public.mofi_species (id, family, rarity, name, sort_order) values
  ('slime_01',   'slime',   'common', 'ぷるりん',   1),
  ('slime_02',   'slime',   'common', 'もちすら',   2),
  ('slime_03',   'slime',   'rare',   'きらすら',   3),
  ('slime_04',   'slime',   'rare',   'にじすら',   4),
  ('slime_05',   'slime',   'sr',     'しずくおう', 5),
  ('critter_01', 'critter', 'common', 'ころみ',     6),
  ('critter_02', 'critter', 'common', 'ぽてうさ',   7),
  ('critter_03', 'critter', 'rare',   'まめきつ',   8),
  ('critter_04', 'critter', 'rare',   'ふわりす',   9),
  ('critter_05', 'critter', 'ssr',    'こんげつ',  10),
  ('dragon_01',  'dragon',  'common', 'とかげり',  11),
  ('dragon_02',  'dragon',  'rare',   'ほのおこ',  12),
  ('dragon_03',  'dragon',  'sr',     'らいりゅう',13),
  ('dragon_04',  'dragon',  'sr',     'こおりば',  14),
  ('dragon_05',  'dragon',  'ssr',    'てんりゅう',15);

-- §4-2 卵レアリティ別 → Mofiレアリティ抽選確率 (各行合計1.0)
insert into public.drop_tables (egg_rarity, distribution, version) values
  ('normal', '{"common":0.80,"rare":0.17,"sr":0.027,"ssr":0.003}'::jsonb, 1),
  ('rare',   '{"common":0.55,"rare":0.35,"sr":0.08, "ssr":0.02}'::jsonb,  1),
  ('epic',   '{"common":0.25,"rare":0.45,"sr":0.22, "ssr":0.08}'::jsonb,  1),
  ('legend', '{"common":0.05,"rare":0.35,"sr":0.40, "ssr":0.20}'::jsonb,  1);

-- §4-3,§4-4,§4-5 経済パラメータ (単一情報源 / リモート設定)
insert into public.app_config (key, value, description) values
  ('shiny_rate',         '0.02'::jsonb,
    'S13 色違い出現率 (1/50)。個体確定後の独立判定'),
  ('point_per_minute',   '1'::jsonb,
    '§4-5 換算レート 1分削減=1pt'),
  ('daily_point_cap',    '480'::jsonb,
    'S4 1日ポイント上限。倍率適用後の最終値で判定'),
  ('baseline_floor_min', '30'::jsonb,
    '§4-5 基準値の下限クランプ(分)'),
  ('baseline_window_days','7'::jsonb,
    'S11 基準値=本日除く直近N日平均(欠損日除外)'),
  ('egg_thresholds',     '{"crack1":100,"crack2":250,"hatch":500}'::jsonb,
    '§4-5 卵成長しきい値(累積pt)'),
  ('warmup_grants',      '{"day1":200,"day2":300}'::jsonb,
    'S1 初回ボーナス卵への自動付与(合計500ptで孵化保証)'),
  ('streak_multipliers', '[{"days":1,"mult":1.0},{"days":3,"mult":1.2},{"days":7,"mult":1.5},{"days":30,"mult":2.0}]'::jsonb,
    'S14 ストリーク倍率(基礎ptのみ適用)。間の日数は直下段を適用'),
  ('pooled_points_max_days','3'::jsonb,
    'S6 アクティブ卵不在時のpt最大プール日数'),
  ('egg_drop_distribution',
    '{"standard":{"normal":0.78,"rare":0.18,"epic":0.035,"legend":0.005},"weekly_quest":{"normal":0.50,"rare":0.35,"epic":0.13,"legend":0.02},"premium":{"normal":0.0,"rare":0.40,"epic":0.45,"legend":0.15}}'::jsonb,
    '§4-4 卵の入手レアリティ分布(入手経路別)'),
  ('dex_total_entries',  '30'::jsonb,
    'S13 図鑑総エントリー数(15種×2色)。コンプ率の分母'),
  ('target_packages_android',
    '["com.zhiliaoapp.musically","com.instagram.android","com.google.android.youtube","com.twitter.android"]'::jsonb,
    'S3 MVP対象4SNSのAndroidパッケージ名(TikTok/Instagram/YouTube/X)');

-- ============================================================================
-- 補足: サーバーRPC (孵化/報酬/通貨/確定) は後続マイグレーションで定義する。
--   * fn_finalize_day(user, date)      : 利用生データ→基準差分→倍率→480cap→台帳冪等加算
--   * fn_apply_growth(user, egg, pts)  : アクティブ卵へ成長pt加算(spend_incubation控除)
--   * fn_hatch_egg(user, egg)          : 原子的孵化(drop_tables参照→個体均等→shiny判定→図鑑upsert)
--   * fn_grant_quest_reward(user, uq)  : reward_granted冪等チェック付き報酬付与
--   * fn_spend_currency(user, kind, n) : 残高検証つき原子的通貨消費(オフライン消費不可/S8)
--   いずれも security definer + 冪等 + 単一情報源(app_config/drop_tables)参照で実装。
-- ============================================================================

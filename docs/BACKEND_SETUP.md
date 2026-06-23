# Moffy バックエンド構築手順書 (BACKEND_SETUP.md)

> 作成: 開発部署 (engineer) / 対象: Supabase プロジェクト作成 → migration 適用 →
> RPC 権限確認 → 抽選分布検証 → クライアント接続。
> 専門用語は初出時にインラインで日本語説明。

このドキュメントは、コア経済の心臓部であるサーバーRPC
(`supabase/migrations/0002_economy_rpcs.sql`) を**ライブDBに適用し、検証し、
Flutter クライアントから接続する**までの手順をまとめる。

現状、開発環境にライブDB (= 実際に動く Supabase インスタンス) が無いため、
SQL は構文・冪等性・権限を自己レビューで担保した状態であり、**未実行**。
本手順に従えば、Supabase プロジェクトが用意でき次第そのまま適用・検証できる。

---

## 0. 前提ツール

- Supabase アカウント (https://supabase.com)
- `supabase` CLI (`npm i -g supabase` または公式バイナリ) … `supabase db push` 用
- もしくは `psql` (PostgreSQL クライアント) … 直接 `-f` で流す場合
- Flutter SDK (このリポジトリで使用中のもの)

---

## 1. Supabase プロジェクト作成

1. Supabase ダッシュボードで新規プロジェクトを作成 (リージョンは日本ユーザー向けに
   `Northeast Asia (Tokyo)` 推奨 / S11 のTZ運用と相性可)。
2. プロジェクトの以下を控える (後でクライアント接続に使う):
   - **Project URL** (例 `https://xxxx.supabase.co`) → `SUPABASE_URL`
   - **anon public key** (公開鍵 / RLS前提で安全に公開できる値) → `SUPABASE_ANON_KEY`
   - **service_role key** (サーバー秘密鍵) … **絶対にクライアントへ入れない**。
     migration 適用・管理操作専用。`.env` 等でローカルに保持し Git に出さない。
3. **匿名認証 (Anonymous Sign-In) を有効化** (S10):
   Dashboard → Authentication → Providers → "Anonymous" を ON。

---

## 2. Migration 適用

### 2-A. supabase CLI を使う場合 (推奨)

```bash
# リポジトリ直下で
supabase link --project-ref <your-project-ref>
supabase db push
```

`supabase/migrations/` 配下の `0001_init.sql` → `0002_economy_rpcs.sql` →
`0003_warmup_grants.sql` → `0004_security_hardening.sql` がファイル名順に適用される。

> `0003_warmup_grants.sql` は QA 差し戻し (F-01 / F-03) の追補:
> - **F-01**: `fn_claim_warmup(p_day)` (ウォームアップ自動付与 Day1=200/Day2=300 +
>   初回ボーナス卵生成・充当)。
> - **F-03**: `profiles` の SELECT RLS を `deleted_at is null` 条件付きへ更新 +
>   `fn_purge_deleted_accounts()` (30日経過の論理削除アカウントを物理削除 / pg_cron 運用)。

> `0004_security_hardening.sql` は信頼境界の物理的な締め直し (CEO承認済み):
> - **G-1**: `baselines` の RLS 有効化 + 本人限定 select ポリシー (0001 の積み残し)。
> - **G-2**: `profiles` の列レベル UPDATE 制限。authenticated が直接更新できるのは
>   `display_name` / `timezone` のみ (通貨・プール・削除・連携状態は RPC/Webhook 専管)。
> - **G-3**: `eggs` の列レベル UPDATE 制限。authenticated が直接更新できるのは
>   `slot_index` / `location` / `is_active` (枠操作) のみ (成長・孵化は RPC 専管)。
> - definer 関数 (所有者権限) は列レベル GRANT / RLS の対象外のため、全列書込みを継続。

### 2-B. psql で直接流す場合

```bash
# DATABASE_URL は Dashboard → Project Settings → Database → Connection string (URI)
psql "$DATABASE_URL" -f supabase/migrations/0001_init.sql
psql "$DATABASE_URL" -f supabase/migrations/0002_economy_rpcs.sql
psql "$DATABASE_URL" -f supabase/migrations/0003_warmup_grants.sql
psql "$DATABASE_URL" -f supabase/migrations/0004_security_hardening.sql
```

> **冪等性**: どちらも再実行を想定。0002 の関数は `create or replace`、権限は
> `revoke`/`grant` で再付与安全。0004 は policy を `drop policy if exists` 先行で
> 再作成し、`enable rls` / `revoke` / `grant` も再実行安全。0001 を再実行する場合は
> 既存オブジェクトの `drop` が必要 (初回はクリーンDBに適用すること)。

---

## 3. RPC 権限の確認 (信頼境界の検証)

migration 適用後、**最小権限 (authenticated のみ・anon 不可・内部ヘルパ非公開)** に
なっているかを確認する。psql で:

```sql
-- 各関数の実行権限を確認 (authenticated に付いているべき公開RPC)
select
  p.proname as func,
  pg_get_function_identity_arguments(p.oid) as args,
  has_function_privilege('authenticated', p.oid, 'execute') as auth_can,
  has_function_privilege('anon', p.oid, 'execute')          as anon_can,
  p.prosecdef as is_security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'fn_finalize_day','fn_hatch_egg','fn_grant_quest_reward',
    'fn_spend_currency','fn_delete_account','fn_claim_warmup',
    'fn_purge_deleted_accounts',
    'fn_apply_growth','cfg','cfg_int','cfg_num','streak_multiplier')
order by p.proname;
```

**期待結果 (= 合否基準)**:

| 関数 | authenticated execute | anon execute | security definer |
|---|---|---|---|
| `fn_finalize_day` | **true** | false | **true** |
| `fn_hatch_egg` | **true** | false | **true** |
| `fn_grant_quest_reward` | **true** | false | **true** |
| `fn_spend_currency` | **true** | false | **true** |
| `fn_delete_account` | **true** | false | **true** |
| `fn_claim_warmup` (公開RPC / F-01) | **true** | false | **true** |
| `fn_purge_deleted_accounts` (バッチ専用 / F-03) | **false** | false | **true** |
| `fn_apply_growth` (内部専用) | **false** | false | **true** |
| `cfg` / `cfg_int` / `cfg_num` (内部専用) | **false** | false | true |
| `streak_multiplier` (内部専用) | **false** | false | true |

- anon が true の行があれば**情報漏洩リスク** → 0002/0003 の revoke を見直す。
- 内部ヘルパ (cfg* / fn_apply_growth / streak_multiplier) が authenticated=true なら
  クライアントから直接呼べてしまう → revoke 漏れ。
- `fn_purge_deleted_accounts` が authenticated=true なら**重大** (任意ユーザーが他人の
  退会済みアカウントを物理削除できてしまう) → 0003 で grant していないことを確認。
  service_role / 所有者 (postgres) のみ実行可。

また、書込みテーブルにクライアント書込ポリシーが**無い**ことを再確認 (0001由来):

```sql
select tablename, policyname, cmd
from pg_policies
where schemaname = 'public'
  and tablename in ('point_ledger','mofi_collection','entitlements')
order by tablename, cmd;
-- point_ledger/mofi_collection/entitlements は select ポリシーのみ存在すべき
-- (insert/update/delete ポリシーが無い = クライアント直接書込み不可 = 信頼境界OK)
```

---

## 4. 抽選分布検証 (§4 理論値との突合)

```bash
psql "$DATABASE_URL" -f supabase/tests/distribution_check.sql
```

検証内容 (`supabase/tests/distribution_check.sql`):

1. **§4-2 卵レア→Mofiレア分布**: 各卵レア (normal/rare/epic/legend) で N=20万回試行し、
   common/rare/sr/ssr の実測比率が理論値 ±許容内か。
2. **§4-3 色違い率**: shiny_rate (2.0%) が実測で収束するか。
3. **§4-2 後段 個体均等**: SR個体3種が各約1/3か。
4. **drop_tables 各行合計=1.0** の整合。

**合否**: いずれかのセルが許容外なら `raise exception` で停止する。最後に
`✅ distribution_check.sql 完了` が出れば全PASS。

> 注: このスクリプトは fn_hatch_egg の**抽選の数学的核**を同一ロジックで再現して
> 検証する (RPC本体は副作用を伴い auth.uid()/実データに依存するため)。
> ロジックは 0002 の fn_hatch_egg と1:1で一致させてあるので、**RPC本体を修正したら
> 本スクリプトの累積判定も必ず同期**すること。

### 4-A. RPC本体のスモークテスト (任意・実ユーザーで)

実ユーザー文脈での孵化を1回確認したい場合 (要 service_role か RLS文脈):

```sql
-- 例: テストユーザーを匿名作成 → 卵を500ptで用意 → fn_hatch_egg。
-- (実際の auth.uid() 文脈が必要なため、Supabase の SQL Editor では
--  set request.jwt.claims でユーザーを偽装するか、クライアント経由で呼ぶ)
```

実運用では §5 のクライアント接続後、アプリから孵化して図鑑反映を見るのが確実。

---

## 5. クライアント接続 (`--dart-define`)

Flutter ビルド時に Supabase の接続情報を注入する。**ソースに秘密を埋め込まない**
(組織ルール / `lib/core/config/env.dart` 参照)。

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon public key>
```

- `Env.hasSupabase` が true になり、各リポジトリの DI が
  **Supabase 実装** (`SupabaseEggRepository` 等) に切り替わる。
- 未指定なら `Env.hasSupabase=false` で**モック実装にフォールバック** (PoC/UI確認用)。
- `--dart-define` は CI/CD では `--dart-define-from-file=env.json` でまとめても可
  (env.json は .gitignore 済みであること)。

### 接続後の動作確認 (5状態)

| 確認 | 期待 |
|---|---|
| 図鑑画面 | `mofi_collection` の本人行が反映される (未発見はシルエット) |
| たまご画面 | `eggs` の本人行が育成3枠/保管に整列、`pooled_points` 表示 |
| 孵化 | `fn_hatch_egg` がサーバー抽選し、結果が演出+図鑑に反映 |
| クエスト受取 | `fn_grant_quest_reward` 後に残高/ストリークが**サーバー値**で更新 |
| オフライン | 孵化/受取/退会ボタンがグレーアウト (S8) |
| 退会 | `fn_delete_account` でサーバーデータ削除 → サインアウト (S12) |

### 接続後の動作確認 (F-01 ウォームアップ)

| 確認 | 期待 |
|---|---|
| 初回起動 (Day1) | `home_repository.claimWarmupIfNeeded(1)` → `fn_claim_warmup(1)` で +200pt、`acquired_source='starter'` の卵が育成枠1に生成され growth_points=200 |
| 翌日 (Day2) | `claimWarmupIfNeeded(2)` → `fn_claim_warmup(2)` で +300pt、starter 卵 growth_points=500 (=孵化保証) |
| 同じ day を再呼出 | 冪等 (生涯1回キー)。`already_claimed=true` / `granted=0` で残高・卵は不変 |
| Mock / オフライン | `claimWarmupIfNeeded` は no-op (null)。warmup はサーバー責務のため何もしない |

> **F-01 クライアント配線**: `HomeRepository.claimWarmupIfNeeded(int day)`
> (`lib/features/home/data/home_repository.dart`) が `Env.hasSupabase` かつオンライン時のみ
> `fn_claim_warmup` を呼び、`WarmupClaimResult` (`lib/core/sync/finalize_models.dart`)
> にパースする。冪等キーが生涯1回 (uid×'warmup'×day) なので、初回オンボーディングで
> Day1、翌日初回起動で Day2 を呼べばよい (二重呼び出しはサーバーが冪等スキップ)。
> どの画面遷移で呼ぶか (オンボーディング完了時 / 日次初回起動時) の駆動配線は、UI フローの
> 実装に合わせて後続パスで接続する (本パスはデータ層の「口」を用意)。

---

## 5-B. 退会アカウントの 30日パージ (F-03 / pg_cron)

退会 (`fn_delete_account`) は **論理削除** (`profiles.deleted_at` をセット) のみ行い、
即時の物理削除はしない (誤操作・サポート復旧の余地を 30日 残す / S12)。30日経過分の
物理削除は `fn_purge_deleted_accounts()` (service_role 専用) を **pg_cron で日次起動**する。

### 5-B-1. pg_cron 拡張を有効化

Supabase Dashboard → Database → Extensions で **`pg_cron`** を ON にする
(または SQL で):

```sql
create extension if not exists pg_cron;
```

### 5-B-2. 日次ジョブを登録

毎日 03:15 (UTC) にパージを実行する例:

```sql
-- 既存の同名ジョブがあれば作り直す (再登録安全)。
select cron.unschedule('purge_deleted_accounts')
  where exists (select 1 from cron.job where jobname = 'purge_deleted_accounts');

select cron.schedule(
  'purge_deleted_accounts',
  '15 3 * * *',                         -- 毎日 03:15 UTC
  $$select public.fn_purge_deleted_accounts();$$
);
```

- `fn_purge_deleted_accounts()` は `security definer` で所有者 (postgres) 権限実行のため、
  pg_cron (postgres ロールで実行) から呼べる。**authenticated には grant していない**
  (クライアントから他人の退会済みアカウントを消せない)。
- 動作確認 (手動実行):

  ```sql
  -- 30日以上前に deleted_at が立っている行があれば物理削除される。
  select public.fn_purge_deleted_accounts();   -- => {"purged": N}
  ```

- ジョブ実行履歴の確認:

  ```sql
  select jobid, runid, status, return_message, start_time, end_time
  from cron.job_run_details
  where command like '%fn_purge_deleted_accounts%'
  order by start_time desc
  limit 20;
  ```

> **退会後の挙動**: `profiles` の SELECT RLS は `deleted_at is null` 条件付き (0003)。
> 論理削除直後から本人でも自分のプロフィールが見えなくなり (= 退会済み扱い)、
> クライアントは `fn_delete_account` 成功後に `signOut` 済み (account_repository)。

---

## 6. トラブルシュート

| 症状 | 原因/対処 |
|---|---|
| RPC が `permission denied for function` | §3 の grant が未適用。0002 末尾の grant を再実行。 |
| 孵化が `not_ready_to_hatch` | 卵の growth_points < hatch しきい値 (500)。確定/成長が先。 |
| `unauthorized` (errcode 28000) | 匿名認証セッションが無い。S10 の匿名サインインを確認。 |
| `app_config` 取得失敗でも起動する | 仕様 (defaults フォールバック / `remote_config.dart`)。 |
| 分布検証が稀に1セルFAIL | N を増やす (低確率セルの揺らぎ)。連続FAILなら確率seed見直し。 |

---

## 7. 既知の残課題 (本パスのスコープ外)

- **fn_finalize_day の呼び出し配線**: ✅ 配線済み。
  - 提出→確定: `lib/core/sync/usage_sync_repository.dart` の `SupabaseUsageSyncRepository`
    が usage_daily へ upsert (本人insert / 未確定update / 0001 RLS) → `fn_finalize_day(p_date)`
    を呼び、`FinalizeDayResult` (`lib/core/sync/finalize_models.dart`) にパースする。
  - 駆動: `SyncService._submitUsageDaily` (`sync_service.dart`) が sync_queue の
    `submitUsageDaily` op を処理し、オンライン復帰エッジ (`syncOnReconnectProvider`) で起動。
    op は `SyncService.enqueueUsageSubmission(UsageDailyDraft)` で積む。
  - S8 競合解決: 確定pt(today分) とローカル暫定ptを `ConflictResolver.resolveConfirmedPoints`
    に通し「確定済みptを減らす上書きはしない」(増える方向のみ反映 / already_finalized=加算0は維持)。
  - 確定値取得: `home_repository.loadServerSnapshot()` が profiles (残高/pooled) と
    アクティブ卵を本人select する。
  - 残: Drift 永続化 (生データ/キャッシュSSOT) と、hatchEgg/grantQuestReward/spendCurrency の
    sync_queue ディスパッチ配線は後続 (各 feature の Supabase リポジトリには実装済み)。
- **退会の論理削除 (F-03)**: ✅ 実装済み。`fn_delete_account` は `profiles.deleted_at` を
  立てる論理削除に変更。物理削除は `fn_purge_deleted_accounts()` を pg_cron で日次起動
  (§5-B)。`profiles` SELECT RLS は `deleted_at is null` 条件付き (0003)。
- **ウォームアップ自動付与 (F-01)**: ✅ サーバー実装済み (`fn_claim_warmup` / 0003) +
  クライアント「口」配線済み (`home_repository.claimWarmupIfNeeded`)。
  残: どの画面遷移で `claimWarmupIfNeeded(1|2)` を駆動するか (オンボーディング/日次初回起動) の
  UI 配線は後続。
- **アカウント連携 (linkProvider)**: Apple/Google ネイティブサインインの配線は後続
  (現状は `UnsupportedFailure` で「準備中」を明示)。
- **課金 (RevenueCat) → entitlements 更新 Webhook**: 別パス。entitlements は
  service_role (Webhook) のみ書込む設計 (0001 / 信頼境界)。

# Moffy オーナー作業ガイド（あなたが対応する項目の手順）

> 実ローンチに向けて**オーナー（あなた）側でしか実施できない作業**を、優先順・依存順にまとめた手順書。
> 詳細は `BACKEND_SETUP.md` / `IAP_SETUP.md` / `legal/` を参照。コードは private repo `lanlangh/moffy` に反映済み。

## 全体像（やる順番）
1. **A. Supabase プロジェクト**（経済バックエンドを実DBで検証）← 最優先
2. **B. RevenueCat 突合 + キー**（課金を実動作）
3. **C. 法務文書の記入 + 公開**（審査ブロッカー）
4. **D. Apple/Google アカウント整備**
5. **E.（任意）ローカルビルド環境 / 観測キー**（CIで代替中）

---

## A. Supabase（作成 → 適用 → 検証）

### A-0. 無料プラン上限について（重要）
Supabase 無料プランは **1アカウント（オーナー）あたり有効プロジェクト2つまで**。既に2つある場合は新規作成できない。対処（いずれか）:
- **既存の未使用プロジェクトを Pause**（Dashboard → 対象プロジェクト → Settings → General → Pause）→ スロットが空く。後で Resume 可。
- **Moffy専用に別のSupabaseアカウント**（例: heartsoffice ドメインのメール）を作り、そこで作成（新アカウントは別枠の無料2つ）。会社プロダクトとして所有を分離でき推奨。
- **不要プロジェクトを Delete**（不可逆・データ消失。捨ててよい場合のみ）。
- **Pro へアップグレード**（$25/月〜）→ 2つ制限が外れる。本番運用を見据えるなら有力。

### A-1. プロジェクト作成
1. リージョン **Northeast Asia (Tokyo)** 推奨。
2. **Settings → API** で控える: Project URL → `SUPABASE_URL` / anon public key → `SUPABASE_ANON_KEY` / service_role key（**アプリに入れない**・適用専用）。
3. **Authentication → Providers → Anonymous を ON**（S10）。

### A-2. マイグレーション適用（どちらか）
**CLI（推奨）**
```bash
npm i -g supabase
cd <リポジトリ直下>
supabase link --project-ref <your-project-ref>
supabase db push     # 0001→0002→0003→0004→0005 の順で適用
```
**SQL Editor（CLIなし）**: `0001_init.sql`→`0002_economy_rpcs.sql`→`0003_warmup_grants.sql`→`0004_security_hardening.sql`→`0005_economy_exploit_fix.sql` をこの順で貼って実行（`supabase/migrations/`、初回はクリーンDB）。

### A-3. 権限検証
`BACKEND_SETUP.md §3` のSQLを実行し、期待表（公開RPC=authenticated true/anon false、内部ヘルパ=false、`fn_purge_deleted_accounts`=authenticated false）と一致を確認。

### A-4. 抽選分布検証
`psql "<Connection string>" -f supabase/tests/distribution_check.sql`（SQL Editor貼付でも可）。最後に「✅ distribution_check.sql 完了」が出れば §4 確率どおり。

### A-5.（推奨）H4-1 実証
SQL Editor で:
```sql
set local role authenticated;
-- 42501(permission denied for column is_finalized)等で失敗するのが正解
insert into public.usage_daily(user_id, usage_date, total_minutes, per_app_minutes, source_mode, is_finalized)
values ('00000000-0000-0000-0000-000000000000', current_date, 0, '{}', 'exact-minutes', true);
reset role;
```
エラーになれば成功（確定フラグ偽造不可）。成功してしまうなら 0004 G-4 の適用漏れ。

### A-6. pg_cron（退会30日パージ）
`BACKEND_SETUP.md §5-B` のとおり `pg_cron` 拡張ON → `fn_purge_deleted_accounts()` を日次登録。

### A-7. アプリ接続
URL/anon key を B-4 の dart-define で渡して起動。

---

## B. RevenueCat 突合 + 公開SDKキー

### B-1. Moffy専用の突合（既存3アプリと混同しない）
`lib/core/constants/pricing.dart` の `RevenueCatIds` と**完全一致**させる:
| 種別 | コードの値 | 作業 |
|---|---|---|
| Entitlement | `premium` | この識別子で作成 |
| Offering | `default`（current） | 既定オファリングを `default` 名で |
| 商品(月額) | `moffy_premium_monthly` | ASC/Play の Product ID をこれに |
| 商品(年額) | `moffy_premium_yearly` | 同上 |
| Package | `$rc_monthly` / `$rc_annual` | Offering内に月/年を割当 |
価格は ASC/Play 側で 月¥480 / 年¥4,800 / 7日無料（PRICING.md）。差異が出たら `RevenueCatIds` を1箇所直すだけ（私が対応可）。

### B-2. 公開SDKキー取得
RevenueCat → API keys → 公開SDKキー（Android `goog_...` / iOS `appl_...`）。**Secretキー `sk_...` はアプリに入れない**（Webhook用）。

### B-3. Webhook（サーバー側・未実装＝開発タスク）
プレミアム判定の正は `entitlements` テーブル。RevenueCat Webhook→Supabase Edge Functionの配線は未実装。Supabase作成後に私が実装可。

### B-4. ビルドにキー注入して起動
```bash
flutter run \
  --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=<anon public key> \
  --dart-define=REVENUECAT_ANDROID_KEY=goog_xxx \
  --dart-define=REVENUECAT_IOS_KEY=appl_xxx
```
（CIは `--dart-define-from-file=env.json`、env.jsonは.gitignore済）

### B-5. サンドボックス購入テスト（必須・IAP_SETUP §5）
実機+サンドボックスで「購入→シート→**完了**」まで。表示だけでは不十分。

---

## C. 法務文書の記入 + 公開

ドラフト: `docs/legal/{privacy_policy,terms_of_service,tokushoho}.md`。`【要記入：〜】`を実値に置換 → 公開 → URL反映。

### C-1. 記入項目（3文書で統一）
事業者名 / 代表者(運営統括責任者) / 所在地 / 電話番号 / 問い合わせメール / アカウント削除用メール / 個人情報保護管理責任者 / 管轄裁判所 / 対応OS・バージョン / 公開日 / 公開URL /（任意）法人番号・適格請求書登録番号。

### C-2. 公開
3文書を公開URL（Notion公開ページ/独自サイト/GitHub Pages 等）に。**ストア登録URLと完全一致**、問い合わせメールは審査時に**受信可能**に。

### C-3. URL反映先（3箇所）
`legal_links.dart`（アプリ内）/ ストアのプライバシーURL欄 / `docs/ASO.md` 説明文末尾。URL確定後、私がコード反映可。

---

## D. Apple / Google アカウント整備
1. **Apple 小規模事業者プログラム申請**（30%→15%・承認制・ローンチ前に）。
2. **有料App契約 "Active"** 確認（未署名だとIAP不動作）。ASC→ビジネス→契約。
3. Google Play **データ安全性フォーム**を `docs/legal/STORE_DATA_SAFETY.md` どおり記入、`PACKAGE_USAGE_STATS` 目的をプラポリと一致。

---

## E.（任意）ローカルビルド / 観測
- ローカル `flutter` は企業WDACでブロック中（CIで代替・緑維持）。ローカル実行が必要なら IT に配置先の WDAC許可を依頼＋Android SDK。
- 観測（Sentry/PostHog）は**配線済み**（未設定時は Noop で安全にフォールバック）。あなたの作業は DSN/APIキーの取得と dart-define での注入のみ。**手順・キー取得・「送らないデータ」原則・イベント一覧は [OBSERVABILITY_SETUP.md](OBSERVABILITY_SETUP.md) を参照**。

---

## 私（Claude/組織）が引き取れること
- `RevenueCatIds` 実値差し替え / 法務URLの `legal_links.dart` 反映 / RevenueCat Webhook実装 / 観測の配線 / Supabase作成後のライブ最終調整。

> まずは **A（Supabase）** から。詰まったらエラーメッセージを貼ってください、診断します。

# iOS App Privacy（プライバシー栄養ラベル）回答シート — Moffy v1.0

App Store Connect ＞ アプリ ＞ 「App のプライバシー」で入力する内容。**実装と現行の提出ビルド（`ios-build.yml`）で実際に収集する情報のみ**を宣言する（過少申告=リジェクト直結／過剰申告=不正確）。作成 2026-07-15。

## 前提（このビルドが実際に何を収集するか）
- **Supabase（匿名認証・確定集計値の保存）= 稼働**（`--dart-define=SUPABASE_*` 注入）。
- **RevenueCat（購読状態）= 稼働**（iOS公開キーは `env.dart` に既定値で焼き込み）。
- **Sentry（クラッシュ）/ PostHog（行動分析）= 無効（Noop）**：`ios-build.yml` は `SENTRY_DSN`/`POSTHOG_API_KEY` を注入しない → `Env.hasSentry/hasPostHog=false`。**＝クラッシュ/行動分析データは収集しない。**
- **広告なし・トラッキングなし**：iOSは `ads_platform_io` でAdMobを初期化しない。`NSUserTrackingUsageDescription` なし＝ATTプロンプトを出さない。**Ad ID(IDFA)は不使用。**
- **スクリーンタイム**：対象アプリは不透明トークン（どのアプリか識別不可）。**生の利用時間は端末内のみ**。サーバーへ出るのは「削減量・ポイント等の集計値」のみ（匿名IDに紐づく）。

## Apple の質問への回答

### 「トラッキングに使用されるデータ」
**なし**（Do NOT enable App Tracking / no data used to track）。iOSは広告なし・IDFA不使用・第三者トラッキングなし。

### 「あなたと紐付けられたデータ（Data Linked to You）」
以下3種。いずれも用途=**アプリの機能（App Functionality）**、トラッキング=いいえ。

| データ種別（Apple区分） | 具体 | 用途 |
|---|---|---|
| **Identifiers → User ID** | Supabase の匿名ユーザーID（初回起動で自動発行） | アプリの機能（アカウント・進行のクラウド保存/復元） |
| **Purchases → Purchase History** | 購読の購入/更新/解約状態（RevenueCat経由・product_id/期限）。※カード番号等の決済情報は収集しない | アプリの機能（プレミアム判定） |
| **Usage Data → Other Usage Data** | スクリーンタイムの削減量・ゲーム内ポイント/進行の集計値（匿名IDに紐づけてクラウド保存） | アプリの機能（育成ゲームのコアループ） |

### 「あなたと紐付けられていないデータ（Data Not Linked to You）」
**なし**（Sentry/PostHog無効のため）。

### 収集しないもの（明示）
連絡先情報（メール等）※アカウント連携はv1.0無効／位置情報／連絡先／写真・メッセージ等のコンテンツ／**Ad Data・Device ID(IDFA)**／**Crash Data・Performance Data（Sentry無効）**／**Product Interaction等の分析（PostHog無効）**／健康・金融（決済情報）。

---

## ⚠️ 入力前の整合チェック（重要）
1. **プライバシーポリシー（Notion）は Sentry/PostHog を「利用中」と記載**しているが、現ビルドは無効。栄養ラベルは実収集に合わせて上記のとおり**クラッシュ/分析を宣言しない**（ラベルはポリシーの部分集合＝Appleは許容）。将来キーを注入したら、ラベルに Crash Data / Product Interaction を追加する（下記「代替」）。
2. **プライバシーポリシーのiOS追記**：現ポリシーは利用時間取得を「Android(UsageStatsManager)」中心に記述し、**iOSのFamilyControls/不透明トークン経路が未記載**。iOS提出に合わせ「iOSはユーザーが選んだアプリを不透明トークンで扱い、どのアプリかは識別しない」旨を追記推奨（審査の実装乖離・2.3.10リスク低減）。
3. **広告記述**：ポリシー§2/§8は「広告なし」。**iOSは正**。ただし同一URLをAndroid（AdMobあり）でも使うため、両OS差（Android=広告/広告ID、iOS=広告なし）を明記して整合させること（Android側の乖離解消）。

## 代替：観測性（Sentry/PostHog）をiOSでも有効化する場合
`ios-build.yml` の archive 前 `flutter build ios` に `--dart-define=SENTRY_DSN=… --dart-define=POSTHOG_API_KEY=…`（GitHub Secret）を追加。その場合ラベルに追加：
- **Diagnostics → Crash Data / Performance Data**（Not Linked・App Functionality）＝Sentry
- **Usage Data → Product Interaction**（Linked・Analytics）＝PostHog（匿名IDにidentifyするためLinked）

利点＝公開ポリシーの記載と一致＋公開初日からクラッシュ監視。判断はオーナー（キー保有・観測性を初日から回すか）。

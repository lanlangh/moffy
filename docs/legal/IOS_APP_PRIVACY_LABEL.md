# iOS App Privacy（プライバシー栄養ラベル）回答シート — Moffy v1.0

App Store Connect ＞ アプリ ＞ 「App のプライバシー」で入力する内容。**実装と提出ビルドで実際に収集する情報のみ**を宣言する（過少申告=リジェクト直結／過剰申告=不正確）。更新 2026-07-16（**オーナー裁定：iOSも広告あり／非パーソナライズ**）。

## 前提（このビルドが実際に何を収集するか）
- **Supabase（匿名認証・確定集計値の保存）= 稼働**。
- **RevenueCat（購読状態）= 稼働**（iOS公開キーは `env.dart` 既定値）。
- **Google AdMob（無料プランのバナー広告）= 稼働**。**iOSは非パーソナライズ広告のみ**＝`AdRequest(nonPersonalizedAds: true)`・**ATTを求めず（`NSUserTrackingUsageDescription` なし）・IDFAをトラッキング目的で使わない**。⇒栄養ラベルの**「トラッキング＝なし」**を維持。
- **Sentry / PostHog = 無効（Noop）**：`ios-build.yml` は鍵を注入しない → クラッシュ/行動分析は**収集しない**。
- **スクリーンタイム**：対象アプリは不透明トークン（識別不可）。生の利用時間は端末内のみ。サーバーへ出るのは削減量・ポイント等の集計値（匿名IDに紐づく）。

## Apple の質問への回答

### 「トラッキングに使用されるデータ」＝ **なし**
iOSは**非パーソナライズ広告**でATT不要・IDFA不使用のため、トラッキングには該当しない（App Tracking は有効化しない）。

### 「あなたと紐付けられたデータ（Data Linked to You）」＝ 3種（用途=アプリの機能・トラッキング=いいえ）
| データ種別（Apple区分） | 具体 | 用途 |
|---|---|---|
| **Identifiers → User ID** | Supabase 匿名ユーザーID | アプリの機能 |
| **Purchases → Purchase History** | 購読の購入/更新/解約状態（RevenueCat。カード情報は不収集） | アプリの機能 |
| **Usage Data → Other Usage Data** | スクリーンタイム削減量・ポイント/進行の集計値 | アプリの機能 |

### 「あなたと紐付けられていないデータ（Data Not Linked to You）」＝ AdMob広告SDKが収集する分
**⚠️正確な項目は Google 公式の「AdMob iOS プライバシー（App Privacy details）」の最新表に合わせて申告すること**（Googleが SDK の収集項目を随時更新するため）。一般に**非パーソナライズ**設定の AdMob が収集し得るのは以下（いずれも **Not Linked・トラッキング=いいえ**、用途は主に「第三者広告」）：
| データ種別 | 用途 |
|---|---|
| **Identifiers → Device ID**（IDFAではなく端末識別情報） | 第三者広告 |
| **Usage Data → Advertising Data / Product Interaction** | 第三者広告・分析 |
| **Diagnostics → Crash Data / Performance Data / Other Diagnostic Data** | アプリの機能 |
| **Location → Coarse Location**（おおよその位置・AdMobが取得する場合） | 第三者広告 |

> 参照（オーナー確認）：AdMob ヘルプ「App Store のプライバシーに関する質問への回答方法（iOS）」の SDK 収集データ一覧。ここに載る項目を上表に反映する。**非パーソナライズのため「トラッキングに使用」は付けない。**

### 収集しないもの（明示）
連絡先情報（メール等・アカウント連携v1.0無効）／写真・メッセージ等のコンテンツ／**クラッシュ/分析（Sentry・PostHogはNoop＝アプリ本体としては不収集。※AdMob由来の診断は上表で申告）**／健康・金融（決済情報）。

## プレミアム特典との整合
iOSも無料プランは広告あり＝**プレミアム特典に「広告を非表示に」が復活**（`freeTierAdsActive` が iOS で true になったため、`freeShowsAds` 連動でペイウォール文言も自動で「広告オフ」を表示）。ASC説明文に広告オフ訴求を戻すか要検討（現説明文は広告非言及）。

## v1.1 オプション（収益最大化）
ATTを実装して**パーソナライズ広告**にすると eCPM が上がる。その場合は本ラベルに **「トラッキングに使用されるデータ」＝ Device ID / Advertising Data** を追加し、`NSUserTrackingUsageDescription` とATTフローを実装する。v1.0は非パーソナライズで審査を軽く通す方針。

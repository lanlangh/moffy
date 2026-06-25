# Moffy IAP（アプリ内課金）セットアップ手順（=開発部署 / RevenueCat）

> 作成: 開発部署（engineer） / 日付: 2026-06-23
> 位置づけ: RevenueCat による課金（サブスク）の実装に対応する「ダッシュボード設定・キー注入・
> サンドボックス検証・サーバー反映方針」の手順書。コード側 SSOT は
> `lib/core/constants/pricing.dart` の `RevenueCatIds`。
> 参照: `docs/PRICING.md`（価格・プラン境界・RevenueCat構成）/ `docs/ARCHITECTURE.md`（信頼境界）。
> 専門用語は初出時にインラインで日本語説明。

---

## 0. この実装でできること / まだできないこと

| できる（クライアント実装済み） | まだ（サーバー/手動が必要） |
|---|---|
| Offering `default` の月額/年額の**取得・表示**（ストア実額 priceString） | **実購入の成功**（サンドボックス実機検証が必要・後述§5） |
| 購入 / 復元 / サブスク管理リンク（ストアへ） | （§6 実装済 → 残: **デプロイ + env 設定 + RevenueCat Webhook 設定**） |
| トライアル文言の**条件表示**（資格 ELIGIBLE のときだけ） | （§6-4 実装済 → 残: **REVIEWER_APP_USER_IDS の設定 + 実機審査確認**） |
| entitlement `premium` の**クライアント状態購読**（即時UI反映） | （§6 実装済: **Webhook 反映 / server優先の合成** → 残: 実 Webhook 送信検証） |
| **Webhook → entitlements 反映 / server権威の合成**（§6・コード実装済） | **サンドボックス + 実 Webhook での E2E 検証**（デプロイ後 / §5・§6） |
| キー未設定/オフライン時の **no-op フォールバック**（5状態が成立） | 既存3アプリとの**商品ID突合せ**（§3・要ユーザー作業） |

> 重要原則（PRICING §4-2 / ARCHITECTURE §0-2）:
> 「価格が表示される＝課金が動く」ではない。**実購入はサンドボックス実機検証**が要る。
> プレミアム機能の**最終解放判定はサーバー（entitlements）が正**。クライアントの
> RevenueCat 状態は購入導線と即時UI反映の**補助**に留める。

---

## 1. コード側の構成（=どこに何があるか）

| 役割 | ファイル |
|---|---|
| SSOT（商品/entitlement/offering 識別子・プラン上限・価格基準） | `lib/core/constants/pricing.dart`（`RevenueCatIds` 他） |
| 公開SDKキーの実行時注入（dart-define）・no-op 判定 | `lib/core/config/env.dart`（`revenueCatAndroidKey` / `revenueCatIosKey` / `hasRevenueCat`） |
| IAP ドメイン・純粋ロジック（トライアル表示判定・割安算出・特典列挙・状態） | `lib/core/iap/iap_models.dart` |
| IAP サービス（抽象 + RevenueCat実装 + no-opモック・SDK型マッパ） | `lib/core/iap/iap_service.dart` |
| Riverpod プロバイダ（サービス選択・offerings・状態・機能判定の合成口） | `lib/core/iap/iap_providers.dart` |
| ペイウォール画面・コントローラ（5状態・購入/復元/管理） | `lib/features/paywall/presentation/` |
| 導線（メニューCTA・保管枠満杯アップセル・ルート） | `lib/features/menu/...` / `lib/features/eggs/...` / `lib/core/router/app_router.dart` |
| 単体テスト（純粋ロジック・状態マッピング） | `test/iap_models_test.dart` / `test/iap_entitlement_mapping_test.dart` |

---

## 2. 正しいセットアップ順序（=飛ばすと後でやり直し）

1. **App Store Connect / Google Play Console** でサブスク商品を作成
   - サブスクリプショングループを作り、**月額/年額を同レベル**に置く（切替を横移動に）。
   - 製品IDは **`RevenueCatIds` と完全一致**させる（§3）。
2. **ストアの IAP Key（=.p8 / サービスアカウント鍵）を発行**し、RevenueCat に登録
   - iOS: App Store Connect の In-App Purchase Key（.p8・ダウンロードは一度きり。Issuer ID / Key ID も控える）。
   - Android: Play Console のサービスアカウント JSON を RevenueCat に登録。
   - **これを忘れると IAP は全く動かない**（価格表示すらされない場合がある）。
3. **RevenueCat ダッシュボード**で Products 登録 → **Entitlement `premium`** に両商品を attach
   → **Offering `default`** を作り、`$rc_monthly` / `$rc_annual` パッケージを置き、**Current に設定**。
4. **無料トライアル（7日）を全商品・全地域に設定**（オファー機能。開始日=即時・終了日なし）。
5. RevenueCat の **公開SDKキー（appl_xxx / goog_xxx）** を取得し、ビルドに dart-define で注入（§4）。
6. **サンドボックスで購入完了まで実機テスト**（§5。必須ゲート）。
7. **Webhook → Supabase** を配線し、機能解放をサーバー値で判定する（§6）。

---

## 3. 既存3アプリとの商品ID突合せ（=ユーザー作業・最重要）

> ユーザーの RevenueCat には**既に3アプリ登録済み**。Moffy の識別子は SSOT（`RevenueCatIds`）に
> 定義済みだが、**ダッシュボードの実値と一致しているか必ず突き合わせる**こと。

突合せチェックリスト（`lib/core/constants/pricing.dart` の `RevenueCatIds` と照合）:

| 項目 | コードの定義（SSOT） | ダッシュボード実値（ユーザー確認） |
|---|---|---|
| Entitlement 識別子 | `entitlementPremium = 'premium'` | ☐ 一致 |
| Offering 識別子 | `defaultOffering = 'default'` | ☐ 一致（Current に設定） |
| 月額 Product ID | `productMonthly = 'moffy_premium_monthly'` | ☐ ストア商品IDと一致 |
| 年額 Product ID | `productYearly = 'moffy_premium_yearly'` | ☐ ストア商品IDと一致 |
| 月額 Package 識別子 | `packageMonthly = '$rc_monthly'` | ☐ Offering 内パッケージと一致 |
| 年額 Package 識別子 | `packageYearly = '$rc_annual'` | ☐ Offering 内パッケージと一致 |
| 公開SDKキー（Android） | `--dart-define=REVENUECAT_ANDROID_KEY` | ☐ Moffy 用アプリの goog_xxx |
| 公開SDKキー（iOS） | `--dart-define=REVENUECAT_IOS_KEY` | ☐ Moffy 用アプリの appl_xxx |

- **差し替えが必要な場合**は `RevenueCatIds`（と必要なら `PricingAmounts` の円基準額）を実値に更新する。
  ここが唯一の定義なので、ここだけ直せばクライアント全体に反映される（UIにハードコードしない）。
- 既存3アプリのキーを誤って使わないこと（**Moffy 専用のアプリ設定の公開キー**を使う）。

---

## 4. 公開SDKキーの dart-define 注入（=ビルドに焼き込む）

Supabase と同じく**ソースに直書きせず**実行時注入する（`env.dart` 冒頭の原則）。

```bash
# ローカル実行
flutter run \
  --dart-define=REVENUECAT_ANDROID_KEY=goog_xxxxxxxx \
  --dart-define=REVENUECAT_IOS_KEY=appl_xxxxxxxx \
  --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...

# リリースビルド（例 Android）
flutter build appbundle \
  --dart-define=REVENUECAT_ANDROID_KEY=goog_xxxxxxxx \
  --dart-define=REVENUECAT_IOS_KEY=appl_xxxxxxxx
```

注意（iap-setup 5大致命傷の1番）:
- **キーがビルドに入っていない**事故に注意。CI/クラウドビルドでは `.env` ローカル値は届かない。
  CI のシークレット（GitHub Actions secrets 等）に登録し、ビルドコマンドの dart-define に明示する。
- **公開SDKキー（appl_/goog_）はクライアント埋め込みで安全**。一方
  **Webhook/REST の Secret キー（sk_xxx）は絶対にクライアントへ入れない**（サーバー専用 / §6）。
- **未設定でもクラッシュしない**: `Env.hasRevenueCat` が false なら `NoopIapService`（プレミアム=false・
  商品なし）にフォールバックし、ペイウォールは「プラン準備中」の空状態を出す（診断コード `NO-KEY`）。

---

## 5. サンドボックス購入テスト手順（=必須ゲート）

> 「価格が表示される」だけでは不十分。**購入ボタンを押して完了するまで**が動作確認。

### Android
1. Play Console に**ライセンステスター**を登録し、内部テストトラックでアプリを配布。
2. テスター端末で購入フローを実行: 購入 / 復元 / 解約 / トライアル開始 → 課金移行。
3. トライアル7日の自動更新はテスト時間短縮設定で確認。

### iOS（追従期）
1. App Store Connect の **Sandbox テスター**を作成。
2. TestFlight 配布の IAP は**自動でサンドボックス**（課金されない・審査員も同環境）。
3. Sandbox は更新サイクルが短縮されるので、トライアル → 課金移行・解約反映を確認。

### 検証項目（PRICING §4-3 と一致）
- ① トライアル開始で entitlement `premium` が即有効化（クライアント状態が即時 premium に）。
- ② **保管枠が 200 に解放**（※サーバー検証経由。§6 配線後に確認）。
- ③ 解約で更新停止後に失効 / ④ 返金・期限切れで特典剥奪。
- ⑤ Restore で別端末復元（連携アカウント）/ ⑥ Webhook がサーバー状態に反映（§6）。
- ⑦ **一致原則の検証**: ストア説明で謳う保管枠数・特典が、実際に解放される値
  （`StorageLimits.premiumStorageSlots = 200`）と一致するか実機で突合（誇大表示防止）。

### トライアル表示の罠（iap-setup 致命傷3）
- 「○日間無料」は**資格 ELIGIBLE のときだけ表示**する実装（`PlanOffer.showTrialBadge`）。
  消費済み/地域外ユーザーには表示しない（支払いシートとの矛盾＝リジェクト要因）。
- **イントロオファーはグループにつき生涯1回**。一度購入したテストアカウントでは無料表示は再現不可
  → 「無料が出る側」の確認は**新規サンドボックスアカウント**で行う。

---

## 6. Webhook → Supabase entitlements 反映（=実装済み）

> ここが**信頼境界の肝**。クライアントの「自分は Pro」を信じない。
> 実装: `supabase/functions/revenuecat-webhook/index.ts`（Deno/TS）+
> クライアント配線（`iap_providers.dart` / `server_entitlement.dart` / `iap_service.dart`）。
> ※ Edge Function は Flutter CI の検査対象外（Deno 未導入）。検証は **デプロイ時 + 実 Webhook 送信**で行う。

### 6-0. デプロイ手順（=サーバー反映の有効化）

```bash
# 1) Edge Function をデプロイ（RevenueCat は Supabase JWT を持たないため --no-verify-jwt。
#    認証は関数内で REVENUECAT_WEBHOOK_AUTH の定数時間比較により行う）
supabase functions deploy revenuecat-webhook --no-verify-jwt

# 2) Secret を設定（手動設定が必要なのは REVENUECAT_WEBHOOK_AUTH のみ）
supabase secrets set REVENUECAT_WEBHOOK_AUTH=<長いランダム共有シークレット>
# REVIEWER_APP_USER_IDS は任意（審査用 / カンマ区切りの user_id）
supabase secrets set REVIEWER_APP_USER_IDS=<reviewer_user_id_1,reviewer_user_id_2>
#
# ⚠️ SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY は Edge runtime が自動注入するため
#    手動設定は不要かつ不可（"SUPABASE_" 接頭辞の secrets set は CLI が拒否する）。
#    関数内の Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") はそのまま自動値を読む。
```

**RevenueCat ダッシュボード側の設定**（Project → Integrations → Webhooks）:
- **Webhook URL**: `https://<project-ref>.functions.supabase.co/revenuecat-webhook`
- **Authorization ヘッダ**: `supabase secrets set` した `REVENUECAT_WEBHOOK_AUTH` と**完全一致**の値を設定。
  不一致は 401（関数が定数時間比較で検証）。

### 6-0b. 必要 env 一覧（=すべてサーバー専用）

| env | 用途 | 置き場所 |
|---|---|---|
| `REVENUECAT_WEBHOOK_AUTH` | Webhook の Authorization 共有シークレット（定数時間比較） | Supabase Function Secrets（**手動設定**） |
| `SUPABASE_SERVICE_ROLE_KEY` | entitlements を RLS バイパスで upsert | **Edge runtime 自動注入**（手動設定不可） |
| `SUPABASE_URL` | service_role クライアント生成 | **Edge runtime 自動注入**（手動設定不可） |
| `REVIEWER_APP_USER_IDS` | 審査用に is_premium=true 扱いにする user_id（任意・カンマ区切り） | Supabase Function Secrets（手動設定・任意） |

> ⚠️ いずれも**クライアント（`EXPO_PUBLIC_`/`--dart-define`）に入れない**。クライアントは anon key のみ。

### 6-1. データフロー（目標）
```
[購入/更新/解約/返金]
  RevenueCat → Webhook（HTTP POST） → Supabase Edge Function（要実装）
    → entitlements テーブル更新（is_premium / premium_until / app_user_id）
       ※ RevenueCat REST/Webhook の Secret キー（sk_xxx）はサーバー専用（クライアント禁止）
[アプリ]
  サーバーの entitlement 値を取得（serverPremiumProvider・未実装）
    → 機能解放（保管枠200・限定Mofi抽選・プレミアム卵導線）は **サーバー値で判定**
  クライアントの RevenueCat 状態（premiumStatusProvider）は即時UI反映の補助のみ
```

### 6-2. App User ID 紐づけ（PRICING §4-2）= 実装済み
- RevenueCat の **App User ID を Supabase の user_id に揃える**（機種変・再インストール時の復元が
  連携アカウントで効くように）。`iap_providers.dart` の `iapConfiguredProvider` が、Supabase
  設定済みかつ認証済みなら現在の `user_id` で `configure(appUserId:)` し、さらに `logIn` で
  確実に揃える。未認証/Supabase 未設定なら従来通り匿名ID。
- `IapService` に `logIn(String appUserId)` を追加（Noop は何もしない / RevenueCat は `Purchases.logIn`）。
- これにより Webhook の `event.app_user_id` が Supabase `user_id`（UUID）になり、entitlements の
  PK へ直接 upsert できる。匿名（logIn 前）の `$RCAnonymousID:...` イベントは関数側で UUID 形式を
  検査し、非UUIDなら受理だけして握る（クラッシュさせず、logIn 後のイベントで是正される / §7 相当）。

### 6-3. 機能判定の合成（2プロバイダに分離）= 実装済み
- `isPremiumProvider`（**即時UI表示用**）: `server.isPremium || client.isPremium`。サーバーが
  不明（未設定/未認証/取得不可）ならクライアント値にフォールバック。用途: メニューのバッジ、
  ペイウォールの「加入済み」表示、保管枠アップセルの抑制。
- `isPremiumConfirmedProvider`（**機能ガード=確定処理用**）: `server.isPremium` のみ。サーバーが
  確定値を返すまで（loading/未設定/未認証/取得失敗）は **false** に倒す（未確認で特典を解放しない）。
  保管枠200の確定解放など改ざん耐性が要る処理はこちらを使う。
- サーバー値の供給源: `server_entitlement.dart` の `serverPremiumProvider`（entitlements を
  RLS select-own で読む FutureProvider / 手動 refresh）。書き込みは一切しない（Webhook 専管）。

### 6-4. レビュアーバイパス（iap-setup 致命傷5 / store審査）= 実装済み
- 審査用アカウントを**サーバー側で premium 扱い**にする。Edge Function の env
  `REVIEWER_APP_USER_IDS`（カンマ区切りの user_id）に該当する `app_user_id` は、イベント種別に
  関わらず `is_premium=true` で upsert する。
- **クライアントで tier 固定してはいけない**（CustomerInfo listener に free で上書きされるため）。
  サーバー側（entitlements 行）+ `isPremiumConfirmedProvider` の合成で reviewer-aware に防御する。
- 対象: 審査用アカウントの **Supabase user_id**（ストア提出フォームの固定アカウントでログインして取得）。

---

## 7. エラーハンドリング設計（=実装済み・診断コード一覧）

購入不可時はユーザー向け日本語文言 + **診断コード**を併記（スクショ1枚で原因特定）。

| 診断コード | 意味 | 主因 |
|---|---|---|
| `NO-KEY` | 公開SDKキー未設定（no-op） | dart-define 未注入 / CI シークレット漏れ |
| `INIT-FAIL` | SDK 初期化失敗 | キー不正 / ストア設定未完 |
| `NO-OFFERING` | offering `default` / 該当パッケージが取得できない | Offering 未 Current 設定 / ID 不一致（§3） |
| `NETWORK` | ネットワークエラー | 通信不可 |
| `NOT-ALLOWED` | 購入制限 | ペアレンタルコントロール等 |
| `PURCHASE-FAIL` / `RESTORE-FAIL` | その他の購入/復元失敗 | レシート異常等 |

- 復元は3分岐（アクティブあり=成功 / 履歴なし=nothingToRestore / エラー=失敗）。
- フォアグラウンド復帰時に CustomerInfo を再取得（`premiumStatusStream` が初期値を流す。
  ストアのサブスク管理から戻った直後の同期）。

---

## 8. リリース前チェック（=この機能の DoD）

- [ ] `RevenueCatIds` がダッシュボード実値と一致（§3 チェックリスト）。
- [ ] 公開SDKキーが**リリースビルドに**注入されている（ローカル `.env` だけにしない / §4）。
- [ ] サンドボックスで**購入完了**まで通る（§5・実機）。
- [ ] トライアル文言が**資格時のみ**表示（新規 Sandbox アカウントで確認）。
- [ ] ストア説明の特典・数値が `pricing.dart`（保管枠20→200等）と一致（誇大表示なし）。
- [ ] 詳細分析を特典に**含めていない**（v1.1送り / 実装済みのみ宣伝）。
- [ ] Webhook → Supabase 反映が動作し、機能解放が**サーバー値**で判定される（§6）。
- [ ] レビュアーアカウントがサーバー側で premium 扱いになる（§6-4）。
- [ ] Apple Small Business Program / Google 15% 優遇を**launch 前に申請**（承認に時間 / PRICING §6）。

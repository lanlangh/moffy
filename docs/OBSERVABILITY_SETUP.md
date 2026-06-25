# 観測（Observability）セットアップ — Sentry / PostHog

クラッシュ監視（Sentry）と行動分析（PostHog）の導入手順・キー注入・送信データの原則・イベント一覧。
配線（コード）は実装済み。**あなたの作業はキー取得と `--dart-define` での注入のみ**です。

- 関連: `docs/OWNER_SETUP_GUIDE.md` E章 / `docs/legal/privacy_policy.md`（第三者提供）/ `docs/legal/STORE_DATA_SAFETY.md`（データ安全性宣言）
- 設計: 抽象 + 実装 + Noop（`lib/core/observability/`）。キー未設定なら Noop にフォールバックし、PoC・テストでクラッシュしません。

---

## 1. 仕組み（未設定でも壊れない）

| 依存 | 実装 | キーあり | キーなし（既定） |
| --- | --- | --- | --- |
| クラッシュ監視 | `CrashReporter` | `SentryCrashReporter` | `NoopCrashReporter`（送信しない） |
| 行動分析 | `Analytics` | `PostHogAnalytics` | `NoopAnalytics`（送信しない） |

- 判定は `Env.hasSentry` / `Env.hasPostHog`（`lib/core/config/env.dart`）。`--dart-define` でキーを渡した時だけ実送信に切り替わります。
- 初期化は `lib/main.dart`：
  - Sentry は DSN がある時のみ `SentryFlutter.init(..., appRunner: () => runApp(...))` でラップ。**DSN 未設定時は通常の `runApp` にフォールバック**。
  - PostHog はキーがある時のみ `Posthog().setup(...)`。
  - 本番の重大エラー（`Log.e`）は Sentry へ転送（DSN 設定時のみ）。

---

## 2. キー取得

### Sentry（クラッシュ監視）
1. https://sentry.io でプロジェクトを作成（Platform: **Flutter**）。
2. プロジェクト設定 → Client Keys (DSN) の **DSN** をコピー（`https://xxxx@oXXXX.ingest.sentry.io/XXXX` 形式）。
   - DSN は端末に焼き込んで安全な「公開鍵」です（送信専用）。

### PostHog（行動分析）
1. https://posthog.com でプロジェクトを作成（US クラウド推奨。EU を使う場合は host を変更）。
2. Project Settings → **Project API Key**（`phc_xxx` 形式）をコピー。
   - これは公開キー（クライアント埋め込み可）。**Personal API Key（`phx_xxx`）は絶対にアプリへ入れない**（管理用の秘密鍵 / サーバー・CI 専用）。
3. ホスト: US は `https://us.i.posthog.com`（既定）、EU は `https://eu.i.posthog.com`。

---

## 3. ビルドへの注入（`--dart-define`）

Supabase / RevenueCat と同じ方式です。ソースに直書きしません。

```bash
flutter run \
  --dart-define=SENTRY_DSN=https://xxxx@oXXXX.ingest.sentry.io/XXXX \
  --dart-define=POSTHOG_API_KEY=phc_xxxxxxxxxxxxxxxx \
  --dart-define=POSTHOG_HOST=https://us.i.posthog.com
```

- いずれも未指定なら Noop（送信なし）。片方だけの設定も可能です。
- リリースビルドは `flutter build apk --dart-define=...` / `--dart-define-from-file` で同様に注入。

---

## 4. 送らないデータ（PII / 生データ原則・厳守）

法務（`privacy_policy.md` / `STORE_DATA_SAFETY.md`）と整合させるための鉄則です。

- **個人情報を送らない**：氏名・メール・電話番号は Sentry / PostHog に送りません。
- **利用生データを送らない**：`usage_daily` の分数、確定ポイントの**数値**などの生値はイベントプロパティに載せません。載せてよいのは「区分（is_provisional 等）」のカテゴリ値のみ。
- **user_id は匿名IDのみ**：`identifyAnonymous()` に渡すのは Supabase の匿名 user_id 等のみ。メール・氏名は渡しません。
- **Sentry `sendDefaultPii: false`**：`main.dart` で固定。例外メッセージ・スタックに個人情報を含めません。
- **PostHog 自動キャプチャは無効**（`captureApplicationLifecycleEvents = false`）：明示イベントのみ送信し、誤計測とノイズを避けます。

イベントプロパティに載せてよいカテゴリ値の例：レアリティ（`mofi_rarity` / `egg_rarity`）、色違い（`is_shiny`）、プラン期間（`plan_period`）、流入経路（`source`）。

---

## 5. イベント一覧（ファネル / SSOT）

定義は `lib/core/observability/analytics_events.dart`（マジック文字列を散らさない単一情報源）。
主要ファネル：**起動 → 利用時間権限 → 日次確定 → 孵化 → 図鑑登録 → 課金**。

| イベント名 | 意味 | 配線状況 |
| --- | --- | --- |
| `app_opened` | アプリ起動 | 配線済み（`app.dart`） |
| `onboarding_completed` | オンボーディング完了 | 配線済み（`onboarding_screen.dart`） |
| `usage_permission_granted` | 利用時間権限が許可された | 配線済み（`onboarding_screen.dart`） |
| `day_finalized` | 日次の削減ポイント確定（pt獲得） | **未配線**（`sync_service.dart` に TODO） |
| `egg_hatched` | 卵が孵化した | 配線済み（`eggs_screen.dart`） |
| `shiny_hatched` | 色違いが孵化した | 配線済み（`eggs_screen.dart`） |
| `dex_registered` | 図鑑に新規登録された | 配線済み（`eggs_screen.dart`、新規時のみ） |
| `quest_claimed` | クエスト報酬を受け取った | **未配線**（`quests_controller.dart` に TODO） |
| `paywall_viewed` | ペイウォール表示 | 配線済み（`paywall_screen.dart`） |
| `purchase_completed` | 購入完了 | 配線済み（`paywall_controller.dart`、成功時のみ） |

> 未配線の `day_finalized` / `quest_claimed` は、該当箇所に発火予定の TODO コメントを残しています。後続パスで `analyticsProvider.capture(...)` を1行追加すれば有効化されます。

---

## 6. 動作確認（キー設定後）

1. 上記 `--dart-define` 付きで起動。
2. PostHog：アプリ起動 → ダッシュボードの Activity / Events に `app_opened` が数十秒以内に出れば OK。
3. Sentry：一時的に意図的な例外を投げる（または本番ビルドでクラッシュ）→ Issues に届けば OK。
4. ファネル：PostHog の Funnels で `app_opened → onboarding_completed → egg_hatched → purchase_completed` を作成し、初日から計測できるか確認（PRD §5-5）。

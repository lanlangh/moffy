/// 環境設定（ビルド時 `--dart-define` で注入。ソースに秘密を埋め込まない）。
///
/// 信頼境界（ARCHITECTURE §0-3 / 組織ルール）:
///   * Supabase の anon key は「公開鍵」だが、RLS 前提で安全に公開できる値のみ。
///     service_role key 等のサーバー秘密鍵は **絶対にクライアントへ入れない**。
///   * URL/anon key もハードコードせず dart-define で渡す（環境切替・漏洩防止）。
///   * 例: flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
library;

import 'package:flutter/foundation.dart';

abstract final class Env {
  static const supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const supabaseAnonKey =
      String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  /// Supabase 設定が揃っているか。未設定ならオフライン専用モードで起動する
  /// （PoC・UI確認時にクラッシュさせない）。
  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// プレビュー(appetize)用に、Supabase 設定があっても**強制的にモック実装**で動かすフラグ。
  /// テスト卵(育成2＋保管3)・発見済み図鑑を仕込んだ状態で、枠操作/リングのズレ/図鑑の
  /// 見た目を検証するため（本番ビルド=未設定=false で必ず実バックエンド）。
  static const forceMock =
      bool.fromEnvironment('FORCE_MOCK', defaultValue: false);

  /// 実バックエンド（Supabase）を使うか。forceMock 時はモックに倒す。
  static bool get useSupabase => hasSupabase && !forceMock;

  // --- RevenueCat（IAP / 課金）の公開SDKキー ---
  //
  // 信頼境界（env.dart 冒頭の原則と同じ）:
  //   * RevenueCat の「公開SDKキー（appl_xxx / goog_xxx）」は端末に焼き込んで安全な
  //     公開鍵。これは入れてよい。一方で **Webhook/REST の Secret キー（sk_xxx）は
  //     絶対にクライアントへ入れない**（サーバー〈Supabase Edge Function〉専用）。
  //   * キーはソースに直書きせず `--dart-define` で注入する（Supabase と同方式）。
  //     例: flutter run \
  //           --dart-define=REVENUECAT_ANDROID_KEY=goog_xxx \
  //           --dart-define=REVENUECAT_IOS_KEY=appl_xxx
  //   * 未設定時は IAP サービスを no-op モック（プレミアム=false）にフォールバックし、
  //     PoC・UI確認・テストでクラッシュさせない（hasRevenueCat で判定）。
  static const revenueCatAndroidKey =
      String.fromEnvironment('REVENUECAT_ANDROID_KEY', defaultValue: '');
  static const revenueCatIosKey =
      String.fromEnvironment('REVENUECAT_IOS_KEY', defaultValue: '');

  /// プラットフォーム別の公開SDKキーが設定されているか。
  /// [isApplePlatform] が true なら iOS キー、false なら Android キーを見る。
  /// 未設定なら IAP は no-op（モック）で動作する。
  static bool hasRevenueCat({required bool isApplePlatform}) =>
      (isApplePlatform ? revenueCatIosKey : revenueCatAndroidKey).isNotEmpty;

  /// 現在プラットフォームに対応する RevenueCat 公開SDKキー（未設定は空文字）。
  static String revenueCatKey({required bool isApplePlatform}) =>
      isApplePlatform ? revenueCatIosKey : revenueCatAndroidKey;

  // --- 監視/分析（Sentry = クラッシュ監視 / PostHog = 行動分析） ---
  //
  // 信頼境界（env.dart 冒頭の原則と同じ）:
  //   * Sentry DSN・PostHog の Project API Key は端末に焼き込んで安全な「公開鍵」。
  //     これは入れてよい。一方で PostHog の Personal API Key（phx_xxx）等の管理用
  //     秘密鍵は **絶対にクライアントへ入れない**（サーバー/CI 専用）。
  //   * キーはソースに直書きせず `--dart-define` で注入する（Supabase / RevenueCat と同方式）。
  //     例: flutter run \
  //           --dart-define=SENTRY_DSN=https://xxx@xxx.ingest.sentry.io/xxx \
  //           --dart-define=POSTHOG_API_KEY=phc_xxx
  //   * 未設定時は Noop 実装にフォールバックし、PoC・UI確認・テストでクラッシュさせない
  //     （hasSentry / hasPostHog で判定）。
  //   * 送信データの原則（PII/生データを送らない）は docs/OBSERVABILITY_SETUP.md に集約。
  static const sentryDsn =
      String.fromEnvironment('SENTRY_DSN', defaultValue: '');
  static const postHogApiKey =
      String.fromEnvironment('POSTHOG_API_KEY', defaultValue: '');

  /// PostHog の取り込みホスト（既定は US クラウド）。EU 等は dart-define で上書き。
  static const postHogHost = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://us.i.posthog.com',
  );

  /// Sentry DSN が設定されているか。未設定なら NoopCrashReporter（送信しない）。
  static bool get hasSentry => sentryDsn.isNotEmpty;

  /// PostHog の Project API Key が設定されているか。未設定なら NoopAnalytics。
  static bool get hasPostHog => postHogApiKey.isNotEmpty;

  /// 本番ログ抑止（組織ルール: console.log は __DEV__ ガード）。
  static bool get isDev => kDebugMode;
}

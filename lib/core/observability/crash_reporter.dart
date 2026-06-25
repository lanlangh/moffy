/// クラッシュ監視（Sentry ラッパ / ARCHITECTURE §1 observability・PRD §10）。
///
/// 役割: Sentry SDK（sentry_flutter）の詳細を隠蔽し、上位には抽象 [CrashReporter]
/// のみ公開する（lib/core/iap/ の IapService と同じ構成: 抽象+実装+Noop）。
///
/// 信頼境界・PII 原則（OBSERVABILITY_SETUP.md / 厳守）:
///   * `sendDefaultPii: false`（main.dart の SentryFlutter.init で設定）。
///   * 例外メッセージ・スタックトレースに個人情報や利用生データを載せない
///     （載るのはコード位置とエラー種別のみ）。
///   * DSN は Env（dart-define）から受ける。未設定なら [NoopCrashReporter]。
library;

import 'package:sentry_flutter/sentry_flutter.dart';

import 'log.dart';

/// クラッシュ監視の抽象。未設定/テスト時は [NoopCrashReporter] を注入する。
abstract interface class CrashReporter {
  /// 補足した例外を送信する（[Log.e] 経由のフックからも呼ばれる）。
  ///
  /// [hint] は分類用の短いカテゴリ文字列のみ（PII 禁止）。失敗しても例外を投げない。
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? hint,
  });

  /// 任意のメッセージ（致命的でない異常）を送信する。
  Future<void> captureMessage(String message);
}

/// 何もしない実装（Sentry 未設定 / テスト）。スローしない・送らない。
class NoopCrashReporter implements CrashReporter {
  const NoopCrashReporter();

  @override
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? hint,
  }) async {}

  @override
  Future<void> captureMessage(String message) async {}
}

/// Sentry 実装。
///
/// 初期化（SentryFlutter.init）は main.dart 側で行う（appRunner ラップのため）。
/// 本クラスは初期化済みの Sentry へ送信を委譲する薄いラッパ。
class SentryCrashReporter implements CrashReporter {
  const SentryCrashReporter();

  @override
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? hint,
  }) async {
    try {
      await Sentry.captureException(
        error,
        stackTrace: stackTrace,
        // hint はカテゴリ文字列のみ（PII を含めない）。
        hint: hint == null ? null : Hint.withMap({'category': hint}),
      );
    } catch (e, st) {
      // 監視自体の失敗でアプリを壊さない（本番ログは抑止）。
      Log.e('Sentry captureException failed', error: e, stack: st);
    }
  }

  @override
  Future<void> captureMessage(String message) async {
    try {
      await Sentry.captureMessage(message);
    } catch (e, st) {
      Log.e('Sentry captureMessage failed', error: e, stack: st);
    }
  }
}

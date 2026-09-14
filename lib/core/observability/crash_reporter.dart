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

/// 送信するときの重さ。Sentry の型を上位へ漏らさないためアプリ側で持つ。
///
/// Sentry は **レベルで課題の優先度を決める**（docs.sentry.io/product/issues/issue-priority）:
///   error / fatal → 優先度「高」＝既定のアラート「high priority issues」でメールが来る
///   warning       → 優先度「中」＝記録はされるが高優先の通知は来ない
/// さらに**同じ課題が急増すると自動で優先度が上がる**。
enum CrashLevel { error, warning }

/// クラッシュ監視の抽象。未設定/テスト時は [NoopCrashReporter] を注入する。
abstract interface class CrashReporter {
  /// 補足した例外を送信する（[Log.e] 経由のフックからも呼ばれる）。
  ///
  /// [hint] は分類用の短いカテゴリ文字列のみ（PII 禁止）。失敗しても例外を投げない。
  /// [level] は既定 error。一時的な通信の失敗は warning にする（error_severity.dart）。
  Future<void> captureException(
    Object error, {
    StackTrace? stackTrace,
    String? hint,
    CrashLevel level = CrashLevel.error,
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
    CrashLevel level = CrashLevel.error,
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
    CrashLevel level = CrashLevel.error,
  }) async {
    try {
      await Sentry.captureException(
        error,
        stackTrace: stackTrace,
        // hint はカテゴリ文字列のみ（PII を含めない）。
        hint: hint == null ? null : Hint.withMap({'category': hint}),
        withScope: (scope) {
          scope.level = switch (level) {
            CrashLevel.error => SentryLevel.error,
            CrashLevel.warning => SentryLevel.warning,
          };
        },
      );
    } catch (e) {
      // 監視自体の失敗でアプリを壊さない。
      // 【2026-09-14】以前はここで Log.e を呼んでいた。本番の Log.e は Sentry 送信に
      //   直結しているので、Sentry 送信が失敗し続けると「失敗→Log.e→送信→失敗→…」と
      //   **自分自身を呼び続けるループ**になり得た。開発時のログだけに留める。
      Log.d('Sentry captureException failed: $e');
    }
  }

  @override
  Future<void> captureMessage(String message) async {
    try {
      await Sentry.captureMessage(message);
    } catch (e) {
      // 同上（Log.e は Sentry へ戻るので使わない）。
      Log.d('Sentry captureMessage failed: $e');
    }
  }
}

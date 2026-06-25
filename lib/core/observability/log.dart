import 'dart:developer' as developer;

import '../config/env.dart';

/// ログユーティリティ（ARCHITECTURE §1 observability / 組織ルール）。
/// 本番ログを出さない: 実出力は __DEV__（kDebugMode）ガードのみ。
/// `print` は analysis_options で error 化しているため、ログは必ず本関数経由。
abstract final class Log {
  /// 本番での重大エラー転送先（Sentry 等）。main.dart が起動時に注入する。
  ///
  /// 軽量フック（関数ポインタ注入）で循環依存を回避する:
  ///   log.dart は sentry_flutter / providers を import しない。配線は main.dart 側で
  ///   [crashReporterSink] に Sentry 送信関数を代入する一方向の依存に保つ。
  static void Function(Object error, StackTrace? stack)? crashReporterSink;

  static void d(String message, {String name = 'moffy'}) {
    if (Env.isDev) {
      developer.log(message, name: name);
    }
  }

  static void e(String message, {Object? error, StackTrace? stack}) {
    if (Env.isDev) {
      developer.log(
        message,
        name: 'moffy.error',
        error: error,
        stackTrace: stack,
      );
      return;
    }
    // 本番（!isDev）: developer.log は出さず、設定済みなら Sentry へ転送する。
    // 握りつぶさない（フック未注入＝Sentry 未設定時は黙って捨てるのが正: Noop と同義）。
    final sink = crashReporterSink;
    if (sink != null) {
      // error が null でもメッセージ自体を例外として送り、文脈を失わせない。
      sink(error ?? message, stack);
    }
  }
}

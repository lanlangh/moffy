import 'dart:developer' as developer;

import '../config/env.dart';

/// ログユーティリティ（ARCHITECTURE §1 observability / 組織ルール）。
/// 本番ログを出さない: 実出力は __DEV__（kDebugMode）ガードのみ。
/// `print` は analysis_options で error 化しているため、ログは必ず本関数経由。
abstract final class Log {
  static void d(String message, {String name = 'moffy'}) {
    if (Env.isDev) {
      developer.log(message, name: name);
    }
  }

  static void e(String message, {Object? error, StackTrace? stack}) {
    if (Env.isDev) {
      developer.log(message, name: 'moffy.error', error: error, stackTrace: stack);
    }
    // 本番では Sentry へ送る（後続パスで配線）。ここでは握りつぶさず構造だけ用意。
  }
}

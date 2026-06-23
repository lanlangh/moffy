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

  /// 本番ログ抑止（組織ルール: console.log は __DEV__ ガード）。
  static bool get isDev => kDebugMode;
}

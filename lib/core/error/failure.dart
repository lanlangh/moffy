/// 共通エラー型（ARCHITECTURE §1-4 / core/error）。
/// 例外を UI 向けの [Failure] に正規化し、ErrorView が一貫して扱えるようにする。
library;

/// アプリ横断の失敗表現（sealed）。`switch` で網羅的に分岐できる。
sealed class Failure {
  const Failure(this.message);

  /// ユーザー向け表示文言（責めない・日本語）。
  final String message;
}

/// ネットワーク不通・タイムアウト。
class NetworkFailure extends Failure {
  const NetworkFailure([super.message = 'ネットワークに接続できませんでした']);
}

/// サーバー（Supabase RPC/PostgREST）側のエラー。
class ServerFailure extends Failure {
  const ServerFailure([super.message = 'サーバーでエラーが発生しました']);
}

/// 認証エラー（匿名認証失敗・セッション切れ）。
class AuthFailure extends Failure {
  const AuthFailure([super.message = '認証に失敗しました']);
}

/// OS利用統計の権限が無い / 取得失敗（再要求導線を出す）。
class PermissionFailure extends Failure {
  const PermissionFailure({
    required String message,
    this.permanentlyDenied = false,
  }) : super(message);

  /// true なら OS設定でOFFのまま（設定誘導が必要）。
  final bool permanentlyDenied;
}

/// このプラットフォームでは機能を提供できない（iOS未実装等）。
class UnsupportedFailure extends Failure {
  const UnsupportedFailure([super.message = 'この端末では利用できません']);
}

/// 想定外。
class UnknownFailure extends Failure {
  const UnknownFailure([super.message = '予期しないエラーが発生しました']);
}

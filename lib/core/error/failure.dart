/// 共通エラー型（ARCHITECTURE §1-4 / core/error）。
/// 例外を UI 向けの [Failure] に正規化し、ErrorView が一貫して扱えるようにする。
library;

/// アプリ横断の失敗表現（sealed）。`switch` で網羅的に分岐できる。
sealed class Failure {
  const Failure(this.message, [this.cause]);

  /// ユーザー向け表示文言（責めない・日本語）。
  final String message;

  /// 包み直す前の元の例外（PostgrestException 等）。無ければ null。
  ///
  /// 【2026-09-14 追加】データ層は「元の例外を Log.e で Sentry に送る → Failure に包んで
  ///   投げ直す」をしている。上位がそれを受け止めてまた Log.e すると、同じ失敗が
  ///   **2回**届いていた。しかも2回目は元の情報が消え、件名が
  ///   「Instance of 'ServerFailure'」だけになり、一時的な通信の失敗かどうかも判定できず
  ///   必ず高優先の通知になっていた（1.2.1+29 で実際に届いた）。
  ///   元の例外を持たせることで、送信の入口（error_severity.dart）が
  ///   「元はもう送った」と分かって2回目を捨て、送るときも元の例外で重さを判定できる。
  final Object? cause;

  /// Sentry の件名に使われる。既定の「Instance of 'ServerFailure'」では何も分からない。
  @override
  String toString() {
    final c = cause;
    return c == null
        ? '$runtimeType: $message'
        : '$runtimeType: $message (cause: ${c.runtimeType})';
  }
}

/// ネットワーク不通・タイムアウト。
class NetworkFailure extends Failure {
  const NetworkFailure([
    super.message = 'ネットワークに接続できませんでした',
    super.cause,
  ]);
}

/// サーバー（Supabase RPC/PostgREST）側のエラー。
class ServerFailure extends Failure {
  const ServerFailure([
    super.message = 'サーバーでエラーが発生しました',
    super.cause,
  ]);
}

/// 認証エラー（匿名認証失敗・セッション切れ）。
class AuthFailure extends Failure {
  const AuthFailure([super.message = '認証に失敗しました', super.cause]);
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
  const UnsupportedFailure([
    super.message = 'この端末では利用できません',
    super.cause,
  ]);
}

/// 想定外。
class UnknownFailure extends Failure {
  const UnknownFailure([
    super.message = '予期しないエラーが発生しました',
    super.cause,
  ]);
}

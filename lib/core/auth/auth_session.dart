import 'package:supabase_flutter/supabase_flutter.dart';

import '../observability/log.dart';

/// 匿名セッションを触る**唯一の入口**（S10 匿名ファースト / S12 退会）。
///
/// ## なぜ1箇所に集めるか
/// 匿名ユーザーのセッションは、失うと**二度と復元できない**（引き継ぎ手段が無いため、
/// セッション＝アカウントそのもの）。サインイン/サインアウトの呼び出しが散らばると、
/// うっかり1回余計に走らせた時点でそのユーザーの Mofi・図鑑・残高が全部消える。
/// よって認証状態を変える操作はこのクラスだけが行う。
///
/// ## ⚠️ やってはいけない設計（意図的に採らなかった案）
/// 「`onAuthStateChange` を購読して、セッションが消えたら自動で匿名サインインし直す」
/// という監視は**絶対に入れないこと**。一時的な通信断・トークンリフレッシュ失敗・
/// サーバー側の一時エラーがすべて誤検知の種になり、誤検知が1回起きた瞬間に
/// 既存ユーザーが別人（新しい uid）になってデータを失う。
/// 再サインインは「ユーザーが退会ボタンを押した」という明示的な意思の直後だけに限る。
abstract final class AuthSession {
  /// セッションが無ければ匿名サインインする（起動時 / main.dart から1回）。
  ///
  /// 既にセッションがあれば何もしない。失敗しても例外は投げず false を返す
  /// （オフライン起動でアプリを落とさない）。
  static Future<bool> ensureAnonymous(SupabaseClient client) async {
    if (client.auth.currentSession != null) return true;
    try {
      await client.auth.signInAnonymously();
      Log.d('anonymous sign-in completed');
      return true;
    } catch (e, st) {
      Log.e('anonymous sign-in failed', error: e, stack: st);
      return false;
    }
  }

  /// 退会後に「新しい人」として始め直す（S12）。
  ///
  /// 呼ぶ側の前提: **既に `fn_delete_account` が成功し、サインアウト済みであること**。
  /// ここでは新しい匿名ユーザーを作るだけで、削除は行わない。
  ///
  /// 新 uid が発行されると 0006 の `on_auth_user_created` トリガーが
  /// `public.profiles` 行を作るので、そのまま通常の新規ユーザーとして動く。
  /// 失敗（オフライン等）は false を返す。呼び出し側は再試行導線を出すこと
  /// （ここで壊れたセッションのまま画面を進めない）。
  static Future<bool> restartAsNewAnonymousUser(SupabaseClient client) async {
    try {
      // 念のためローカルセッションを落としてから作り直す（多重ログイン状態を残さない）。
      if (client.auth.currentSession != null) {
        await client.auth.signOut(scope: SignOutScope.local);
      }
      await client.auth.signInAnonymously();
      Log.d('restarted as new anonymous user');
      return true;
    } catch (e, st) {
      Log.e('restart as new anonymous user failed', error: e, stack: st);
      return false;
    }
  }

  /// 退会時のサインアウト（S12）。**失敗しても例外を投げない**。
  ///
  /// `fn_delete_account`（論理削除）は既に成功している状態で呼ばれるため、
  /// ここで例外を投げて上位に「削除できませんでした」と表示させると、
  /// **サーバーは削除済み・端末はセッション生存**という復旧不能な状態
  /// （通称ゾンビセッション）になる。その状態では:
  ///   * profiles は RLS（deleted_at is null）で本人にも見えず、残高0・空の巣になる
  ///   * 一方 eggs / 図鑑 / 統計の RLS には deleted_at 条件が無いので見えたまま
  ///   * 次回起動時も currentSession が残っているため匿名再サインインが走らない
  /// ＝ ユーザーに脱出手段が無くなる。
  ///
  /// そこで global サインアウトが失敗しても **local スコープで必ずセッションを捨てる**。
  static Future<void> signOutAfterDeletion(SupabaseClient client) async {
    try {
      await client.auth.signOut();
    } catch (e, st) {
      Log.e('signOut(global) failed after deletion; falling back to local',
          error: e, stack: st);
      try {
        await client.auth.signOut(scope: SignOutScope.local);
      } catch (e2, st2) {
        // ここまで失敗するのは端末ストレージ異常など。次回起動時に
        // ensureAnonymous が拾えるよう、握って先へ進む（削除自体は成功している）。
        Log.e('signOut(local) also failed', error: e2, stack: st2);
      }
    }
  }
}

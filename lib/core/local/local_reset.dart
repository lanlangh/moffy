import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/home/data/warmup_tracker.dart';
import '../../features/onboarding/data/onboarding_repository.dart';
import '../observability/log.dart';
import '../sync/sync_queue.dart';

/// 退会時に端末へ残るユーザー状態を消す（S12）。
///
/// ## 何を消すか
/// サーバー側のデータ削除は `fn_delete_account`（論理削除）の責務。ここが受け持つのは
/// **端末に残ると次の人（退会後に始め直した新しい匿名ユーザー）を壊すもの**だけ。
///
///   1. オンボーディング完了フラグ … 残すと新規ユーザーがオンボと「最初の卵」を
///      スキップして、いきなりホームに落ちる（go_router の redirect がこれを見る）。
///   2. ウォームアップ初回起動日 … 残すと初回起動から2日を過ぎた判定になり、
///      新しいアカウントが Day1/Day2 のボーナス（200pt/300pt）を**永久に受け取れない**。
///      ＝ 正規の新規ユーザーより貧しい状態で始まる。
///   3. 送信キュー … 旧ユーザー分の未送信の利用データが残ったまま再サインインすると、
///      提出は user_id を送らずサーバーが auth.uid() で解決する設計なので、
///      **旧ユーザーの記録が新ユーザーのものとして確定される**（クロスアカウント汚染）。
///
/// ## 意図的に消さないもの
///   * 通知設定 … 通知機能そのものが未実装（kNotificationsEnabled=false）で、
///     残っていても新ユーザーに影響しない。
///   * Drift のローカルDB … **そもそも存在しない**。pubspec に依存はあるが lib/ からの
///     利用は0件。以前この付近のコメントが「Drift をクリアする」と書いていたが、
///     実体の無いものを指していた。
///
/// ## トレードオフ（記録として残す）
/// 2 を消すことで「退会 → 再開」を繰り返せばウォームアップ 200+300pt と初回卵を
/// 何度でも取り直せる。ただし代償として図鑑・残高・ストリークを毎回すべて失うため
/// 自己破壊的で、ランキングや交換の仕組みも無いので他人に影響しない。
/// 消さない場合の害（新規が永久にボーナスを受け取れない）のほうが大きいと判断した。
Future<void> resetLocalUserState(Ref ref) async {
  // 送信キュー: 失敗しても続行する（メモリ上のキューなのでプロセス終了でも消える）。
  try {
    await ref.read(syncQueueProvider).clear();
  } catch (e, st) {
    Log.e('sync queue clear failed on account deletion', error: e, stack: st);
  }

  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(SharedPrefsOnboardingRepository.prefsKey);
    await prefs.remove(WarmupTracker.firstLaunchPrefsKey);
  } catch (e, st) {
    // ここが失敗しても削除自体は成功している。次の起動で不整合が出るだけなので
    // ユーザーには「削除できませんでした」と見せない（誤解を与える）。
    Log.e('local prefs reset failed on account deletion', error: e, stack: st);
  }
}

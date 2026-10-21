import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/env.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';

/// 「ふだんのSNS時間」R の申告（0018 / docs/design/EGG_PACING_DESIGN.md §2-1）。
///
/// 信頼境界: R の正本は **サーバー（profiles.usual_minutes）**。評価（◎/○/△）は
/// サーバー `fn_finalize_day` が profiles の値で行う。端末は
///   1. オンボーディング（または既存ユーザーへの1回だけのシート）で申告を受け取り、
///   2. 端末に保存してから RPC `fn_set_usual_minutes` で送る（オフラインなら次の起動で再送）、
///   3. 「きょうのペース」の暫定表示にローカル値を使う（サーバー値が取れればそちらを優先）。
/// 実測による上方修正はサーバーだけが行う（端末は書かない）。
abstract interface class UsualMinutesRepository {
  /// 端末に保存した申告値（分）。未申告・スキップは null。
  Future<int?> localReported();

  /// 申告シートを出したことがあるか（スキップ含む）。既存ユーザーに1回だけ出すための判定。
  Future<bool> hasBeenAsked();

  /// 「出した」と記録する（スキップ時もここを呼ぶ）。
  Future<void> markAsked();

  /// 申告を保存し、可能ならサーバーへ送る。
  Future<void> report(int minutes);

  /// 未同期の申告があればサーバーへ送る（起動時・復帰時に呼ぶ）。
  Future<void> syncPending();
}

class SharedPrefsUsualMinutesRepository implements UsualMinutesRepository {
  SharedPrefsUsualMinutesRepository(this._ref);

  final Ref _ref;

  /// 退会時のローカル初期化（core/local/local_reset.dart）が参照するため公開する。
  static const String reportedKey = 'usual_minutes_reported_v1';
  static const String syncedKey = 'usual_minutes_synced_v1';
  static const String askedKey = 'usual_minutes_asked_v1';

  @override
  Future<int?> localReported() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(reportedKey);
    } catch (e, st) {
      Log.e('usual minutes read failed', error: e, stack: st);
      return null;
    }
  }

  @override
  Future<bool> hasBeenAsked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(askedKey) ?? false;
    } catch (e, st) {
      // 読めないときは「聞いた」扱い＝シートを出さない（毎回出て困るより安全側）。
      Log.e('usual minutes asked-flag read failed', error: e, stack: st);
      return true;
    }
  }

  @override
  Future<void> markAsked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(askedKey, true);
    } catch (e, st) {
      Log.e('usual minutes asked-flag write failed', error: e, stack: st);
    }
  }

  @override
  Future<void> report(int minutes) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(reportedKey, minutes);
      await prefs.setBool(syncedKey, false);
      await prefs.setBool(askedKey, true);
    } catch (e, st) {
      Log.e('usual minutes write failed', error: e, stack: st);
    }
    await syncPending();
  }

  @override
  Future<void> syncPending() async {
    // ⚠️ `useSupabase` であること（`hasSupabase` ではない）。FORCE_MOCK のプレビュー配信が
    //    本番の profiles を書かないように（daily_submission.dart と同じ原則）。
    if (!Env.useSupabase || !_ref.read(isOnlineProvider)) return;
    int? minutes;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(syncedKey) ?? false) return;
      minutes = prefs.getInt(reportedKey);
    } catch (e, st) {
      Log.e('usual minutes sync read failed', error: e, stack: st);
      return;
    }
    if (minutes == null) return;
    try {
      final client = _ref.read(supabaseClientProvider);
      await client.rpc('fn_set_usual_minutes', params: {'p_minutes': minutes});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(syncedKey, true);
    } catch (e, st) {
      // 送れなくても画面は止めない（次の起動/復帰で再送）。
      Log.e('fn_set_usual_minutes failed', error: e, stack: st);
    }
  }
}

/// DI（ARCHITECTURE §1-3）。テストで override 可能。
final usualMinutesRepositoryProvider = Provider<UsualMinutesRepository>(
  (ref) => SharedPrefsUsualMinutesRepository(ref),
);

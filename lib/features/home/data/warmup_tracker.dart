import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/observability/log.dart';

/// ウォームアップ（S1）の「経過日（Day1|Day2）」をローカルで決定する純粋ロジック。
///
/// 信頼境界（PRD §S1 / §2-3）: 付与の正は **サーバー RPC `fn_claim_warmup`**。
/// 冪等キーは「生涯1回（uid×'warmup'×day）」なので、クライアントは「今が Day1 か Day2 か」
/// を粗く決めて呼ぶだけでよい（二重呼びはサーバーが冪等スキップ）。
/// ここでの day 決定はあくまで「いつ Day1/Day2 を呼ぶか」のトリガー判断であり、
/// 付与額や受取済みの正本ではない。
///
/// 決定方式（0018 で改訂 / docs/design/EGG_PACING_DESIGN.md §3-3）:
///   * 初回起動日と同じ日（経過0日）      → Day1
///   * 初回起動日より後で、まだ Day2 を受け取っていない → Day2
///     （翌日でも、3日後でも、1か月後でも。以前は「翌日」だけだったため、翌日開かないと
///       2日目のボーナスが永久に来なかった＝初日の 200pt で止まった卵が 83 個あった）
///   * Day2 受取済み                    → ウォームアップ対象外（null）
///
/// サーバー登録日（signup）ではなくローカル初回起動日を使う理由:
///   * 匿名認証ファースト（S10）で「初回起動 ≒ サインアップ」が成立する。
///   * オフライン初回でも判定でき、サーバー往復に依存しない。
///   * 端末TZの暦日で素直に「今日/それ以降」を表現でき、ユーザー体感に合う（S11）。
int? warmupDayFor(
  DateTime firstLaunch,
  DateTime now, {
  bool day2Claimed = false,
}) {
  // 暦日（時刻成分を落とす）どうしの差で「経過日数」を出す（S11: ローカル暦日境界）。
  final f = DateTime(firstLaunch.year, firstLaunch.month, firstLaunch.day);
  final n = DateTime(now.year, now.month, now.day);
  final elapsed = n.difference(f).inDays;
  if (elapsed <= 0) return 1; // 初回起動当日（巻き戻り含め安全側で Day1）。
  if (day2Claimed) return null; // 受取済み＝ウォームアップ卒業。
  return 2; // 初回起動日より後に最初に開いた日（何日後でも）。
}

/// ウォームアップの初回起動日と Day2 受取済みフラグをローカル永続化し、現在の Day を解決する。
///
/// 初回起動日は端末ローカル（shared_preferences）に1度だけ記録する
/// （オンボーディング完了フラグと同じ方針 / サーバー不要・オフライン判定可能）。
class WarmupTracker {
  WarmupTracker();

  /// 初回起動日（ISO8601・日付のみ）の保存キー。退会時のローカル初期化
  /// （core/local/local_reset.dart）が参照するため公開する。
  static const String firstLaunchPrefsKey = 'warmup_first_launch_v1';

  /// Day2 を受け取った（またはサーバーが受取済みと答えた）記録。0018 で追加。
  /// これが無いと Day2 の RPC を起動のたびに呼び続ける（冪等なので害はないが無駄）。
  static const String day2ClaimedPrefsKey = 'warmup_day2_claimed_v1';

  /// 初回起動日を取得する。未記録なら [now] を初回起動日として記録して返す。
  ///
  /// 読み書き失敗時は安全側で [now] を返す（= Day1 として扱える / 体験を止めない）。
  Future<DateTime> firstLaunchDate(DateTime now) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(firstLaunchPrefsKey);
      if (stored != null) {
        final parsed = DateTime.tryParse(stored);
        if (parsed != null) return parsed;
      }
      // 初回: 当日を暦日で記録（時刻成分は持たない）。
      final today = DateTime(now.year, now.month, now.day);
      await prefs.setString(firstLaunchPrefsKey, today.toIso8601String());
      return today;
    } catch (e, st) {
      // 永続化に失敗しても体験を止めない（Day1 相当の now を返す）。
      Log.e('warmup firstLaunchDate failed', error: e, stack: st);
      return DateTime(now.year, now.month, now.day);
    }
  }

  /// Day2 を受け取り済みか。
  Future<bool> isDay2Claimed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(day2ClaimedPrefsKey) ?? false;
    } catch (e, st) {
      // 読めないときは「未受取」に倒す（サーバーが冪等に弾くので二重付与にはならない）。
      Log.e('warmup day2 flag read failed', error: e, stack: st);
      return false;
    }
  }

  /// Day2 の受取を記録する（サーバーが付与した／受取済みと答えたとき）。
  Future<void> markDay2Claimed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(day2ClaimedPrefsKey, true);
    } catch (e, st) {
      Log.e('warmup day2 flag write failed', error: e, stack: st);
    }
  }

  /// 現在のウォームアップ Day（1|2）を解決する。対象外は null。
  Future<int?> resolveWarmupDay(DateTime now) async {
    final first = await firstLaunchDate(now);
    final claimed = await isDay2Claimed();
    return warmupDayFor(first, now, day2Claimed: claimed);
  }
}

/// DI（ARCHITECTURE §1-3）。テストで override 可能。
final warmupTrackerProvider = Provider<WarmupTracker>((ref) => WarmupTracker());

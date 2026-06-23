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
/// 決定方式: ローカル初回起動日（[firstLaunch]）からの経過日数で Day を割り出す。
///   * 同日（経過0日） → Day1
///   * 翌日（経過1日） → Day2
///   * 2日以降       → ウォームアップ対象外（null）
///
/// サーバー登録日（signup）ではなくローカル初回起動日を使う理由:
///   * 匿名認証ファースト（S10）で「初回起動 ≒ サインアップ」が成立する。
///   * オフライン初回でも判定でき、サーバー往復に依存しない。
///   * 端末TZの暦日で素直に「今日/明日」を表現でき、ユーザー体感に合う（S11）。
int? warmupDayFor(DateTime firstLaunch, DateTime now) {
  // 暦日（時刻成分を落とす）どうしの差で「経過日数」を出す（S11: ローカル暦日境界）。
  final f = DateTime(firstLaunch.year, firstLaunch.month, firstLaunch.day);
  final n = DateTime(now.year, now.month, now.day);
  final elapsed = n.difference(f).inDays;
  if (elapsed <= 0) return 1; // 初回起動当日（巻き戻り含め安全側で Day1）。
  if (elapsed == 1) return 2; // 翌日。
  return null; // 2日目以降はウォームアップ卒業（暫定基準フェーズへ）。
}

/// ウォームアップの初回起動日をローカル永続化し、現在の Day を解決する。
///
/// 初回起動日は端末ローカル（shared_preferences）に1度だけ記録する
/// （オンボーディング完了フラグと同じ方針 / サーバー不要・オフライン判定可能）。
class WarmupTracker {
  WarmupTracker();

  /// 初回起動日（ISO8601・日付のみ）の保存キー。
  static const String _firstLaunchKey = 'warmup_first_launch_v1';

  /// 初回起動日を取得する。未記録なら [now] を初回起動日として記録して返す。
  ///
  /// 読み書き失敗時は安全側で [now] を返す（= Day1 として扱える / 体験を止めない）。
  Future<DateTime> firstLaunchDate(DateTime now) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_firstLaunchKey);
      if (stored != null) {
        final parsed = DateTime.tryParse(stored);
        if (parsed != null) return parsed;
      }
      // 初回: 当日を暦日で記録（時刻成分は持たない）。
      final today = DateTime(now.year, now.month, now.day);
      await prefs.setString(_firstLaunchKey, today.toIso8601String());
      return today;
    } catch (e, st) {
      // 永続化に失敗しても体験を止めない（Day1 相当の now を返す）。
      Log.e('warmup firstLaunchDate failed', error: e, stack: st);
      return DateTime(now.year, now.month, now.day);
    }
  }

  /// 現在のウォームアップ Day（1|2）を解決する。対象外は null。
  Future<int?> resolveWarmupDay(DateTime now) async {
    final first = await firstLaunchDate(now);
    return warmupDayFor(first, now);
  }
}

/// DI（ARCHITECTURE §1-3）。テストで override 可能。
final warmupTrackerProvider = Provider<WarmupTracker>((ref) => WarmupTracker());

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/env.dart';
import '../constants/remote_config.dart';
import '../observability/log.dart';
import '../usage/point_calculator.dart';
import '../usage/usage_providers.dart';
import 'connectivity_provider.dart';
import 'finalize_models.dart';
import 'sync_service.dart';

/// 「終了した日」の利用生データを提出し、サーバー確定を駆動する（ARCHITECTURE §1-5 step1）。
///
/// 位置づけ: [SyncService.syncNow] が「キューを流す人」なのに対し、本サービスは
/// **キューに積む人**。これが無いと `usage_daily` は永久に提出されず、
/// `fn_finalize_day` が到達不能になり、削減ptが一切確定しない（コアループが死ぬ）。
///
/// なぜ「昨日」だけなのか（PRD §S4-2「当日分のみ確定」）:
///   * 確定は「サーバー基準でその日が終了した分」を**翌日**に行う。当日を確定すると
///     `fn_finalize_day` が `is_finalized` を立て、加算も冪等キー
///     （uid×date×'reduction'）で締まるため、以降の利用が反映されない。
///     削減量 = 基準値 - 当日利用分 は時間とともに**減るだけ**なので、当日の早い時刻に
///     確定すると満額が入ってしまう（＝朝に確定して1日中使い放題）。
///   * 同§「過去日付の遡及加点は不可」により、一昨日以前は対象にしない。
///   * 当日は端末の暫定表示に留める（HomeRepository の provisionalPoints）。
///
/// なぜ1日1回なのか（S8 冪等性）:
///   * 確定済みの行は RLS（`usage_update_own_unfinalized`）で更新できない。再提出すると
///     権限エラーになりキューに残って再試行し続けるため、提出済みの暦日を端末に記録する。
class DailySubmissionService {
  DailySubmissionService(this._ref);

  final Ref _ref;

  /// 最後に提出した「利用日」（yyyy-MM-dd）の保存キー。
  /// オンボーディング完了フラグ・ウォームアップ初回起動日と同じローカル永続方針。
  static const String _lastSubmittedKey = 'usage_last_submitted_day_v1';

  /// 昨日（端末TZの暦日 / S11）の利用を、未提出なら提出して確定する。
  ///
  /// 前提が欠けている場合は静かに諦める（体験を止めない・次の起動/復帰で再試行）:
  ///   * Supabase 未設定（オフライン専用モード）
  ///   * オフライン（復帰時に [dailySubmissionProvider] が再駆動する）
  ///   * 利用統計の権限なし / OS 取得失敗
  Future<void> submitYesterdayIfNeeded({DateTime? now}) async {
    if (!_ref.read(usageSubmissionEnabledProvider)) return;
    if (!_ref.read(isOnlineProvider)) return;

    final base = now ?? DateTime.now();
    final yesterday =
        DateTime(base.year, base.month, base.day).subtract(const Duration(days: 1));
    final dayKey = _dayKey(yesterday);

    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getString(_lastSubmittedKey) == dayKey) return;

      final usageProvider = _ref.read(usageProviderProvider);
      final permission = await usageProvider.checkPermission();
      if (!permission.isGranted) return;

      final targets = _ref.read(targetPackagesProvider);
      final params = await _ref.read(economyParamsProvider.future);

      // 提出する生データ本体（昨日1日分）。
      final usage = await usageProvider.fetchDailyUsage(
        date: yesterday,
        targetPackages: targets,
      );

      // 昨日時点の暫定pt（S8 競合解決の比較基準 = サーバー確定値が下回っても
      // 画面から減らさないための基準）。基準値は「昨日を含まない」直近 window 日（S11）。
      final history = await usageProvider.fetchUsageRange(
        startDate:
            yesterday.subtract(Duration(days: params.baselineWindowDays)),
        endDate: yesterday.subtract(const Duration(days: 1)),
        targetPackages: targets,
      );
      final baseline = Baseline.compute(
        forDate: yesterday,
        history: history,
        params: params,
      );
      final calculator = _ref.read(pointCalculatorProvider);
      final localPoints = baseline.isWarmup
          ? 0 // ウォームアップ期は削減計算しない（固定ボーナスはサーバー warmup_grants / S1）。
          : calculator.applyStreakAndCap(
              basePoints: calculator.calculateBasePoints(
                today: usage,
                baseline: baseline,
                params: params,
              ),
              // ストリーク日数はサーバーSSOT。端末は倍率なし（×1.0）で見積もる。
              currentStreakDays: 1,
              params: params,
            );

      final draft = UsageDailyDraft.fromDailyUsage(usage, localPoints: localPoints);
      final sync = _ref.read(syncServiceProvider);
      await sync.enqueueUsageSubmission(draft);
      final outcome = await sync.syncNow();

      // 送信できた時だけ「提出済み」を記録する（失敗時は記録せず次回再試行 / S8）。
      if (outcome.succeeded > 0) {
        await prefs.setString(_lastSubmittedKey, dayKey);
        Log.d('usage submitted for $dayKey');
      }
    } catch (e, st) {
      // 提出失敗でアプリを止めない（次の起動 / オンライン復帰で再試行）。
      Log.e('submitYesterdayIfNeeded failed', error: e, stack: st);
    }
  }

  /// `p_date` / `usage_date` と同じ YYYY-MM-DD 表現（[UsageDailyDraft.dateKey] と一致）。
  String _dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// 実バックエンドへ提出してよい環境か（ARCHITECTURE §1-3 / テストで override 可能）。
///
/// FORCE_MOCK のプレビュー配信は Supabase 設定を持つ（`Env.hasSupabase`=true）ため、
/// [Env.hasSupabase] ではなく [Env.useSupabase] で判定する（プレビューの操作を
/// 本番DBへ書かない）。
final usageSubmissionEnabledProvider = Provider<bool>((ref) => Env.useSupabase);

/// DI（ARCHITECTURE §1-3）。テストで override 可能。
final dailySubmissionServiceProvider =
    Provider<DailySubmissionService>((ref) => DailySubmissionService(ref));

/// 起動時とオンライン復帰時に「昨日の提出 → サーバー確定」を駆動する（ARCHITECTURE §1-5）。
///
/// アプリ起動時に `ref.watch(dailySubmissionProvider)` で常駐させる想定（app.dart）。
/// [syncOnReconnectProvider] が「キューを流す」のに対し、こちらは「キューに積む」。
/// 両方が揃って初めて 生データ提出 → fn_finalize_day → 確定pt が成立する。
final dailySubmissionProvider = Provider<void>((ref) {
  // 起動直後に1回（前日分の確定はアプリを開いた最初のタイミングで行う）。
  // ignore: discarded_futures
  ref.read(dailySubmissionServiceProvider).submitYesterdayIfNeeded();

  // オフラインで起動した場合に備え、復帰エッジでも再試行する。
  var wasOnline = ref.read(isOnlineProvider);
  ref.listen<bool>(isOnlineProvider, (prev, next) {
    final cameOnline = (prev == false || !wasOnline) && next == true;
    wasOnline = next;
    if (cameOnline) {
      Log.d('reconnected: triggering daily usage submission');
      // ignore: discarded_futures
      ref.read(dailySubmissionServiceProvider).submitYesterdayIfNeeded();
    }
  });
});

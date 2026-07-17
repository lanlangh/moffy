import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../constants/remote_config.dart';
import '../observability/log.dart';
import '../usage/point_calculator.dart';
import '../usage/usage_providers.dart';
import 'connectivity_provider.dart';
import 'finalize_models.dart';
import 'sync_service.dart';
import 'usage_sync_repository.dart';

/// 「終了した日」の利用生データを提出し、サーバー確定を駆動する（ARCHITECTURE §1-5 step1）。
///
/// 位置づけ: [SyncService.syncNow] が「キューを流す人」なのに対し、本サービスは
/// **キューに積む人**。これが無いと `usage_daily` は永久に提出されず、確定RPCが
/// 到達不能になり、削減ptが一切確定しない（コアループが死ぬ）。
///
/// ## 対象日はサーバーが決める（PRD §S4-2 / S4: 日付境界の正はサーバー時刻 / 0011）
///
/// 端末時計で「昨日」を計算してはいけない。端末が1日進んでいると「端末の昨日」＝
/// 「サーバーの今日」になり、当日確定が通ってしまう。削減量 = 基準値 - 当日利用分は
/// 時間とともに**減るだけ**なので、朝の少ない利用時間で満額(480pt上限)を確定でき、
/// その後は使い放題になる。よって [UsageSyncRepository.pendingFinalizeDate] で
/// サーバーに対象日を問い合わせる。
///
/// ⚠️ ただしこの問い合わせは「どの日の OS 利用データを集めるか」を知るための**照会**で
/// あって、権限境界ではない。境界はサーバーの `fn_submit_and_finalize_day` が持ち、
/// 申告された日がサーバーの計算した対象日（＝前日）と一致しなければ
/// 'wrong_finalize_date' で拒否する。よって照会と本送信の間に日を跨いでも安全
/// （次回の起動/復帰で正しい日を取り直す / Codex 第2次レビュー #1・#5）。
///
/// ## 提出済み判定もサーバーが持つ
///
/// 端末に「提出済みフラグ」を持たない。ローカルフラグはサーバー状態と乖離し得るため
/// （再インストールで消える → 確定済み日を再提出）。確定の事実は
/// `usage_daily.is_finalized` が唯一の正本で、`already_finalized` として受け取る。
/// 確定済み日を再提出しても RPC は行ロック下で早期 return するだけ（エラーにしない）
/// なので、キューに毒オペレーションが residue として残り続けることはない。
class DailySubmissionService {
  DailySubmissionService(this._ref);

  final Ref _ref;

  /// 多重起動の抑止（起動トリガーと復帰トリガーが重なると両方が「未提出」と判断し、
  /// 同じ日を並行提出してしまう）。
  bool _inFlight = false;

  /// サーバーが指す「確定すべき日」を提出して確定する。既に確定済みなら何もしない。
  ///
  /// 前提が欠けている場合は静かに諦める（体験を止めない・次の復帰/起動で再試行）:
  ///   * Supabase 未設定（オフライン専用モード）/ モック実装（実DB無し）
  ///   * オフライン
  ///   * 利用統計の権限なし / OS 取得失敗 / 認証未確立
  Future<void> submitPendingDay() async {
    if (!_ref.read(usageSubmissionEnabledProvider)) return;
    if (!_ref.read(isOnlineProvider)) return;
    if (_inFlight) return;
    _inFlight = true;
    try {
      final repo = _ref.read(usageSyncRepositoryProvider);

      // 1. 対象日をサーバーに聞く（S4: 日付境界の正はサーバー時刻 + ユーザーTZ）。
      final pending = await repo.pendingFinalizeDate();
      if (pending == null) return; // 実DB無し（モック）＝提出しない。
      if (pending.alreadyFinalized) return; // 既に確定済み＝何もしない。

      final usageProvider = _ref.read(usageProviderProvider);
      final permission = await usageProvider.checkPermission();
      if (!permission.isGranted) return;

      final targets = _ref.read(targetPackagesProvider);
      final params = await _ref.read(economyParamsProvider.future);
      final target = pending.targetDate;

      // 2. 提出する生データ本体（サーバーが指した1日分）。
      final usage = await usageProvider.fetchDailyUsage(
        date: target,
        targetPackages: targets,
      );

      // 3. 対象日時点の暫定pt（S8 競合解決の比較基準 = サーバー確定値が下回っても
      //    画面から減らさないための基準）。基準値は対象日を含まない直近 window 日（S11）。
      final history = await usageProvider.fetchUsageRange(
        startDate: target.subtract(Duration(days: params.baselineWindowDays)),
        endDate: target.subtract(const Duration(days: 1)),
        targetPackages: targets,
      );
      final baseline = Baseline.compute(
        forDate: target,
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

      // 4. キューへ積んで送信（オフライン中に積めるのが S8 の骨子）。
      //    確定できたかの判定と画面への合図（[dayFinalizedTickProvider]）は
      //    [SyncService] が行う＝確定RPCの戻り値を唯一知っている場所だから。
      //    ここで再照会してはいけない（送信中に日を跨ぐと、再照会は**翌日**について
      //    答えるため、対象日の確定を見逃す/別日の確定を今回の成功と誤認する
      //    / Codex 第2次レビュー #5B）。
      final draft = UsageDailyDraft.fromDailyUsage(usage, localPoints: localPoints);
      final sync = _ref.read(syncServiceProvider);
      await sync.enqueueUsageSubmission(draft);
      await sync.syncNow();
    } catch (e, st) {
      // 提出失敗でアプリを止めない（次の復帰 / 起動で再試行）。
      Log.e('submitPendingDay failed', error: e, stack: st);
    } finally {
      _inFlight = false;
    }
  }
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

/// 起動時とオンライン復帰時に「前日の提出 → サーバー確定」を駆動する（ARCHITECTURE §1-5）。
///
/// アプリ起動時に `ref.watch(dailySubmissionProvider)` で常駐させる想定（app.dart）。
/// [syncOnReconnectProvider] が「キューを流す」のに対し、こちらは「キューに積む」。
/// 両方が揃って初めて 生データ提出 → 確定RPC → 確定pt が成立する。
///
/// ⚠️ Provider の本体は**初回 watch の1回しか走らない**。プロセスが生きたまま日を跨ぐ
/// （＝スマホでは普通に起きる）と起動トリガーは二度と来ないため、**フォアグラウンド復帰**
/// でも駆動する必要がある。そちらは app.dart の [WidgetsBindingObserver] が担う。
final dailySubmissionProvider = Provider<void>((ref) {
  // 起動直後に1回。
  // ignore: discarded_futures
  ref.read(dailySubmissionServiceProvider).submitPendingDay();

  // オフラインで起動した場合に備え、復帰エッジでも再試行する。
  var wasOnline = ref.read(isOnlineProvider);
  ref.listen<bool>(isOnlineProvider, (prev, next) {
    final cameOnline = (prev == false || !wasOnline) && next == true;
    wasOnline = next;
    if (cameOnline) {
      Log.d('reconnected: triggering daily usage submission');
      // ignore: discarded_futures
      ref.read(dailySubmissionServiceProvider).submitPendingDay();
    }
  });
});

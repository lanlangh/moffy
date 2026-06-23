import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/economy.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/sync/finalize_models.dart';
import '../../../core/usage/point_calculator.dart';
import '../../../core/usage/usage_models.dart';
import '../../../core/usage/usage_providers.dart';
import '../domain/home_state.dart';

/// ホームのデータ層（ARCHITECTURE §1-2 data）。
/// OS抽象（UsageProvider）と PointCalculator を組み合わせて「今日の利用 + 暫定pt」を作る。
/// Supabase/Drift の詳細は上位に漏らさず、ドメイン型（[HomeUsageResult]）のみ返す。
///
/// 第1パスのスコープ: 利用取得 → 基準値 → 暫定pt の縦スライス。
/// 通貨残高・卵・サーバー確定値の取得は後続パスで Supabase/Drift を配線する
/// （ここでは型と差し込み口を用意し、未配線部はデフォルト値で安全に返す）。
class HomeRepository {
  HomeRepository(this._ref);

  final Ref _ref;

  /// 今日の利用を取得し、基準値・暫定ptを算出する。
  ///
  /// 失敗時は例外を throw せず [HomeUsageResult] にエラー種別を載せて返す
  /// （AsyncNotifier 側で 5状態に振り分けるため）。
  Future<HomeUsageResult> loadUsage({
    required EconomyParams params,
    required List<String> targetPackages,
    DateTime? now,
  }) async {
    final usageProvider = _ref.read(usageProviderProvider);
    final calculator = _ref.read(pointCalculatorProvider);
    final today = now ?? DateTime.now();

    // 権限なし/失敗でも返せるよう、空履歴の warmup baseline を先に用意（画面を落とさない）。
    final warmupBaseline = Baseline.compute(
      forDate: today,
      history: const [],
      params: params,
    );

    // 1. 権限チェック（無ければフォールバック / §5-1）。
    final permission = await usageProvider.checkPermission();
    if (!permission.isGranted) {
      return HomeUsageResult.noPermission(permission, warmupBaseline);
    }

    try {
      // 2. 基準値計算用の履歴（本日除く直近 window 日 / S11）。
      final windowDays = params.baselineWindowDays;
      final startDate = today.subtract(Duration(days: windowDays));
      final yesterday = today.subtract(const Duration(days: 1));
      final history = await usageProvider.fetchUsageRange(
        startDate: startDate,
        endDate: yesterday, // 本日を含まない（S11）
        targetPackages: targetPackages,
      );

      final baseline = Baseline.compute(
        forDate: today,
        history: history,
        params: params,
      );

      // 3. 今日の利用（端末暫定）。
      final todayUsage = await usageProvider.fetchDailyUsage(
        date: today,
        targetPackages: targetPackages,
      );

      // 4. 暫定pt（ウォームアップ期は削減計算しない / S1）。
      //    ストリーク日数はサーバーSSOTのため第1パスでは 1（×1.0）で算出。
      //    確定値はサーバー fn_finalize_day が再計算する（ARCHITECTURE §2-3）。
      final int provisionalPoints;
      if (baseline.isWarmup) {
        provisionalPoints = 0; // 固定ボーナスはサーバー warmup_grants で付与
      } else {
        final base = calculator.calculateBasePoints(
          today: todayUsage,
          baseline: baseline,
          params: params,
        );
        provisionalPoints = calculator.applyStreakAndCap(
          basePoints: base,
          currentStreakDays: 1,
          params: params,
        );
      }

      // 昨日の利用分（昨日比表示用）。一致する日が無ければ null。
      int? yMin;
      for (final d in history) {
        if (d.date.year == yesterday.year &&
            d.date.month == yesterday.month &&
            d.date.day == yesterday.day) {
          yMin = d.totalMinutes;
          break;
        }
      }

      return HomeUsageResult.success(
        permission: permission,
        todayUsage: todayUsage,
        baseline: baseline,
        provisionalPoints: provisionalPoints,
        yesterdayMinutes: yMin,
      );
    } on UsageException catch (e, st) {
      Log.e('usage fetch failed', error: e, stack: st);
      return HomeUsageResult.fetchError(permission, warmupBaseline, e.message);
    }
  }

  /// 通貨残高・アクティブ卵・プールptの取得（確定値SSOT = サーバー / ARCHITECTURE §1-5 step3）。
  ///
  /// 確定値（point_balance/gem_balance/pooled_points/アクティブ卵の growth_points）は
  /// すべてサーバーが SSOT。本メソッドは本人行を select するだけで、加算・改ざんはしない。
  /// Supabase 未設定/オフライン/取得失敗時は安全なデフォルト（0 / 卵なし）を返し、画面を落とさない
  /// （TODO: Drift キャッシュへのフォールバックは永続化パスで配線 / S8）。
  Future<HomeServerSnapshot> loadServerSnapshot(EconomyParams params) async {
    if (!Env.hasSupabase || !_ref.read(isOnlineProvider)) {
      return HomeServerSnapshot.empty;
    }
    try {
      final client = _ref.read(supabaseClientProvider);

      // 残高・プールpt（profiles の本人行 / RLS本人select）。
      final profile = await client
          .from('profiles')
          .select('point_balance, gem_balance, pooled_points')
          .maybeSingle();

      // アクティブ卵（育成中・is_active / S6: 1枠のみ）。無ければ空状態。
      final egg = await client
          .from('eggs')
          .select('id, rarity, growth_points')
          .eq('is_active', true)
          .eq('location', 'incubating')
          .maybeSingle();

      ActiveEggSummary? active;
      if (egg != null) {
        active = ActiveEggSummary(
          eggId: '${egg['id']}',
          growthPoints: (egg['growth_points'] as num?)?.toInt() ?? 0,
          hatchThreshold: params.eggThresholds.hatch,
          rarityLabel: '${egg['rarity']}',
        );
      }

      return HomeServerSnapshot(
        pointBalance: (profile?['point_balance'] as num?)?.toInt() ?? 0,
        gemBalance: (profile?['gem_balance'] as num?)?.toInt() ?? 0,
        pooledPoints: (profile?['pooled_points'] as num?)?.toInt() ?? 0,
        activeEgg: active,
      );
    } catch (e, st) {
      // 確定値が取れなくても画面は出す（5状態: オフライン/エラーは局所表示）。
      Log.e('loadServerSnapshot failed', error: e, stack: st);
      return HomeServerSnapshot.empty;
    }
  }

  /// ウォームアップ自動付与（S1 / F-01）をサーバーへ要求する。
  ///
  /// 信頼境界（§2-3 / S1）: 付与（Day1=200 / Day2=300）と初回ボーナス卵への充当は
  /// サーバー RPC `fn_claim_warmup(p_day)` の責務。冪等キーは **生涯1回**（uid×'warmup'×day）
  /// なので、初回体験ごとに無条件に呼んでよい（2回目以降はサーバーが冪等スキップ）。
  ///
  /// Supabase 未設定（Mock 時）/ オフライン時は no-op で null を返し、画面を落とさない
  /// （PoC/UI 確認では warmup はサーバー責務のため何もしない）。失敗時も例外を投げず null。
  Future<WarmupClaimResult?> claimWarmupIfNeeded(int day) async {
    if (!Env.hasSupabase || !_ref.read(isOnlineProvider)) {
      return null; // Mock/オフラインは no-op（サーバー責務）。
    }
    try {
      final client = _ref.read(supabaseClientProvider);
      final res = await client.rpc('fn_claim_warmup', params: {'p_day': day});
      if (res is! Map) return null;
      return WarmupClaimResult.fromJson(res.cast<String, Object?>());
    } catch (e, st) {
      // 付与に失敗しても画面は出す（生涯1回キーなので後続呼び出しで再試行可能）。
      Log.e('claimWarmupIfNeeded failed', error: e, stack: st);
      return null;
    }
  }
}

/// 利用取得の結果（成功/権限なし/取得失敗 を型で表現）。
class HomeUsageResult {
  final UsagePermissionStatus permission;
  final DailyUsage? todayUsage;

  /// 常に非nullで返す（権限なし/失敗時も warmup baseline を載せ、画面を落とさない）。
  final Baseline baseline;
  final int provisionalPoints;
  final int? yesterdayMinutes;
  final String? errorMessage;
  final HomeUsageStatus status;

  const HomeUsageResult._({
    required this.permission,
    required this.status,
    required this.baseline,
    this.todayUsage,
    this.provisionalPoints = 0,
    this.yesterdayMinutes,
    this.errorMessage,
  });

  factory HomeUsageResult.success({
    required UsagePermissionStatus permission,
    required DailyUsage todayUsage,
    required Baseline baseline,
    required int provisionalPoints,
    required int? yesterdayMinutes,
  }) =>
      HomeUsageResult._(
        permission: permission,
        status: HomeUsageStatus.ok,
        todayUsage: todayUsage,
        baseline: baseline,
        provisionalPoints: provisionalPoints,
        yesterdayMinutes: yesterdayMinutes,
      );

  factory HomeUsageResult.noPermission(
    UsagePermissionStatus p,
    Baseline baseline,
  ) =>
      HomeUsageResult._(
        permission: p,
        status: HomeUsageStatus.noPermission,
        baseline: baseline,
      );

  factory HomeUsageResult.fetchError(
    UsagePermissionStatus p,
    Baseline baseline,
    String message,
  ) =>
      HomeUsageResult._(
        permission: p,
        status: HomeUsageStatus.fetchError,
        baseline: baseline,
        errorMessage: message,
      );
}

enum HomeUsageStatus { ok, noPermission, fetchError }

/// サーバー/キャッシュ由来のスナップショット。
class HomeServerSnapshot {
  final int pointBalance;
  final int gemBalance;
  final int pooledPoints;
  final ActiveEggSummary? activeEgg;

  const HomeServerSnapshot({
    required this.pointBalance,
    required this.gemBalance,
    required this.pooledPoints,
    required this.activeEgg,
  });

  /// 未配線/オフライン/取得失敗時の安全なデフォルト（画面を落とさない）。
  static const HomeServerSnapshot empty = HomeServerSnapshot(
    pointBalance: 0,
    gemBalance: 0,
    pooledPoints: 0,
    activeEgg: null,
  );
}

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  return HomeRepository(ref);
});

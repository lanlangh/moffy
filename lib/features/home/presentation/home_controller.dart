import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/remote_config.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/sync/finalize_models.dart';
import '../../../core/usage/usage_providers.dart';
import '../data/home_repository.dart';
import '../data/warmup_tracker.dart';
import '../domain/home_state.dart';

/// ホームの状態管理（ARCHITECTURE §1-3 / AsyncNotifier）。
///
/// AsyncValue<HomeState> により loading / error が型で強制される（5状態のうち2つを担保）。
/// 権限なし・取得失敗・オフラインは [HomeState] のフラグ + data として返し、
/// 画面側で局所的に 5状態を出し分ける（全画面エラーにしない / SCREEN_FLOWS §2）。
class HomeController extends AsyncNotifier<HomeState> {
  @override
  Future<HomeState> build() async {
    return _load();
  }

  Future<HomeState> _load() async {
    final repo = ref.read(homeRepositoryProvider);
    final params = await ref.watch(economyParamsProvider.future);
    final targets = ref.read(targetPackagesProvider);
    final isOnline = ref.watch(isOnlineProvider);

    // サーバー/キャッシュ（通貨・卵）は権限の有無に関わらず取得（部分エラーにしない）。
    var snapshot = await repo.loadServerSnapshot(params);

    // 利用取得（権限なし/失敗でも baseline は warmup フォールバックで非null）。
    final usage = await repo.loadUsage(
      params: params,
      targetPackages: targets,
    );

    // F-01 ウォームアップ自動付与（S1）。
    // ウォームアップ期（Day1〜2 相当）のホーム初回ロードで `claimWarmupIfNeeded(day)` を発火する。
    // 信頼境界（§2-3）: 付与の正はサーバー RPC。クライアントは「いつ Day1/Day2 を呼ぶか」を
    // ローカル初回起動日から粗く決めて呼ぶだけ（冪等キーは生涯1回なので二重呼びは安全）。
    // 5状態: 付与成功=祝福 / 未対象=通常 / オフライン=後で再試行 / エラー=黙って通常表示。
    WarmupGrantSummary? warmupGrant;
    if (usage.baseline.isWarmup) {
      warmupGrant = await _claimWarmup(repo);
      // 新規付与があれば残高・卵が増えるのでサーバー値を取り直す（祝福と整合）。
      if (warmupGrant != null) {
        snapshot = await repo.loadServerSnapshot(params);
      }
    }

    return HomeState(
      permission: usage.permission,
      todayUsage: usage.todayUsage,
      baseline: usage.baseline,
      provisionalPoints: usage.provisionalPoints,
      yesterdayMinutes: usage.yesterdayMinutes,
      activeEgg: snapshot.activeEgg,
      pointBalance: snapshot.pointBalance,
      gemBalance: snapshot.gemBalance,
      pooledPoints: snapshot.pooledPoints,
      isOffline: !isOnline,
      params: params,
      warmupGrant: warmupGrant,
    );
  }

  /// ウォームアップ Day（1|2）を解決して付与要求し、**新規付与時のみ**祝福サマリを返す。
  ///
  /// 受取済み（生涯1回キーの冪等スキップ）/ 未対象 / オフライン / エラーは null
  /// （= 通常ホーム。責めない・黙って通常表示 / 受け入れ §5-1）。
  Future<WarmupGrantSummary?> _claimWarmup(HomeRepository repo) async {
    final day = await ref.read(warmupTrackerProvider).resolveWarmupDay(
          DateTime.now(),
        );
    if (day == null) return null; // ウォームアップ卒業（暫定基準フェーズへ）。

    final WarmupClaimResult? res = await repo.claimWarmupIfNeeded(day);
    // null = Mock/オフライン/エラー（no-op）。再試行は次回ロードで可能（生涯1回キー）。
    if (res == null) return null;
    // 新規付与（granted>0）でのみ祝福を出す。冪等スキップ（既受取）は通常ホーム。
    if (res.granted <= 0 || res.alreadyClaimed) return null;
    return WarmupGrantSummary(day: res.day, grantedPoints: res.granted);
  }

  /// pull-to-refresh / 権限付与後の再取得。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// 権限要求（OS設定へ誘導）後に再読込する。画面の再付与ボタンから呼ぶ。
  Future<void> requestPermissionAndReload() async {
    final usageProvider = ref.read(usageProviderProvider);
    await usageProvider.requestPermission();
    await refresh();
  }
}

/// ホームコントローラの Provider。
final homeControllerProvider =
    AsyncNotifierProvider<HomeController, HomeState>(HomeController.new);

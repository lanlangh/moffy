import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/remote_config.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/usage/usage_providers.dart';
import '../data/home_repository.dart';
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
    final snapshot = await repo.loadServerSnapshot(params);

    // 利用取得（権限なし/失敗でも baseline は warmup フォールバックで非null）。
    final usage = await repo.loadUsage(
      params: params,
      targetPackages: targets,
    );

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
    );
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

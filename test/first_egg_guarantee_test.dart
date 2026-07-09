import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/observability/analytics.dart';
import 'package:moffy/core/observability/analytics_events.dart';
import 'package:moffy/core/observability/observability_providers.dart';
import 'package:moffy/core/sync/finalize_models.dart';
import 'package:moffy/features/eggs/data/egg_repository.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';
import 'package:moffy/features/eggs/presentation/eggs_controller.dart';

/// FTUE「最初の卵保証」のコントローラ・オーケストレーション単体テスト（migration 0009 配線）。
///
/// 検証対象は EggsController._load の「巣が完全に空なら ensureFirstEgg を呼び、付与できたら
/// 1回だけ再読込して卵を出す」ロジックと、FTUE ファネル計測（first_egg_granted）を
/// 「生涯初回（is_first_ever）のみ」に絞る配線。付与判断そのものはサーバー RPC の責務なので、
/// ここではリポジトリと Analytics を差し替えて制御フローと計測ゲートを担保する。
void main() {
  ProviderContainer containerWith(
    _FakeEggRepository fake, {
    _RecordingAnalytics? analytics,
  }) {
    final container = ProviderContainer(
      overrides: [
        eggRepositoryProvider.overrideWithValue(fake),
        if (analytics != null)
          analyticsProvider.overrideWithValue(analytics),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('巣が完全に空なら ensureFirstEgg を呼び、卵が出るまで1回だけ再読込する', () async {
    final fake = _FakeEggRepository(startEmpty: true);
    final container = containerWith(fake);

    final state = await container.read(eggsControllerProvider.future);

    // 最終状態: 巣に卵が出ている（空でない）。
    expect(state.isCompletelyEmpty, isFalse);
    expect(state.activeEgg?.id, 'e1');
    // 保証は1回、ロードは「初回の空 + 付与後の再読込」の2回。
    expect(fake.ensureCalls, 1);
    expect(fake.loadCalls, 2);
  });

  test('既に卵があるときは ensureFirstEgg を呼ばず、再読込もしない', () async {
    final fake = _FakeEggRepository(startEmpty: false);
    final container = containerWith(fake);

    final state = await container.read(eggsControllerProvider.future);

    expect(state.activeEgg?.id, 'e1');
    expect(fake.ensureCalls, 0); // 空でないので保証は要求しない
    expect(fake.loadCalls, 1); // 再読込なし
  });

  test('空でも保証に失敗（granted=false）したら再読込しない（次回ロードで再試行）', () async {
    // オフライン/未配線/失敗を模した「空だが付与できない」ケース。
    final fake = _FakeEggRepository(startEmpty: true, grant: EnsureFirstEggResult.notGranted);
    final container = containerWith(fake);

    final state = await container.read(eggsControllerProvider.future);

    expect(state.isCompletelyEmpty, isTrue); // 空のまま（画面は止めない）
    expect(fake.ensureCalls, 1);
    expect(fake.loadCalls, 1); // 付与できなかったので再読込しない
  });

  test('生涯初回の付与では first_egg_granted を1回だけ計測する', () async {
    final analytics = _RecordingAnalytics();
    final fake = _FakeEggRepository(
      startEmpty: true,
      grant: const EnsureFirstEggResult(
        granted: true,
        reason: 'granted',
        eggId: 'e1',
        rarity: 'normal',
        isFirstEver: true,
      ),
    );
    final container = containerWith(fake, analytics: analytics);

    await container.read(eggsControllerProvider.future);

    expect(analytics.events, [AnalyticsEvents.firstEggGranted]);
  });

  test('復帰ユーザーの refill（is_first_ever=false）では計測しない（funnel 水増し防止）', () async {
    final analytics = _RecordingAnalytics();
    final fake = _FakeEggRepository(
      startEmpty: true,
      grant: const EnsureFirstEggResult(
        granted: true,
        reason: 'granted',
        eggId: 'e1',
        rarity: 'normal',
        isFirstEver: false, // 全孵化して空になった復帰ユーザー
      ),
    );
    final container = containerWith(fake, analytics: analytics);

    final state = await container.read(eggsControllerProvider.future);

    // 卵は出る（再読込される）が、FTUE ファネルには計上しない。
    expect(state.activeEgg?.id, 'e1');
    expect(fake.loadCalls, 2);
    expect(analytics.events, isEmpty);
  });
}

/// 「空→保証→再読込」の制御フローだけを検証するための最小フェイク。
///
/// [startEmpty]=true なら初回 loadEggs は空を返し、ensureFirstEgg 成功後は卵入りを返す。
/// [grant] は ensureFirstEgg の戻り（既定=生涯初回付与）。オフライン/失敗は notGranted を渡す。
class _FakeEggRepository implements EggRepository {
  _FakeEggRepository({
    required this.startEmpty,
    EnsureFirstEggResult? grant,
  }) : grant = grant ??
            const EnsureFirstEggResult(
              granted: true,
              reason: 'granted',
              eggId: 'e1',
              rarity: 'normal',
              isFirstEver: true,
            );

  final bool startEmpty;
  final EnsureFirstEggResult grant;
  bool _granted = false;
  int ensureCalls = 0;
  int loadCalls = 0;

  Egg? get _active {
    final hasEgg = !startEmpty || _granted;
    return hasEgg
        ? const Egg(
            id: 'e1',
            rarity: EggRarity.normal,
            growthPoints: 0,
            location: EggLocation.incubating,
            slotIndex: 1,
            isActive: true,
            acquiredSource: 'starter',
          )
        : null;
  }

  @override
  Future<EggsState> loadEggs(EconomyParams params) async {
    loadCalls++;
    return EggsState(
      incubatorSlots: [_active, null, null],
      storage: const [],
      pooledPoints: 0,
      isOffline: false,
      params: params,
    );
  }

  @override
  Future<EnsureFirstEggResult> ensureFirstEgg() async {
    ensureCalls++;
    if (!startEmpty || _granted) return EnsureFirstEggResult.notGranted;
    if (grant.granted) _granted = true;
    return grant;
  }

  @override
  Future<void> setActiveEgg(String eggId) => throw UnimplementedError();

  @override
  Future<void> moveToStorage(String eggId) => throw UnimplementedError();

  @override
  Future<void> moveToIncubator({
    required String eggId,
    required int slotIndex,
  }) =>
      throw UnimplementedError();

  @override
  Future<HatchResult> hatch(String eggId) => throw UnimplementedError();
}

/// capture されたイベント名を記録する最小 Analytics（計測ゲートの検証用）。
class _RecordingAnalytics implements Analytics {
  final List<String> events = [];

  @override
  void capture(String event, {Map<String, Object>? properties}) =>
      events.add(event);

  @override
  void identifyAnonymous(String anonymousUserId) {}

  @override
  void reset() {}
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/core/sync/finalize_models.dart';
import 'package:moffy/features/collection/domain/mofi_models.dart';
import 'package:moffy/features/eggs/data/egg_repository.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';
import 'package:moffy/features/eggs/presentation/eggs_screen.dart';
import 'package:moffy/features/eggs/presentation/widgets/hatch_overlay.dart';

/// 「孵化させる」を押したら、通信に時間がかかっても孵化演出が出ること。
///
/// なぜこのテストが要るか（2026-10-23 本番 1.2.1 で発生）:
///   孵化の RPC は成功しているのに演出が出ず、巣が空になったので新しい 0% の卵だけが
///   置かれた。孵化後の再読込で EggsController が loading に戻り、たまご画面が
///   スケルトンに差し替わって `_EggsBody` が破棄され、`_hatch` が
///   `context.mounted` で黙って抜けていた。
///   モックは待ちが無く、loading と data の間にフレームが挟まらないので、既存の
///   テストと Web プレビューでは再現しなかった。ここでは通信の待ちを入れて本番を模す。
void main() {
  testWidgets('通信に時間がかかっても、孵化させるを押すと孵化演出が出る', (tester) async {
    // 既定の 800x600 だと詳細シートの下のボタンが画面外に出るので、縦長の端末にする。
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final repo = _SlowEggRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          eggRepositoryProvider.overrideWithValue(repo),
          isOnlineProvider.overrideWithValue(true),
        ],
        child: const MaterialApp(home: EggsScreen()),
      ),
    );
    // 初回の読み込み（待ちあり）。
    await tester.pump();
    await tester.pump(_SlowEggRepository.latency * 2);
    expect(find.text('育成枠'), findsOneWidget);

    // 主役ステージの卵をタップ → 詳細シート → 孵化させる。
    // 卵は揺れ続けるので pumpAndSettle は使えない（終わらない）。時間を指定して回す。
    await tester.tap(find.text('まもなく孵化').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final hatchButton = find.text('孵化させる');
    await tester.ensureVisible(hatchButton);
    await tester.pump();
    await tester.tap(hatchButton);

    // 孵化 RPC → 再読込（空なので最初の卵保証 → もう一度読込）。待ちのたびにフレームを回す。
    for (var i = 0; i < 12; i++) {
      await tester.pump(_SlowEggRepository.latency);
    }

    expect(repo.hatchCalls, 1);
    expect(
      find.byType(HatchOverlay),
      findsOneWidget,
      reason: '孵化は成功したのに演出が出ていない（再読込で画面が作り直された）',
    );

    // 演出のタイマーを流しきってから閉じる（テスト終了時の保留タイマー対策）。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  });
}

/// 本番の Supabase を模して、すべての呼び出しに待ちを入れたフェイク。
///
/// 卵は孵化可能な1つだけ。孵化すると巣が空になり、`ensureFirstEgg` が 0pt の
/// 新しい卵を付与する（本番の fn_ensure_first_egg と同じ流れ）。
class _SlowEggRepository implements EggRepository {
  static const latency = Duration(milliseconds: 120);

  int hatchCalls = 0;
  bool _hatched = false;
  bool _refilled = false;

  Egg? get _active {
    if (!_hatched) {
      return const Egg(
        id: 'egg_ready',
        rarity: EggRarity.normal,
        growthPoints: 520,
        location: EggLocation.incubating,
        slotIndex: 1,
        isActive: true,
        acquiredSource: 'starter',
      );
    }
    if (_refilled) {
      return const Egg(
        id: 'egg_refill',
        rarity: EggRarity.normal,
        growthPoints: 0,
        location: EggLocation.incubating,
        slotIndex: 1,
        isActive: true,
        acquiredSource: 'starter',
      );
    }
    return null;
  }

  @override
  Future<EggsState> loadEggs(EconomyParams params) async {
    await Future<void>.delayed(latency);
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
    await Future<void>.delayed(latency);
    if (_active != null) return EnsureFirstEggResult.notGranted;
    _refilled = true;
    return const EnsureFirstEggResult(
      granted: true,
      reason: 'granted',
      eggId: 'egg_refill',
      rarity: 'normal',
    );
  }

  @override
  Future<HatchResult> hatch(String eggId) async {
    hatchCalls++;
    await Future<void>.delayed(latency);
    _hatched = true;
    return HatchResult(
      species: const MofiSpecies(
        id: 'dragon_01',
        family: MofiFamily.dragon,
        rarity: MofiRarity.common,
        name: 'とかげり',
        sortOrder: 11,
      ),
      isShiny: false,
      isNewDexEntry: true,
      fromEggId: eggId,
    );
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
}

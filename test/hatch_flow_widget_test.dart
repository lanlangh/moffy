import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
  /// たまご画面を出す（本番と同じく router の下・初回の読み込みの待ちを流す）。
  Future<void> openEggsScreen(
    WidgetTester tester,
    _SlowEggRepository repo,
  ) async {
    // 既定の 800x600 だと詳細シートの下のボタンが画面外に出るので、縦長の端末にする。
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          eggRepositoryProvider.overrideWithValue(repo),
          isOnlineProvider.overrideWithValue(true),
        ],
        // 孵化の処理は GoRouter.of(context) を使うので、本番と同じく router の下に置く。
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, __) => const EggsScreen()),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(_SlowEggRepository.latency * 2);
    expect(find.text('育成枠'), findsOneWidget);
  }

  /// 主役ステージの卵 → 詳細シート → 「孵化させる」を押す（待ちは流さない）。
  Future<void> tapHatch(WidgetTester tester) async {
    // 卵は揺れ続けるので pumpAndSettle は使えない（終わらない）。時間を指定して回す。
    await tester.tap(find.text('まもなく孵化').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final hatchButton = find.text('孵化させる');
    await tester.ensureVisible(hatchButton);
    await tester.pump();
    await tester.tap(hatchButton);
    await tester.pump();
  }

  /// 孵化 RPC → 再読込（空なので最初の卵保証 → もう一度読込）。待ちのたびにフレームを回す。
  Future<void> waitForHatch(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(_SlowEggRepository.latency);
    }
  }

  /// 演出のタイマーを流しきってから閉じる（テスト終了時の保留タイマー対策）。
  Future<void> tearDownOverlay(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('通信に時間がかかっても、孵化させるを押すと孵化演出が出る', (tester) async {
    final repo = _SlowEggRepository();
    await openEggsScreen(tester, repo);
    await tapHatch(tester);
    await waitForHatch(tester);

    expect(repo.hatchCalls, 1);
    expect(
      find.byType(HatchOverlay),
      findsOneWidget,
      reason: '孵化は成功したのに演出が出ていない（再読込で画面が作り直された）',
    );
    await tearDownOverlay(tester);
  });

  testWidgets('孵化後の再読込が失敗しても、孵化演出は出る（孵化はサーバーで確定済み）',
      (tester) async {
    // 再読込の失敗でたまご画面はエラー表示に差し替わり、押した側の画面は破棄される。
    // それでも演出を出す（ここで黙って抜けると、孵化した子を一度も見られない）。
    final repo = _SlowEggRepository(failReloadAfterHatch: true);
    await openEggsScreen(tester, repo);
    await tapHatch(tester);
    await waitForHatch(tester);

    expect(repo.hatchCalls, 1);
    expect(
      find.byType(HatchOverlay),
      findsOneWidget,
      reason: '再読込の失敗で画面が作り直され、演出が出ていない',
    );
    await tearDownOverlay(tester);
  });

  testWidgets('孵化の通信中にもう一度押しても、孵化は1回だけで演出も1つ', (tester) async {
    final repo = _SlowEggRepository(hatchLatency: const Duration(seconds: 3));
    await openEggsScreen(tester, repo);
    await tapHatch(tester);
    // シートが閉じきるのを待ってから、1回目の RPC が終わる前に同じ卵をもう一度押す。
    await tester.pump(const Duration(milliseconds: 400));
    await tapHatch(tester);
    await tester.pump(const Duration(seconds: 3));
    await waitForHatch(tester);

    expect(repo.hatchCalls, 1);
    expect(find.byType(HatchOverlay), findsOneWidget);
    await tearDownOverlay(tester);
  });

  testWidgets('最後の卵を孵化して新しい卵が付与されなくても、孵化した子はステージに残る',
      (tester) async {
    final repo = _SlowEggRepository(grantRefill: false);
    await openEggsScreen(tester, repo);
    await tapHatch(tester);
    await waitForHatch(tester);
    expect(find.byType(HatchOverlay), findsOneWidget);

    // 演出を最後まで流して「とじる」。
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('とじる'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(HatchOverlay), findsNothing);
    expect(
      find.text('図鑑に送る'),
      findsOneWidget,
      reason: '巣が空になったら空表示が優先され、孵化した子が見えなくなっている',
    );
    expect(find.text('まだ卵がありません'), findsNothing);
    await tearDownOverlay(tester);
  });
}

/// 本番の Supabase を模して、すべての呼び出しに待ちを入れたフェイク。
///
/// 卵は孵化可能な1つだけ。孵化すると巣が空になり、`ensureFirstEgg` が 0pt の
/// 新しい卵を付与する（本番の fn_ensure_first_egg と同じ流れ）。
/// [failReloadAfterHatch] が true なら、孵化後の読み込みは通信エラーで失敗する。
/// [grantRefill] が false なら、空になっても新しい卵は付与されない（付与の失敗を模す）。
/// [hatchLatency] は孵化 RPC だけの待ち（通信中の二度押しを試すときに長くする）。
class _SlowEggRepository implements EggRepository {
  _SlowEggRepository({
    this.failReloadAfterHatch = false,
    this.grantRefill = true,
    this.hatchLatency = latency,
  });

  static const latency = Duration(milliseconds: 120);

  final bool failReloadAfterHatch;
  final bool grantRefill;
  final Duration hatchLatency;
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
    if (failReloadAfterHatch && _hatched) {
      throw Exception('network error after hatch');
    }
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
    if (_active != null || !grantRefill) return EnsureFirstEggResult.notGranted;
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
    await Future<void>.delayed(hatchLatency);
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

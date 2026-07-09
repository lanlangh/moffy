import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/remote_config.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/observability_providers.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../data/egg_repository.dart';
import '../domain/egg_models.dart';

/// たまご画面の状態管理（ARCHITECTURE §1-3 / AsyncNotifier）。
///
/// AsyncValue<EggsState> で loading/error を型で担保。枠操作（切替・入替）は
/// リポジトリへ委譲し、完了後に再読込する。孵化は別途 [hatch] で実行し、
/// 結果（[HatchResult]）を画面が受け取って演出する（抽選はサーバー / ARCHITECTURE §2-3）。
class EggsController extends AsyncNotifier<EggsState> {
  @override
  Future<EggsState> build() => _load();

  Future<EggsState> _load() async {
    final params = await ref.watch(economyParamsProvider.future);
    final repo = ref.read(eggRepositoryProvider);
    var state = await repo.loadEggs(params);

    // FTUE 最初の卵保証（復帰フォールバック / migration 0009・2026-07-07 決定）。
    // 巣が完全に空（育成枠も保管枠も空）のとき、サーバーへ標準卵1つを冪等付与要求し、
    // 新規に付与できたら1回だけ再読込して巣に卵を出す。ウォームアップ窓（Day1/2）や
    // ローカル日付に依存せず、「空の巣で手詰まり」を状態ベースで根治する（新規も、全孵化して
    // 空になった復帰ユーザーも救済）。Mock/オフライン/失敗は granted=false で通常表示。
    // ホームは eggsController を watch するため、この保証はたまご/ホーム双方に効く（単一経路）。
    if (state.isCompletelyEmpty) {
      final res = await repo.ensureFirstEgg();
      if (res.granted) {
        // FTUE ファネル計測は「生涯初回の卵」のみ（is_first_ever）。復帰ユーザーが全孵化して
        // 空になり再付与された refill では発火させない（funnel の水増しを防ぐ）。
        if (res.isFirstEver) {
          ref.read(analyticsProvider).capture(AnalyticsEvents.firstEggGranted);
        }
        state = await repo.loadEggs(params);
      }
    }
    return state;
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// アクティブ卵（加点対象 / S6: 1枠のみ）を切り替える。
  Future<void> setActive(String eggId) async {
    await ref.read(eggRepositoryProvider).setActiveEgg(eggId);
    await refresh();
  }

  /// 育成枠の卵を保管枠へ戻す（枠を空ける / S6）。
  Future<void> moveToStorage(String eggId) async {
    await ref.read(eggRepositoryProvider).moveToStorage(eggId);
    await refresh();
  }

  /// 保管枠の卵を空き育成枠へセットする（S6）。
  Future<void> moveToIncubator(String eggId, int slotIndex) async {
    final current = state.valueOrNull;
    if (current == null) throw StateError('Egg state is not loaded');
    final actualSlot = current.firstEmptySlotIndex;
    if (actualSlot == null) {
      throw StateError('All incubator slots are occupied');
    }
    // A bottom sheet can outlive the snapshot it was built from.
    slotIndex = actualSlot;
    await ref
        .read(eggRepositoryProvider)
        .moveToIncubator(eggId: eggId, slotIndex: slotIndex);
    await refresh();
  }

  /// 孵化を確定する（オンライン必須 / S8）。
  ///
  /// オフライン時は null を返し、画面側で「接続したら確定」を出す（二重孵化防止）。
  /// 成功時は結果を返し、状態も再読込する。失敗は例外を投げ、画面でリトライ表示。
  Future<HatchResult?> hatch(String eggId) async {
    final isOnline = ref.read(isOnlineProvider);
    if (!isOnline) return null; // S8: 孵化確定はオンラインのみ
    final result = await ref.read(eggRepositoryProvider).hatch(eggId);
    await refresh();
    return result;
  }
}

final eggsControllerProvider =
    AsyncNotifierProvider<EggsController, EggsState>(EggsController.new);

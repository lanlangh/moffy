import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/remote_config.dart';
import '../../../core/error/failure.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../data/quest_repository.dart';
import '../domain/quest_models.dart';

/// クエスト画面の状態管理（ARCHITECTURE §1-3 / AsyncNotifier）。
///
/// AsyncValue<QuestsState> で loading/error を型で担保。受取（claim）はリポジトリへ委譲し、
/// 完了後に再読込する。受取の確定はサーバーRPCの責務であり、ここは「口」を呼ぶだけ。
class QuestsController extends AsyncNotifier<QuestsState> {
  @override
  Future<QuestsState> build() => _load();

  Future<QuestsState> _load() async {
    final params = await ref.watch(economyParamsProvider.future);
    final repo = ref.read(questRepositoryProvider);
    return repo.loadQuests(params);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// 達成済みクエストの報酬を受け取る（オンライン必須 / S8）。
  ///
  /// オフライン時は [NetworkFailure] を返し、画面側で理由表示する（二重消費防止）。
  /// 成功時は null（=エラーなし）を返し、状態を再読込する。失敗時は [Failure] を返し
  /// 画面でスナックバー表示する（二重付与せずリトライ可能 / §5-3）。
  Future<Failure?> claim(String questId) async {
    final isOnline = ref.read(isOnlineProvider);
    if (!isOnline) {
      return const NetworkFailure('受け取りには接続が必要です');
    }
    try {
      await ref.read(questRepositoryProvider).claimReward(questId);
      // TODO(観測・未配線): ここで analyticsProvider.capture(AnalyticsEvents.questClaimed)
      //   を発火する（PRD §5-5 リテンション補助）。スコープ上、本パスでは定義のみ。
      await refresh();
      return null;
    } on Failure catch (f) {
      return f;
    } catch (_) {
      return const UnknownFailure('受け取りに失敗しました。もう一度お試しください。');
    }
  }
}

final questsControllerProvider =
    AsyncNotifierProvider<QuestsController, QuestsState>(QuestsController.new);

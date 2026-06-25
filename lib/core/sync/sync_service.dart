import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../observability/log.dart';
import 'conflict_resolver.dart';
import 'connectivity_provider.dart';
import 'finalize_models.dart';
import 'sync_models.dart';
import 'sync_queue.dart';
import 'usage_sync_repository.dart';

/// オフライン同期エンジンの実装骨子（ARCHITECTURE §1-5 / S8）。
///
/// 役割:
///   * オンライン復帰検知（[connectivityStreamProvider] を監視）。
///   * 復帰時に [SyncQueue] の操作を順次サーバーへ反映（各RPCは冪等なので二重実行安全）。
///   * 生データ提出 → サーバー確定（fn_finalize_day）→ 確定値取得 → 競合解決（別途
///     [ConflictResolver]）の流れを駆動する。
///
/// 信頼境界（S8）:
///   * 実際のRPC送信（fn_finalize_day / fn_hatch_egg / fn_grant_quest_reward）は
///     **サーバーの責務**。本サービスは「いつ・どの順で送るか」を司るだけで、
///     抽選・残高加算・確定計算は一切クライアントで行わない（TODO明示）。
class SyncService {
  SyncService(this._ref);

  final Ref _ref;

  /// 復帰時の一括同期。キューの操作を順に送信し、結果を集計して返す。
  ///
  /// オフライン中は何もしない（呼び出し側がオンライン時にだけ起動する想定だが、
  /// 二重防御でここでも接続を確認する）。
  Future<SyncOutcome> syncNow() async {
    final isOnline = _ref.read(isOnlineProvider);
    if (!isOnline) {
      Log.d('syncNow skipped: offline');
      return const SyncOutcome();
    }

    final queue = _ref.read(syncQueueProvider);
    final ops = await queue.pending();
    if (ops.isEmpty) return const SyncOutcome();

    var succeeded = 0;
    var retryable = 0;

    // 投入順に送信（生データ提出 → 確定依存の孵化/受取 の順序を保つため）。
    for (final op in ops) {
      try {
        await _dispatch(op);
        await queue.remove(op.id);
        succeeded++;
      } catch (e, st) {
        // 一時失敗: キューに残し再試行（冪等なので次回再送しても安全 / S8）。
        Log.e('sync op failed: ${op.type.wire}', error: e, stack: st);
        await queue.markRetried(op.id);
        retryable++;
      }
    }

    return SyncOutcome(succeeded: succeeded, retryable: retryable);
  }

  /// 1操作をサーバーへ反映する（種別ごとのRPC/insertへ振り分け）。
  ///
  /// 信頼境界（§2-3）: 確定計算・抽選・残高加算は **すべてサーバー RPC** の責務。
  /// 本サービスは「いつ・どの順で送るか」と「確定結果のS8競合解決」を司るのみ。
  ///   * submitUsageDaily → usage_daily へ提出 → fn_finalize_day（[UsageSyncRepository]）。
  ///   * hatchEgg         → fn_hatch_egg（抽選・図鑑登録はサーバー）。
  ///   * grantQuestReward → fn_grant_quest_reward（残高加算はサーバー）。
  ///   * spendCurrency    → fn_spend_currency（原子的・オンラインのみ到達する）。
  ///
  /// TODO(後続): hatchEgg / grantQuestReward / spendCurrency は各 feature の
  ///   Supabase リポジトリ（fn_hatch_egg 等）が実装済みのため、本ディスパッチからも
  ///   payload 経由で呼べるよう配線する（現状は各画面から直接呼ぶ経路で成立）。
  Future<void> _dispatch(SyncOperation op) async {
    switch (op.type) {
      case SyncOpType.submitUsageDaily:
        await _submitUsageDaily(op);
        return;
      case SyncOpType.hatchEgg:
      case SyncOpType.grantQuestReward:
      case SyncOpType.spendCurrency:
        // 後続配線（上記 TODO）。現状は no-op で成功扱い（キュー順序の骨子は維持）。
        return;
    }
  }

  /// 未確定の利用生データを提出し fn_finalize_day で確定する（ARCHITECTURE §1-5 step1-3）。
  ///
  /// 確定結果は S8 競合解決（[ConflictResolver.resolveConfirmedPoints]）に通し、
  /// 「確定済みptを減らす方向の上書きはしない」（増える方向のみ反映 / ユーザー保護）。
  Future<void> _submitUsageDaily(SyncOperation op) async {
    final draft = UsageDailyDraft.fromPayload(op.payload);
    final repo = _ref.read(usageSyncRepositoryProvider);
    final result = await repo.submitAndFinalize(draft);

    if (!result.finalized) {
      // 未提出/異常値/未来日 or オフラインモック。確定値が無いのでローカル暫定を維持。
      Log.d('finalize skipped: ${draft.dateKey} reason=${result.reason}');
      return;
    }

    // TODO(観測・未配線): ここで analyticsProvider.capture(AnalyticsEvents.dayFinalized)
    //   を発火する（PRD §5-5 pt獲得ファネル）。確定ptの「数値」は載せず is_provisional 等の
    //   区分のみ（PII/生データ非送信）。スコープ上、本パスでは定義のみ。

    // S8: サーバー確定pt（today分）とローカル暫定ptを競合解決。減算は抑止する。
    //   already_finalized（冪等スキップ）時は pointsAwarded=0 のため、
    //   ローカル暫定を維持する側に倒れる（既加算分を画面から消さない）。
    final resolution = ConflictResolver.resolveConfirmedPoints(
      localValue: draft.localPoints,
      serverValue: result.pointsAwarded,
    );
    if (resolution.suppressedDecrease) {
      Log.d(
        'finalize ${draft.dateKey}: suppressed decrease '
        '(local=${draft.localPoints} > server=${result.pointsAwarded})',
      );
    }
    Log.d(
      'finalized ${draft.dateKey}: awarded=${result.pointsAwarded} '
      'streak=${result.streakAfter} stage=${result.stage} '
      'resolved=${resolution.resolvedValue}',
    );
  }

  /// 利用生データ提出操作をキューへ積む（ARCHITECTURE §1-5: オフライン中も積める / S8）。
  ///
  /// 冪等キー = `usage:<日付>`（usage_daily の (user×date) 一意 / fn_finalize_day も冪等）。
  /// オンライン時は [syncNow] が、オフライン時は復帰エッジが確定まで駆動する。
  Future<bool> enqueueUsageSubmission(UsageDailyDraft draft) {
    final queue = _ref.read(syncQueueProvider);
    final op = SyncOperation(
      type: SyncOpType.submitUsageDaily,
      id: 'usage:${draft.dateKey}',
      idempotencyKey: 'usage:${draft.dateKey}',
      payload: draft.toPayload(),
      enqueuedAt: DateTime.now(),
    );
    return queue.enqueue(op);
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(ref);
});

/// オンライン復帰を監視し、復帰時に自動で [SyncService.syncNow] を起動するプロバイダ。
///
/// アプリ起動時に `ref.watch(syncOnReconnectProvider)` で常駐させる想定（main/app）。
/// false→true（オフライン→オンライン）の遷移エッジでのみ同期を駆動する。
final syncOnReconnectProvider = Provider<void>((ref) {
  var wasOnline = ref.read(isOnlineProvider);
  ref.listen<bool>(isOnlineProvider, (prev, next) {
    final cameOnline = (prev == false || !wasOnline) && next == true;
    wasOnline = next;
    if (cameOnline) {
      // 復帰エッジ: 一括同期を起動（失敗はキューに残り次回再送 / S8）。
      Log.d('reconnected: triggering syncNow');
      // ignore: discarded_futures
      ref.read(syncServiceProvider).syncNow();
    }
  });
});

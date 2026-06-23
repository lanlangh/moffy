import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'conflict_resolver.dart';
import 'sync_models.dart';

/// ローカル操作の送信キュー（ARCHITECTURE §1-1 sync_queue / S8）。
///
/// 抽象を切り、本実装は Drift（`sync_queue` テーブル）に永続化する。第2bパスは
/// インメモリ実装 [InMemorySyncQueue] で骨子・競合ルール・テストを成立させる。
///
/// 信頼境界（S8）:
///   * 通貨消費（[SyncOpType.spendCurrency]）はオフライン中に積めない（二重消費防止）。
///     [enqueue] は [ConflictResolver.canEnqueueOffline] で弾く。
abstract interface class SyncQueue {
  /// 操作をキューに積む。積めた場合 true、オフライン消費系で拒否した場合 false。
  Future<bool> enqueue(SyncOperation op);

  /// 現在キューに残っている操作（投入順）。
  Future<List<SyncOperation>> pending();

  /// 操作を送信成功としてキューから除去する。
  Future<void> remove(String opId);

  /// 操作の試行回数をインクリメントする（バックオフ・恒久失敗判定用）。
  Future<void> markRetried(String opId);

  /// キューを空にする（退会時のローカルクリア等 / S12）。
  Future<void> clear();
}

/// インメモリ実装（第2bパス）。プロセス内でキュー操作・競合ルールを再現する。
/// TODO(本実装): Drift `sync_queue` テーブル + SyncQueueDao に置換（永続化 / S8）。
class InMemorySyncQueue implements SyncQueue {
  final List<SyncOperation> _ops = [];

  @override
  Future<bool> enqueue(SyncOperation op) async {
    // S8: 通貨消費はオフライン中キューに積まない（二重消費防止）。
    if (!ConflictResolver.canEnqueueOffline(op.type)) {
      return false;
    }
    // 冪等キー重複は積み直さない（同一操作の多重キューを防ぐ）。
    final dup = _ops.any((e) => e.idempotencyKey == op.idempotencyKey);
    if (dup) return true;
    _ops.add(op);
    return true;
  }

  @override
  Future<List<SyncOperation>> pending() async {
    final sorted = [..._ops]
      ..sort((a, b) => a.enqueuedAt.compareTo(b.enqueuedAt));
    return sorted;
  }

  @override
  Future<void> remove(String opId) async {
    _ops.removeWhere((e) => e.id == opId);
  }

  @override
  Future<void> markRetried(String opId) async {
    final i = _ops.indexWhere((e) => e.id == opId);
    if (i >= 0) {
      _ops[i] = _ops[i].copyWith(attempts: _ops[i].attempts + 1);
    }
  }

  @override
  Future<void> clear() async {
    _ops.clear();
  }
}

/// 同期キューの DI（ARCHITECTURE §1-3）。テストでは override 可能。
/// TODO(本実装): Drift 依存の DriftSyncQueue を返すよう切替。
final syncQueueProvider = Provider<SyncQueue>((ref) {
  return InMemorySyncQueue();
});

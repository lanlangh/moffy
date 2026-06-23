import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/sync/conflict_resolver.dart';
import 'package:moffy/core/sync/finalize_models.dart';
import 'package:moffy/core/sync/sync_models.dart';
import 'package:moffy/core/sync/sync_queue.dart';

/// 同期競合解決（S8）の単体テスト。代表ケース:
///   * 確定ポイントは「サーバー優先だが減算上書きしない」（増える方向のみ反映）。
///   * 通貨消費はオフライン不可（キューに積めない / 二重消費防止）。
///   * 生データはサーバー確定済み日はサーバー値、未確定は端末値。
void main() {
  group('ConflictResolver.resolveConfirmedPoints（S8: 減算上書きしない）', () {
    test('サーバー >= ローカル → サーバー採用（増加方向）', () {
      final r = ConflictResolver.resolveConfirmedPoints(
        localValue: 100,
        serverValue: 150,
      );
      expect(r.resolvedValue, 150);
      expect(r.suppressedDecrease, isFalse);
    });

    test('サーバー == ローカル → サーバー採用（変化なし）', () {
      final r = ConflictResolver.resolveConfirmedPoints(
        localValue: 100,
        serverValue: 100,
      );
      expect(r.resolvedValue, 100);
      expect(r.suppressedDecrease, isFalse);
    });

    test('サーバー < ローカル → ローカル維持・減算抑止（ユーザー保護）', () {
      final r = ConflictResolver.resolveConfirmedPoints(
        localValue: 200,
        serverValue: 120,
      );
      expect(r.resolvedValue, 200); // 減らさない
      expect(r.suppressedDecrease, isTrue); // 差分はログのみ
    });
  });

  group('ConflictResolver.resolveCurrencyBalance（S8: 通貨はサーバーが正）', () {
    test('常にサーバー値を採用', () {
      expect(
        ConflictResolver.resolveCurrencyBalance(serverValue: 42),
        42,
      );
    });
  });

  group('ConflictResolver.canEnqueueOffline（S8: 消費はオフライン不可）', () {
    test('通貨消費はオフラインで積めない', () {
      expect(
        ConflictResolver.canEnqueueOffline(SyncOpType.spendCurrency),
        isFalse,
      );
    });

    test('生データ提出・孵化・受取は積める（冪等RPC）', () {
      expect(
        ConflictResolver.canEnqueueOffline(SyncOpType.submitUsageDaily),
        isTrue,
      );
      expect(ConflictResolver.canEnqueueOffline(SyncOpType.hatchEgg), isTrue);
      expect(
        ConflictResolver.canEnqueueOffline(SyncOpType.grantQuestReward),
        isTrue,
      );
    });
  });

  group('ConflictResolver.resolveDailyUsageMinutes（S8: 確定日はサーバー）', () {
    test('サーバー確定済み → サーバー値', () {
      expect(
        ConflictResolver.resolveDailyUsageMinutes(
          localMinutes: 90,
          serverMinutes: 100,
          serverFinalized: true,
        ),
        100,
      );
    });

    test('サーバー未確定 → 端末値（生データSSOTは端末）', () {
      expect(
        ConflictResolver.resolveDailyUsageMinutes(
          localMinutes: 90,
          serverMinutes: 0,
          serverFinalized: false,
        ),
        90,
      );
    });
  });

  group('fn_finalize_day の確定結果 × S8競合解決（SyncService の整合）', () {
    // SyncService._submitUsageDaily と同じ規則: 確定pt(today分)とローカル暫定を
    // resolveConfirmedPoints に通し、減算は抑止する。
    PointResolution reconcile(int local, FinalizeDayResult r) =>
        ConflictResolver.resolveConfirmedPoints(
          localValue: local,
          serverValue: r.pointsAwarded,
        );

    test('サーバー確定 > ローカル暫定 → サーバー値を反映（増加方向）', () {
      const r = FinalizeDayResult(finalized: true, pointsAwarded: 200);
      final res = reconcile(120, r);
      expect(res.resolvedValue, 200);
      expect(res.suppressedDecrease, isFalse);
    });

    test('上限クランプでサーバー < ローカル → ローカル維持・減算抑止', () {
      const r = FinalizeDayResult(
        finalized: true,
        pointsAwarded: 480,
        capped: true,
      );
      final res = reconcile(600, r); // 端末暫定が上限を超えて先行していたケース
      expect(res.resolvedValue, 600);
      expect(res.suppressedDecrease, isTrue);
    });

    test('already_finalized（加算0）→ 既加算分を画面から消さない', () {
      const r = FinalizeDayResult(
        finalized: true,
        pointsAwarded: 0,
        alreadyFinalized: true,
      );
      final res = reconcile(150, r);
      expect(res.resolvedValue, 150); // 0 で上書きしない
      expect(res.suppressedDecrease, isTrue);
    });
  });

  group('InMemorySyncQueue（キューの基本動作 + S8 消費拒否）', () {
    SyncOperation op(
      SyncOpType type,
      String key, {
      String? id,
      DateTime? at,
    }) =>
        SyncOperation(
          id: id ?? key,
          type: type,
          payload: const {},
          idempotencyKey: key,
          enqueuedAt: at ?? DateTime(2026, 6, 19),
        );

    test('通貨消費はキューに積めない（false / 二重消費防止）', () async {
      final q = InMemorySyncQueue();
      final ok = await q.enqueue(op(SyncOpType.spendCurrency, 'spend_1'));
      expect(ok, isFalse);
      expect(await q.pending(), isEmpty);
    });

    test('冪等キー重複は二重に積まない', () async {
      final q = InMemorySyncQueue();
      await q.enqueue(op(SyncOpType.hatchEgg, 'egg_2026-06-19'));
      await q.enqueue(op(SyncOpType.hatchEgg, 'egg_2026-06-19', id: 'dup'));
      expect((await q.pending()).length, 1);
    });

    test('pending は投入時刻の昇順（順序保証）', () async {
      final q = InMemorySyncQueue();
      final late = op(
        SyncOpType.grantQuestReward,
        'late',
        at: DateTime(2026, 6, 19, 12),
      );
      final early = op(
        SyncOpType.submitUsageDaily,
        'early',
        at: DateTime(2026, 6, 19, 8),
      );
      await q.enqueue(late);
      await q.enqueue(early);
      final pending = await q.pending();
      expect(pending.first.idempotencyKey, 'early');
      expect(pending.last.idempotencyKey, 'late');
    });

    test('remove で除去 / markRetried で試行回数加算 / clear で空に', () async {
      final q = InMemorySyncQueue();
      await q.enqueue(op(SyncOpType.hatchEgg, 'k1', id: 'op1'));
      await q.markRetried('op1');
      expect((await q.pending()).first.attempts, 1);
      await q.remove('op1');
      expect(await q.pending(), isEmpty);

      await q.enqueue(op(SyncOpType.hatchEgg, 'k2'));
      await q.clear();
      expect(await q.pending(), isEmpty);
    });
  });
}

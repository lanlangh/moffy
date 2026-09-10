import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/quests/data/quest_repository.dart';
import 'package:moffy/features/quests/domain/quest_models.dart';

/// クエストの重複表示の回帰テスト（2026-09-10）。
///
/// 何が起きていたか:
///   `user_quests` は `unique(user_id, quest_id, period_start)` で、サーバーの
///   `fn_sync_quests` が毎日1行ずつ増やしていく。クライアントが period_start で
///   絞らずに全期間分を select していたため、**使った日数だけ同じクエストが並んでいた**。
///   本番実測で1ユーザーに「30分減らそう」15行 /「今週1000pt」7行。
///
/// 本来はサーバー側の `or()` で当期だけに絞る。[keepLatestPeriodPerKind] はその
/// 二重の安全策で、オフライン時（当期が分からない）と、将来サーバー側の絞りが
/// 壊れたときに効く。ここではその純関数だけを検証する。
void main() {
  Quest q(String id, QuestKind kind) => Quest(
        id: id,
        kind: kind,
        title: id,
        condition: const QuestCondition(
          type: QuestConditionType.reduceTotal,
          target: 30,
        ),
        reward: const QuestReward(points: 10),
        progress: 0,
        isCompleted: false,
        rewardGranted: false,
      );

  QuestRow row(String defId, QuestKind kind, String period) => (
        defId: defId,
        userQuestId: '$defId@$period',
        period: period,
        quest: q(defId, kind),
      );

  group('keepLatestPeriodPerKind', () {
    test('同じクエストが複数期間ぶんあっても、最新の期間だけが残る', () {
      final rows = [
        row('daily_reduce_30', QuestKind.daily, '2026-09-08'),
        row('daily_streak_keep', QuestKind.daily, '2026-09-08'),
        row('daily_reduce_30', QuestKind.daily, '2026-09-10'),
        row('daily_streak_keep', QuestKind.daily, '2026-09-10'),
        row('daily_reduce_30', QuestKind.daily, '2026-09-09'),
      ];

      final got = keepLatestPeriodPerKind(rows);

      expect(got.length, 2, reason: '定義2件なので2件だけ残るはず');
      expect(got.every((r) => r.period == '2026-09-10'), isTrue);
      expect(
        got.map((r) => r.defId).toSet(),
        {'daily_reduce_30', 'daily_streak_keep'},
      );
    });

    test('daily と weekly は別々に判定する（期間の刻みが違うため）', () {
      final rows = [
        // weekly は月曜起点なので daily より古い日付になるのが正常。
        row('weekly_hatch_3', QuestKind.weekly, '2026-09-07'),
        row('weekly_hatch_3', QuestKind.weekly, '2026-08-31'),
        row('daily_reduce_30', QuestKind.daily, '2026-09-10'),
        row('daily_reduce_30', QuestKind.daily, '2026-09-09'),
      ];

      final got = keepLatestPeriodPerKind(rows);

      expect(got.length, 2);
      final byKind = {for (final r in got) r.quest.kind: r};
      expect(byKind[QuestKind.daily]!.period, '2026-09-10');
      expect(
        byKind[QuestKind.weekly]!.period,
        '2026-09-07',
        reason: 'daily の 09-10 に引きずられて weekly が消えてはいけない',
      );
    });

    test('受取先に当期の user_quests.id を選ぶ（古い期間の行を掴まない）', () {
      final rows = [
        row('daily_reduce_30', QuestKind.daily, '2026-09-01'),
        row('daily_reduce_30', QuestKind.daily, '2026-09-10'),
      ];

      final got = keepLatestPeriodPerKind(rows);

      expect(got.single.userQuestId, 'daily_reduce_30@2026-09-10');
    });

    test('入力の並び順を保つ', () {
      final rows = [
        row('b', QuestKind.daily, '2026-09-10'),
        row('a', QuestKind.daily, '2026-09-10'),
        row('c', QuestKind.daily, '2026-09-09'),
      ];

      expect(
        keepLatestPeriodPerKind(rows).map((r) => r.defId).toList(),
        ['b', 'a'],
      );
    });

    test('空でも落ちない', () {
      expect(keepLatestPeriodPerKind(const []), isEmpty);
    });

    test('1期間しか無いときは何も落とさない', () {
      final rows = [
        row('daily_reduce_30', QuestKind.daily, '2026-09-10'),
        row('daily_streak_keep', QuestKind.daily, '2026-09-10'),
        row('weekly_hatch_3', QuestKind.weekly, '2026-09-07'),
      ];

      expect(keepLatestPeriodPerKind(rows).length, 3);
    });
  });
}

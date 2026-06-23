import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/features/quests/domain/quest_models.dart';
import 'package:moffy/features/quests/domain/quest_progress_evaluator.dart';

/// クエスト進捗判定（[QuestProgressEvaluator]）と倍率（[StreakState]）の単体テスト。
///
/// 信頼境界（ARCHITECTURE §2-3）の確認も兼ねる:
///   * 報酬付与（残高反映）はサーバーの責務。ここでは「達成判定」のみを検証し、
///     evaluate が rewardGranted を変えないことも確認する。
void main() {
  Quest def(QuestCondition c, {int progress = 0}) => Quest(
        id: 'q',
        kind: QuestKind.daily,
        title: 't',
        condition: c,
        reward: const QuestReward(points: 10),
        progress: progress,
        isCompleted: false,
        rewardGranted: false,
      );

  group('QuestProgressEvaluator（rule_json 準拠の進捗判定）', () {
    test('reduce_total: 削減分が目標以上で達成', () {
      final q = def(
        const QuestCondition(type: QuestConditionType.reduceTotal, target: 30),
      );
      final r = QuestProgressEvaluator.evaluate(
        q,
        const QuestMetrics(reducedMinutes: 35),
      );
      expect(r.progress, 35);
      expect(r.isCompleted, isTrue);
    });

    test('reduce_total: 削減が目標未満は未達', () {
      final q = def(
        const QuestCondition(type: QuestConditionType.reduceTotal, target: 30),
      );
      final r = QuestProgressEvaluator.evaluate(
        q,
        const QuestMetrics(reducedMinutes: 20),
      );
      expect(r.isCompleted, isFalse);
    });

    test('app_under: 対象アプリが目標分未満なら達成（余裕分を進捗化）', () {
      final q = def(
        const QuestCondition(
          type: QuestConditionType.appUnder,
          target: 20,
          package: 'com.x',
        ),
      );
      // 12分利用 → 余裕8分 → 進捗8。達成は progress>=target=20 を要するため未達。
      final r = QuestProgressEvaluator.evaluate(
        q,
        const QuestMetrics(perAppMinutes: {'com.x': 12}),
      );
      expect(r.progress, 8);
      expect(r.isCompleted, isFalse);
    });

    test('app_under: 全く使わなければ余裕=target で達成', () {
      final q = def(
        const QuestCondition(
          type: QuestConditionType.appUnder,
          target: 20,
          package: 'com.x',
        ),
      );
      final r = QuestProgressEvaluator.evaluate(q, const QuestMetrics());
      expect(r.progress, 20);
      expect(r.isCompleted, isTrue);
    });

    test('app_under: 使いすぎ（超過）は進捗0', () {
      final q = def(
        const QuestCondition(
          type: QuestConditionType.appUnder,
          target: 20,
          package: 'com.x',
        ),
      );
      final r = QuestProgressEvaluator.evaluate(
        q,
        const QuestMetrics(perAppMinutes: {'com.x': 40}),
      );
      expect(r.progress, 0);
      expect(r.isCompleted, isFalse);
    });

    test('streak_keep: 維持で達成 / 未維持は未達', () {
      const c = QuestCondition(type: QuestConditionType.streakKeep, target: 1);
      expect(
        QuestProgressEvaluator.evaluate(
          def(c),
          const QuestMetrics(streakKept: true),
        ).isCompleted,
        isTrue,
      );
      expect(
        QuestProgressEvaluator.evaluate(
          def(c),
          const QuestMetrics(streakKept: false),
        ).isCompleted,
        isFalse,
      );
    });

    test('hatch_count / points_earn: 累積が目標到達で達成', () {
      final hatch = def(
        const QuestCondition(type: QuestConditionType.hatchCount, target: 3),
      );
      expect(
        QuestProgressEvaluator.evaluate(
          hatch,
          const QuestMetrics(hatchCount: 3),
        ).isCompleted,
        isTrue,
      );
      final pts = def(
        const QuestCondition(
          type: QuestConditionType.pointsEarn,
          target: 1000,
        ),
      );
      expect(
        QuestProgressEvaluator.evaluate(
          pts,
          const QuestMetrics(earnedPoints: 640),
        ).isCompleted,
        isFalse,
      );
    });

    test('unknown 条件は安全に未達（誤って受取要求が走らない / 信頼境界）', () {
      final q = def(
        const QuestCondition(type: QuestConditionType.unknown, target: 1),
      );
      final r = QuestProgressEvaluator.evaluate(
        q,
        const QuestMetrics(reducedMinutes: 999),
      );
      expect(r.progress, 0);
      expect(r.isCompleted, isFalse);
    });

    test('target<=0 の不正定義は達成にしない（誤付与防止）', () {
      final q = def(
        const QuestCondition(type: QuestConditionType.reduceTotal, target: 0),
      );
      final r = QuestProgressEvaluator.evaluate(
        q,
        const QuestMetrics(reducedMinutes: 5),
      );
      expect(r.isCompleted, isFalse);
    });

    test('evaluate は rewardGranted を変更しない（受取はサーバー確定）', () {
      const q = Quest(
        id: 'q',
        kind: QuestKind.daily,
        title: 't',
        condition: QuestCondition(
          type: QuestConditionType.reduceTotal,
          target: 10,
        ),
        reward: QuestReward(points: 10),
        progress: 0,
        isCompleted: false,
        rewardGranted: true, // 既に受取済み
      );
      final r = QuestProgressEvaluator.evaluate(
        q,
        const QuestMetrics(reducedMinutes: 50),
      );
      expect(r.rewardGranted, isTrue); // 変更されない
    });
  });

  group('StreakState 倍率（S14 / 間の日数は直下段）', () {
    const tiers = StreakTier.defaults; // 1→1.0 / 3→1.2 / 7→1.5 / 30→2.0

    StreakState s(int current) =>
        StreakState(current: current, longest: 30, tiers: tiers);

    test('1日=×1.0', () => expect(s(1).multiplier, 1.0));
    test('3日=×1.2', () => expect(s(3).multiplier, 1.2));
    test('5日=×1.2（間は直下段）', () => expect(s(5).multiplier, 1.2));
    test('7日=×1.5', () => expect(s(7).multiplier, 1.5));
    test('10日=×1.5（間は直下段）', () => expect(s(10).multiplier, 1.5));
    test('30日=×2.0', () => expect(s(30).multiplier, 2.0));
    test('100日=×2.0（最高段維持）', () => expect(s(100).multiplier, 2.0));
    test('0日=×1.0（最低段）', () => expect(s(0).multiplier, 1.0));

    test('次マイルストーンと残り日数（5日→次は7日まであと2日）', () {
      final st = s(5);
      expect(st.nextTier?.days, 7);
      expect(st.daysToNextTier, 2);
    });

    test('最高段では次マイルストーンなし', () {
      final st = s(30);
      expect(st.nextTier, isNull);
      expect(st.daysToNextTier, isNull);
    });
  });

  group('QuestsState 集計', () {
    Quest claimable() => const Quest(
          id: 'a',
          kind: QuestKind.daily,
          title: 't',
          condition: QuestCondition(
            type: QuestConditionType.reduceTotal,
            target: 1,
          ),
          reward: QuestReward(points: 1),
          progress: 1,
          isCompleted: true,
          rewardGranted: false,
        );

    test('isClaimable は達成済み・未受取', () {
      expect(claimable().isClaimable, isTrue);
      expect(claimable().copyWith(rewardGranted: true).isClaimable, isFalse);
    });

    test('全達成で isAllCompleted / 空で isEmpty', () {
      final all = QuestsState(
        daily: [claimable()],
        weekly: const [],
        streak: const StreakState(
          current: 1,
          longest: 1,
          tiers: StreakTier.defaults,
        ),
        isOffline: false,
      );
      expect(all.isAllCompleted, isTrue);
      expect(all.claimableCount, 1);

      const empty = QuestsState(
        daily: [],
        weekly: [],
        streak: StreakState(
          current: 0,
          longest: 0,
          tiers: StreakTier.defaults,
        ),
        isOffline: false,
      );
      expect(empty.isEmpty, isTrue);
      expect(empty.isAllCompleted, isFalse);
    });
  });
}

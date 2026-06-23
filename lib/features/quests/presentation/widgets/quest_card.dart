import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../domain/quest_models.dart';

/// クエスト1件のカード（SCREEN_FLOWS §5）。進捗バー + 報酬 + 受取CTA。
///
/// 報酬アイコンはSVG相当の Material アイコン（絵文字をアイコン代わりにしない / 禁止事項）。
/// 受取はオフライン時グレーアウト（onClaim=null / S8）。
class QuestCard extends StatelessWidget {
  const QuestCard({
    super.key,
    required this.quest,
    required this.onClaim,
    required this.claiming,
  });

  final Quest quest;

  /// 受取コールバック。null=受取不可（未達 / 受取済み / オフライン）でグレーアウト。
  final VoidCallback? onClaim;

  /// 受取処理中（多重タップ防止のスピナー表示）。
  final bool claiming;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(quest.title, style: AppType.bodyStrong),
                    if (quest.description != null) ...[
                      const SizedBox(height: AppSpace.xs),
                      Text(quest.description!, style: AppType.caption),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              _RewardBadges(reward: quest.reward),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          // 進捗バー（達成は緑、進行中は orange）。
          GrowthProgressBar(
            value: quest.progressRatio,
            fillColor:
                quest.isCompleted ? AppColors.success : AppColors.primary,
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              Text(
                _progressLabel(quest),
                style: AppType.caption,
              ),
              const Spacer(),
              _ClaimButton(
                quest: quest,
                onClaim: onClaim,
                claiming: claiming,
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _progressLabel(Quest q) {
    final unit = switch (q.condition.type) {
      QuestConditionType.appUnder ||
      QuestConditionType.reduceTotal =>
        '分',
      QuestConditionType.hatchCount => '個',
      QuestConditionType.pointsEarn => 'pt',
      QuestConditionType.streakKeep ||
      QuestConditionType.unknown =>
        '',
    };
    if (q.condition.type == QuestConditionType.streakKeep) {
      return q.isCompleted ? '達成' : '今日まだ';
    }
    return '${q.progress} / ${q.condition.target}$unit';
  }
}

/// 受取CTA。状態に応じて「受け取る」/「受取済み」/グレーアウトを出し分ける。
class _ClaimButton extends StatelessWidget {
  const _ClaimButton({
    required this.quest,
    required this.onClaim,
    required this.claiming,
  });

  final Quest quest;
  final VoidCallback? onClaim;
  final bool claiming;

  @override
  Widget build(BuildContext context) {
    if (quest.rewardGranted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: AppColors.success,
          ),
          const SizedBox(width: AppSpace.xs),
          Text(
            '受取済み',
            style: AppType.caption.copyWith(color: AppColors.success),
          ),
        ],
      );
    }
    if (!quest.isCompleted) {
      // 未達は CTA を出さない（進行中の表示のみ）。
      return const SizedBox.shrink();
    }
    if (claiming) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppColors.primary,
        ),
      );
    }
    // 達成・未受取: 受取ボタン。onClaim=null（オフライン）でグレーアウト。
    return ElevatedButton(
      onPressed: onClaim,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.sm,
        ),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('受け取る'),
    );
  }
}

/// 報酬バッジ群（pt / ジェム / 卵）。固定報酬（倍率非適用 / S14）。
class _RewardBadges extends StatelessWidget {
  const _RewardBadges({required this.reward});

  final QuestReward reward;

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[];
    if (reward.points > 0) {
      badges.add(
        StatBadge(
          icon: Icons.star_rounded,
          value: reward.points,
        ),
      );
    }
    if (reward.gems > 0) {
      badges.add(
        StatBadge(
          icon: Icons.diamond_rounded,
          value: reward.gems,
          color: AppColors.successSoft,
          iconColor: AppColors.successDeep,
        ),
      );
    }
    if (reward.eggRarity != null) {
      badges.add(
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.xs,
          ),
          decoration: const BoxDecoration(
            color: AppColors.surfaceNest,
            borderRadius: AppRadius.pillR,
          ),
          child: const Icon(
            Icons.egg_rounded,
            size: 16,
            color: AppColors.nestBark,
          ),
        ),
      );
    }
    if (badges.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: AppSpace.xs,
      runSpacing: AppSpace.xs,
      alignment: WrapAlignment.end,
      children: badges,
    );
  }
}

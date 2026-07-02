import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/egg_art.dart';
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
    // 「app_under（○分まで）」型は意味が逆（使うほど悪い）なので、バーは
    // 「残り allowance（使うほど減る）」を表す。達成は満タン、上限超過は赤。
    final isUnderType = quest.condition.type == QuestConditionType.appUnder;
    final overLimit = isUnderType && quest.progress > quest.condition.target;
    final barValue = quest.isCompleted
        ? 1.0
        : isUnderType
            ? (1 - quest.progressRatio).clamp(0.0, 1.0)
            : quest.progressRatio;
    final barColor = quest.isCompleted
        ? AppColors.success
        : overLimit
            ? AppColors.error
            : (isUnderType && quest.progressRatio > 0.8)
                ? AppColors.warn
                : AppColors.primary;
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
          // 進捗バー（達成=緑満タン / 上限超過=赤 / 「〜まで」型=残り allowance）。
          GrowthProgressBar(value: barValue, fillColor: barColor),
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
      QuestConditionType.appUnder || QuestConditionType.reduceTotal => '分',
      QuestConditionType.hatchCount => '個',
      QuestConditionType.pointsEarn => 'pt',
      QuestConditionType.streakKeep || QuestConditionType.unknown => '',
    };
    if (q.condition.type == QuestConditionType.streakKeep) {
      return q.isCompleted ? '達成' : '今日まだ';
    }
    // 「○分まで」型は「残り／上限」で表す（使った量の分子表示だと意味が逆に読める）。
    if (q.condition.type == QuestConditionType.appUnder) {
      final target = q.condition.target;
      final remaining = target - q.progress;
      if (q.isCompleted) return '上限内で達成';
      return remaining >= 0
          ? 'あと$remaining分（上限$target分）'
          : '上限を${-remaining}分オーバー';
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
    // コアループ最重要操作なので、指で押しやすいよう 48dp 相当のタップ領域を確保する
    // （shrinkWrap+Size.zero でのタップ潰しをやめる）。
    return ElevatedButton(
      onPressed: onClaim,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.md,
        ),
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
          icon: Icons.bolt_rounded,
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
          // 卵は本番イラスト（[EggArt]）で、レアリティ色も反映する（アイコン化・レア色破棄をやめる）。
          child: SizedBox(
            width: 22,
            height: 22,
            child: EggArt(rarity: _eggRarityToken(reward.eggRarity!)),
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

/// 報酬の卵レアリティ文字列（'normal'/'rare'/'epic'/'legend' 等）→ 色帯トークン。
/// active_egg_panel の対応と揃える（epic≈SR / legend≈SSR の表示近似）。
RarityToken _eggRarityToken(String label) => switch (label) {
      'rare' => RarityToken.rare,
      'epic' || 'sr' => RarityToken.sr,
      'legend' || 'ssr' => RarityToken.ssr,
      _ => RarityToken.common,
    };

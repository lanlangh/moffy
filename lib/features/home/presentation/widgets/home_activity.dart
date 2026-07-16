import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/ads/ads.dart';
import '../../../../core/iap/iap_providers.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../collection/data/collection_repository.dart';
import '../../../quests/domain/quest_models.dart';
import '../../../quests/presentation/quests_controller.dart';

/// ホームの「今日のクエスト」カード（ストリーク＋デイリー上位2件）。
///
/// クエスト provider を自前で watch し、未取得/空のときは何も出さない
/// （ホームを埋めすぎない・落とさない）。進捗の“方向”はクエストtabの本表示に任せ、
/// ここは達成状態のチェックリストに留める（app_under の逆向きバー等を避ける）。
class HomeQuestsCard extends ConsumerWidget {
  const HomeQuestsCard({super.key, required this.onSeeAll});

  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(questsControllerProvider).valueOrNull;
    if (q == null || q.isEmpty) return const SizedBox.shrink();
    final show = q.daily.take(2).toList(growable: false);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('今日のクエスト', style: AppType.bodyStrong),
              const Spacer(),
              if (q.streak.current > 0) _StreakBadge(streak: q.streak),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          for (final quest in show) _QuestRow(quest: quest),
          InkWell(
            onTap: onSeeAll,
            borderRadius: AppRadius.smR,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'すべて見る',
                    style: AppType.caption.copyWith(color: AppColors.primary),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: AppColors.primary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ストリーク（連続日数）の小さなピル。絵文字は使わず炎アイコン＋日数（数字はBaloo）。
class _StreakBadge extends StatelessWidget {
  const _StreakBadge({required this.streak});
  final StreakState streak;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.primarySoft.withValues(alpha: 0.5),
        borderRadius: AppRadius.pillR,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.local_fire_department_rounded,
            size: 15,
            color: AppColors.primaryDeep,
          ),
          const SizedBox(width: AppSpace.xs),
          Text(
            '${streak.current}日',
            style: AppType.numLabel.copyWith(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// クエスト1件のチェックリスト行（アイコン＋タイトル＋状態）。
class _QuestRow extends StatelessWidget {
  const _QuestRow({required this.quest});
  final Quest quest;

  @override
  Widget build(BuildContext context) {
    final completed = quest.isCompleted;
    final label = quest.isClaimable
        ? '受け取れる！'
        : completed
            ? '達成'
            : '進行中';
    final labelColor = (quest.isClaimable || completed)
        ? AppColors.successDeep
        : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          Icon(
            completed
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 16,
            color: completed ? AppColors.success : AppColors.textDisabled,
          ),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              quest.title,
              style: AppType.caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          Text(
            label,
            style: AppType.caption.copyWith(
              color: labelColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// ホームの「コレクション」カード（図鑑達成率のクイック表示 / 収集動機）。
class HomeCollectionCard extends ConsumerWidget {
  const HomeCollectionCard({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ref.watch(collectionStateProvider).valueOrNull;
    if (c == null) return const SizedBox.shrink();
    return AppCard(
      child: InkWell(
        onTap: onOpen,
        borderRadius: AppRadius.lgR,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('コレクション', style: AppType.bodyStrong),
                const Spacer(),
                Text('${c.discoveredCount}', style: AppType.numLabel),
                Text(' / ${c.totalEntries}', style: AppType.caption),
                const SizedBox(width: AppSpace.xs),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
            const SizedBox(height: AppSpace.sm),
            GrowthProgressBar(
              value: c.completionRatio,
              fillColor: AppColors.success,
            ),
          ],
        ),
      ),
    );
  }
}

/// ホームのプレミアム導線カード（非プレミアムのみ・非naggy / 磨き込み②）。
///
/// 訴求は **v1.0 で実提供している特典だけ**（広告オフ・保管枠アップ）。プレミアム卵/限定Mofi
/// は未実装のため謳わない（PremiumEntitlements のコメント / 景表法・3.1.2 回避）。
/// 加入者には出さない（isPremium で丸ごと畳む＝課金済みを煩わせない）。表示は自己完結の
/// 下余白を持ち、非表示時は上の間隔だけ残る（二重の空きを作らない）。
class HomePremiumCard extends ConsumerWidget {
  const HomePremiumCard({super.key, required this.onOpen});

  /// タップ時の遷移（ホームが `PaywallScreen.pathWithSource(PaywallSource.home)` を渡す）。
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 加入者には一切出さない（アップセルは無料ユーザーだけ）。
    if (ref.watch(isPremiumProvider)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.lg),
      child: AppCard(
        child: InkWell(
          onTap: onOpen,
          borderRadius: AppRadius.lgR,
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: AppColors.primarySoft,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.workspace_premium_rounded,
                  color: AppColors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Moffyプレミアム', style: AppType.bodyStrong),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      // 実際に広告が出る Android/iOS は「広告オフ」訴求、出ない Web は
                      // 実態に合わせて保管枠中心の訴求にする（優良誤認・3.1.2 回避）。
                      freeTierAdsActive
                          ? '広告オフで、たっぷり集める。'
                          : '保管枠アップで、たっぷり集める。',
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

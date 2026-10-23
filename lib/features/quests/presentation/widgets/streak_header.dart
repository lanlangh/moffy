import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../domain/quest_models.dart';

/// ストリークヘッダ（SCREEN_FLOWS §5）。連続日数（＋倍率が有効なら現在倍率と次マイルストーン）。
///
/// 数字は必ず Baloo 2（[AppType.numHero]/[AppType.numLabel] / DESIGN_SYSTEM §3）。
///
/// 0018 で倍率は廃止された（`streak_multipliers` は全段 ×1.0）。[StreakState.hasMultipliers]
/// が false のときは倍率バッジと「あと N 日で ×1.5」を出さず、連続日数の意味
/// （◎か○の日がつづくと伸びる）だけを添える。倍率のある設定に戻したときは従来の表示に戻る。
class StreakHeader extends StatelessWidget {
  const StreakHeader({super.key, required this.streak});

  final StreakState streak;

  @override
  Widget build(BuildContext context) {
    final hasMultipliers = streak.hasMultipliers;
    final next = streak.nextTier;
    final toNext = streak.daysToNextTier;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: const BoxDecoration(
        color: AppColors.surfaceNest,
        borderRadius: AppRadius.lgR,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 連続日数（主役数字 / Baloo）。
              Text('${streak.current}', style: AppType.numHero),
              const SizedBox(width: AppSpace.xs),
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Text('日連続', style: AppType.body),
              ),
              const Spacer(),
              if (hasMultipliers)
                // 現在倍率バッジ（×1.0〜×2.0）。
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.xs,
                  ),
                  decoration: const BoxDecoration(
                    color: AppColors.primarySoft,
                    borderRadius: AppRadius.pillR,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.local_fire_department_rounded,
                        size: 18,
                        color: AppColors.primary,
                      ),
                      const SizedBox(width: AppSpace.xs),
                      // 「今日達成したときに掛かる倍率」を出す（サーバー fn_finalize_day の
                      // streak_multiplier(current + 1) と同じ基準）。streak.multiplier は
                      // 昨日までの実績に対する値で、実際の付与より低く表示されていた。
                      Text(
                        '×${streak.todayMultiplier.toStringAsFixed(1)}',
                        style: AppType.numLabel,
                      ),
                    ],
                  ),
                )
              else
                const Icon(
                  Icons.local_fire_department_rounded,
                  size: 22,
                  color: AppColors.primary,
                ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (hasMultipliers) ...[
            // 次マイルストーンまで（最高段なら最大表示）。
            // 今日を1日目として数えた残り日数（nextTier は「倍率が実際に上がる段」だけを返す）。
            if (next != null && toNext != null)
              Text(
                '今日から$toNext日続けると ×${next.mult.toStringAsFixed(1)}',
                style: AppType.caption,
              )
            else
              Text('最大倍率に到達中', style: AppType.caption),
            const SizedBox(height: AppSpace.xs),
            // S14: 倍率は基礎ポイントにのみ適用（クエスト報酬・ジェム・卵には掛けない）。
            Text(
              '倍率は毎日の削減で得る基礎ポイントにだけかかります。',
              style: AppType.caption.copyWith(color: AppColors.textSecondary),
            ),
          ] else
            // 0018: 倍率なし。連続日数の意味だけ添える（◎/○ で +1、△ で 0、計れなかった日は据え置き）。
            Text(
              '◎か○の日がつづくと伸びます。△の日で0に戻り、計れなかった日はそのまま。',
              style: AppType.caption.copyWith(color: AppColors.textSecondary),
            ),
        ],
      ),
    );
  }
}

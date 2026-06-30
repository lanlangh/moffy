import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/egg_art.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/home_state.dart';

/// ウォームアップ付与の祝福カード（F-01 ハッピーパス / S1「初日体験」）。
///
/// 付与成功時のみホーム上部に出す。「初回ボーナス卵に Day1=200 / Day2=300pt が積まれた」
/// 体験を主役化し、コアループ（卵が育つ→孵化）の快感を最短で予感させる。
///
/// 署名要素 [NestRing] を土台に使い、数字は Baloo 2（[AppType.numHero]）。
/// 絵文字をアイコン代わりにしない（Material アイコンを使う / 組織ルール）。
class WarmupCelebration extends StatelessWidget {
  const WarmupCelebration({super.key, required this.grant});

  final WarmupGrantSummary grant;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      // アクセシビリティ: スクリーンリーダーに付与内容を1文で伝える。
      label: 'ボーナス ${grant.grantedPoints} ポイントを獲得し、卵にためました',
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: const BoxDecoration(
          // 達成の暖色面（grow.leaf）。責めない・祝う色（DESIGN_SYSTEM §2-2）。
          color: AppColors.successSoft,
          borderRadius: AppRadius.lgR,
          boxShadow: AppElevation.card,
        ),
        child: Column(
          children: [
            const NestRing(
              diameter: 120,
              glow: AppColors.primary,
              child: EggArt(rarity: RarityToken.common),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              'はじまりのボーナス',
              style: AppType.title,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpace.xs),
            // 主役数字は Baloo 2（numHero）。pt 単位は小さく添える。
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '+${grant.grantedPoints}',
                  style: AppType.numHero.copyWith(color: AppColors.successDeep),
                ),
                const SizedBox(width: AppSpace.xs),
                Text(
                  'pt',
                  style: AppType.numLabel.copyWith(color: AppColors.successDeep),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              '最初のボーナス卵にためました。'
              'このまま育てて、はじめてのMofiに会いに行こう。',
              style: AppType.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/egg_art.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/home_state.dart';

/// ウォームアップ付与の祝福カード（F-01 ハッピーパス / S1「初日体験」）。
///
/// 付与成功時のみホーム上部に出す。0018: 1日目は 300pt（白いたまごが もよう→ヒビ→光 まで
/// 一気に育つ＝育ち方の予告編）、2日目は「孵化までの残り全部」（戻ってきた瞬間に孵化できる）。
/// 卵そのものの変化は主役パネルの段階アップ演出が見せるので、ここは数字と一言だけ。
///
/// 署名要素 [NestRing] を土台に使い、数字は Baloo 2（[AppType.numHero]）。
/// 絵文字をアイコン代わりにしない（Material アイコンを使う / 組織ルール）。
class WarmupCelebration extends StatelessWidget {
  const WarmupCelebration({super.key, required this.grant});

  final WarmupGrantSummary grant;

  @override
  Widget build(BuildContext context) {
    final body = grant.day == 1
        ? '最初のボーナス卵にためました。'
            '白い卵に模様が浮かび、ヒビが入り、光が漏れるところまで一気に育ちます。'
        : '戻ってきてくれてありがとう。孵化までの残りを全部入れました。'
            '卵をタップして、初めてのMofiに会いに行こう。';
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
            NestRing(
              diameter: 120,
              glow: AppColors.primary,
              child: EggArt(
                rarity: RarityToken.common,
                look: grant.day == 1 ? EggLook.blank : EggLook.ready,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              grant.day == 1 ? 'はじまりのボーナス' : 'おかえりのボーナス',
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
            Text(body, style: AppType.caption, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/egg_art.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/home_state.dart';

/// ホーム主役の巣パネル（SCREEN_FLOWS §2-2,3）。
/// アクティブ卵があれば孵化進捗を、無ければ空枠誘導を表示（§5-2 空状態）。
class ActiveEggPanel extends StatelessWidget {
  const ActiveEggPanel({
    super.key,
    required this.state,
    required this.onSetEgg,
  });

  final HomeState state;
  final VoidCallback onSetEgg;

  @override
  Widget build(BuildContext context) {
    final egg = state.activeEgg;

    // 空状態: アクティブ卵なし → 空の巣 + 「卵をセットしよう」（§5-2）。
    if (egg == null) {
      return NestPanel(
        diameter: 160,
        subject: const Opacity(
          opacity: 0.5,
          child: EggArt(rarity: RarityToken.common),
        ),
        caption: Text('巣が空いています', style: AppType.title),
        footer: Column(
          children: [
            Text(
              state.pooledPoints > 0
                  ? '${state.pooledPoints}pt ためてあります。'
                      '卵をセットすると、このポイントで育ち始めます。'
                  : 'つぎに育てる卵を選んで、巣にセットしましょう。',
              style: AppType.caption,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpace.md),
            PrimaryButton(label: '卵をセットする', onPressed: onSetEgg),
          ],
        ),
      );
    }

    // ハッピー: 孵化進捗。孵化間近なら巣リング微発光（SCREEN_FLOWS §2）。
    final rarity = _rarityToken(egg.rarityLabel);
    return NestPanel(
      diameter: 180,
      glow: egg.isNearHatch ? rarity.glow : null,
      caption: Text(
        egg.remaining > 0 ? '孵化まであと ${egg.remaining}pt' : 'まもなく孵化',
        style: AppType.title,
      ),
      subject: EggArt(rarity: rarity, progress: egg.progress),
      footer: Column(
        children: [
          GrowthProgressBar(value: egg.progress),
          const SizedBox(height: AppSpace.sm),
          Text(
            '${(egg.progress * 100).round()}%',
            style: AppType.numLabel,
          ),
        ],
      ),
    );
  }

  RarityToken _rarityToken(String label) => switch (label) {
        'rare' => RarityToken.rare,
        'epic' => RarityToken.sr, // epic卵 ≈ SR色帯（表示上の近似）
        'legend' => RarityToken.ssr,
        _ => RarityToken.common,
      };
}

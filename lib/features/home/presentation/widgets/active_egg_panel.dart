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
    this.onHatch,
  });

  final HomeState state;
  final VoidCallback onSetEgg;

  /// 孵化できる状態のときに出すボタンの行き先（たまご画面）。null ならボタンを出さない。
  final VoidCallback? onHatch;

  @override
  Widget build(BuildContext context) {
    final egg = state.activeEgg;

    // 空状態: アクティブ卵なし → 空の巣 + 「卵をセットしよう」（§5-2）。
    if (egg == null) {
      return NestPanel(
        diameter: 160,
        subject: const EmptyNestEgg(),
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
    // 【2026-10-05 追加】孵化できる状態（残り0pt）なら、ここから孵化へ送る。
    //   以前は「まもなく孵化」と出すだけで**ボタンが無く**、孵化するには
    //   たまごタブ → 卵をタップ → シート → 孵化 の4ステップ必要だった。
    //   実測（2026-10-05）: 500pt を超えた卵が2個、数週間〜数か月放置されていた。
    final canHatch = egg.remaining == 0;
    return NestPanel(
      diameter: 180,
      glow: canHatch || egg.isNearHatch ? rarity.glow : null,
      caption: Text(
        canHatch ? '孵化できます！' : '孵化まであと ${egg.remaining}pt',
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
          if (canHatch && onHatch != null) ...[
            const SizedBox(height: AppSpace.md),
            PrimaryButton(label: '孵化する', onPressed: onHatch),
          ],
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

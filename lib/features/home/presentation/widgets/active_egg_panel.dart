import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/egg_art.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/home_state.dart';
import 'egg_stage_reveal.dart';

/// ホーム主役の巣パネル（SCREEN_FLOWS §2-2,3）。
/// アクティブ卵があれば 5段階の見た目＋段階アップ演出（[EggStageReveal]）を、
/// 無ければ空枠誘導を表示（§5-2 空状態）。
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

    // ハッピー: 5段階の見た目。段階が進んでいれば「変わった！」の演出を出す（0018 §4-3）。
    // 孵化できる状態（残り0pt）なら演出の最後に「孵化する」ボタン。以前は
    // 「まもなく孵化」と出すだけで**ボタンが無く**、たまごタブ → 卵をタップ → シート → 孵化 の
    // 4ステップ必要だった（実測 2026-10-05: 500pt を超えた卵が2個、数週間〜数か月放置）。
    return EggStageReveal(egg: egg, onHatch: onHatch);
  }
}

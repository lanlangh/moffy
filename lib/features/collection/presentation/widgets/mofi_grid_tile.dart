import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../../eggs/presentation/egg_visuals.dart';
import '../../domain/mofi_models.dart';

/// 図鑑グリッドのサムネ（巣リング上の円形 / 署名要素の反復 / SCREEN_FLOWS §4）。
///   * 発見済み: カラー + 名前。色違いは虹枠。
///   * 未発見: シルエット（巣だけ残す）+ 「？？？」。
class MofiGridTile extends StatelessWidget {
  const MofiGridTile({
    super.key,
    required this.entry,
    required this.stage2Count,
    this.forceBabyStage = false,
    required this.onTap,
  });

  final MofiDexEntry entry;

  /// 進化アダルト化の重複しきい値（CollectionState由来 / docs/EVOLUTION.md）。
  final int stage2Count;

  /// true のとき、進化済みでも**こどもの姿**で描く（図鑑の切替）。
  /// 進化すると前の姿が一覧から消えてしまうのを補う。
  final bool forceBabyStage;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final discovered = entry.discovered;
    // 🔴 絵と名前は**必ず同じ段階**にする。以前は絵だけ段階に追従し、
    // 名前は進化前のままだった（進化後の姿に進化前の名前が付いていた）。
    // 段階を1箇所で決めて両方に配ることで、二度と食い違わないようにする。
    final shownStage = forceBabyStage ? 1 : entry.evolutionStage(stage2Count);
    final shownName = entry.species.nameForStage(shownStage);
    final ring = NestRing(
      diameter: 72,
      // 色違いは巣リングの外周を虹色リムに（リングと同心＝中心がずれない / SCREEN_FLOWS §4）。
      rimGradient: (discovered && entry.isShiny)
          ? SweepGradient(
              colors: [
                AppColors.error,
                AppColors.warn,
                AppColors.success,
                RarityToken.rare.main,
                RarityToken.sr.main,
                AppColors.error,
              ],
            )
          : null,
      child: MofiSubject(
        speciesId: entry.species.id,
        family: entry.species.family,
        rarity: entry.species.rarity,
        stage: shownStage,
        silhouette: !discovered,
        isShiny: entry.isShiny,
      ),
    );

    return Semantics(
      button: true,
      label: discovered
          ? (entry.isShiny ? '$shownName・色違い' : shownName)
          : '未発見',
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ring,
            const SizedBox(height: AppSpace.xs),
            Text(
              discovered ? shownName : '？？？',
              style: AppType.caption.copyWith(
                color:
                    discovered ? AppColors.textPrimary : AppColors.textDisabled,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

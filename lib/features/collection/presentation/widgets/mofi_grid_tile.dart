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
    required this.onTap,
  });

  final MofiDexEntry entry;

  /// 進化アダルト化の重複しきい値（CollectionState由来 / docs/EVOLUTION.md）。
  final int stage2Count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final discovered = entry.discovered;
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
        stage: entry.evolutionStage(stage2Count),
        silhouette: !discovered,
        isShiny: entry.isShiny,
      ),
    );

    return Semantics(
      button: true,
      label: discovered
          ? (entry.isShiny ? '${entry.species.name}・色違い' : entry.species.name)
          : '未発見',
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ring,
            const SizedBox(height: AppSpace.xs),
            Text(
              discovered ? entry.species.name : '？？？',
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

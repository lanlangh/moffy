import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../../eggs/presentation/egg_visuals.dart';
import '../../domain/mofi_models.dart';

/// 図鑑グリッドのサムネ（巣リング上の円形 / 署名要素の反復 / SCREEN_FLOWS §4）。
///   * 発見済み: カラー + 名前。色違いは虹枠。
///   * 未発見: シルエット（巣だけ残す）+ 「？？？」。
class MofiGridTile extends StatelessWidget {
  const MofiGridTile({super.key, required this.entry, required this.onTap});

  final MofiDexEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final discovered = entry.discovered;
    final ring = NestRing(
      diameter: 72,
      child: MofiSubject(
        family: entry.species.family,
        rarity: entry.species.rarity,
        silhouette: !discovered,
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
            // 色違いは虹枠（発見済みのみ / SCREEN_FLOWS §4）。色は RarityToken/AppColors（SSOT）。
            if (discovered && entry.isShiny)
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(
                    colors: [
                      AppColors.error,
                      AppColors.warn,
                      AppColors.success,
                      RarityToken.rare.main,
                      RarityToken.sr.main,
                      AppColors.error,
                    ],
                  ),
                ),
                child: ring,
              )
            else
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

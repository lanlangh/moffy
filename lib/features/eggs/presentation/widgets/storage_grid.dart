import 'package:flutter/material.dart';

import '../../../../core/constants/economy.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/egg_models.dart';
import '../egg_visuals.dart';

/// 保管枠（無制限）グリッド（SCREEN_FLOWS §3）。
/// 各卵にレアリティ RarityChip 相当の色と成長ptを表示。空なら空状態文言。
class StorageGrid extends StatelessWidget {
  const StorageGrid({super.key, required this.state, required this.onSelect});

  final EggsState state;
  final ValueChanged<Egg> onSelect;

  @override
  Widget build(BuildContext context) {
    if (state.storage.isEmpty) {
      // 保管庫が空（育成中はある）→ 素っ気なくしない短い誘導。
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: const BoxDecoration(
          color: AppColors.sectionFill,
          borderRadius: AppRadius.lgR,
        ),
        child: Text(
          '保管庫は空っぽ。クエストやポイントで卵を増やそう。',
          style: AppType.caption,
          textAlign: TextAlign.center,
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: AppSpace.md,
        crossAxisSpacing: AppSpace.md,
        childAspectRatio: 0.82,
      ),
      itemCount: state.storage.length,
      itemBuilder: (context, i) {
        final egg = state.storage[i];
        return _StorageEggTile(
          egg: egg,
          params: state.params,
          onTap: () => onSelect(egg),
        );
      },
    );
  }
}

class _StorageEggTile extends StatelessWidget {
  const _StorageEggTile({
    required this.egg,
    required this.params,
    required this.onTap,
  });

  final Egg egg;
  final EconomyParams params;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final rarity = RarityVisuals.ofEgg(egg.rarity);
    return Semantics(
      button: true,
      label: '${egg.rarity.label}のたまご ${egg.growthPoints}ポイント',
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NestRing(
              diameter: 64,
              child: EggSubject(rarity: egg.rarity, stage: egg.stage(params)),
            ),
            const SizedBox(height: AppSpace.xs),
            // レアリティチップ（色は §2-3 厳密統一）。
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: rarity.glow,
                borderRadius: AppRadius.pillR,
              ),
              child: Text(
                egg.rarity.label,
                style: AppType.caption.copyWith(color: AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: 2),
            Text('${egg.growthPoints}pt', style: AppType.numLabel),
          ],
        ),
      ),
    );
  }
}

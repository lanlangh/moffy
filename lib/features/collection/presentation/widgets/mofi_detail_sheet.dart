import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../../eggs/presentation/egg_visuals.dart';
import '../../domain/mofi_models.dart';

/// Mofi詳細シート（SCREEN_FLOWS §4 / 要件: 名前・レア・種族・発見日時・色違い有無）。
/// 未発見は項目を伏せ、「卵を育てて見つけよう」を案内する。
class MofiDetailSheet extends StatelessWidget {
  const MofiDetailSheet({super.key, required this.entry});

  final MofiDexEntry entry;

  @override
  Widget build(BuildContext context) {
    final discovered = entry.discovered;
    final rarity = RarityVisuals.ofMofi(entry.species.rarity);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      padding: const EdgeInsets.all(AppSpace.xl),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetGrip(),
            const SizedBox(height: AppSpace.lg),
            NestRing(
              diameter: 160,
              glow: discovered ? rarity.main : null,
              child: MofiSubject(
                family: entry.species.family,
                rarity: entry.species.rarity,
                silhouette: !discovered,
              ),
            ),
            const SizedBox(height: AppSpace.xl),
            Text(
              discovered ? entry.species.name : '？？？',
              style: AppType.display,
            ),
            if (discovered && entry.isShiny) ...[
              const SizedBox(height: AppSpace.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 16,
                    color: AppColors.warn,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Text(
                    '色違い',
                    style: AppType.bodyStrong.copyWith(color: AppColors.warn),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.xl),

            if (discovered) ...[
              _DetailRow(label: 'レアリティ', value: entry.species.rarity.label),
              _DetailRow(label: '種族', value: entry.species.family.label),
              _DetailRow(
                label: '色違い',
                value: entry.isShiny ? 'あり' : '通常色',
              ),
              _DetailRow(
                label: '発見日時',
                value: _formatDate(entry.discoveredAt),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                child: Text(
                  '${entry.species.rarity.label}のMofi。卵を育てて孵化させると見つかります。',
                  style: AppType.body,
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: AppSpace.lg),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime? d) {
    if (d == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// ボトムシート上端のつまみ（共通の見た目）。
class _SheetGrip extends StatelessWidget {
  const _SheetGrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 4,
      decoration: const BoxDecoration(
        color: AppColors.divider,
        borderRadius: AppRadius.pillR,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: [
          Text(label, style: AppType.caption),
          const Spacer(),
          Text(value, style: AppType.bodyStrong),
        ],
      ),
    );
  }
}

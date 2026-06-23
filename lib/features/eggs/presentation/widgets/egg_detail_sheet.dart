import 'package:flutter/material.dart';

import '../../../../core/constants/economy.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/egg_models.dart';
import '../egg_visuals.dart';

/// 卵詳細シート（SCREEN_FLOWS §3）。
/// 成長進捗（0/100/250/500pt のヒビ段階）+ アクティブ切替 + 枠入替 + 孵化CTA。
class EggDetailSheet extends StatelessWidget {
  const EggDetailSheet({
    super.key,
    required this.egg,
    required this.state,
    required this.onSetActive,
    required this.onMoveToStorage,
    required this.onMoveToIncubator,
    required this.onHatch,
  });

  final Egg egg;
  final EggsState state;
  final VoidCallback onSetActive;
  final VoidCallback onMoveToStorage;
  final ValueChanged<int> onMoveToIncubator;
  final VoidCallback onHatch;

  @override
  Widget build(BuildContext context) {
    final params = state.params;
    final stage = egg.stage(params);
    final rarity = RarityVisuals.ofEgg(egg.rarity);
    final inIncubator = egg.location == EggLocation.incubating;
    final canHatch = egg.canHatch(params);

    // 空いている育成枠（保管→育成の入替先）。
    final emptySlots = <int>[
      for (var i = 0; i < state.incubatorSlots.length; i++)
        if (state.incubatorSlots[i] == null) i + 1,
    ];

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
            // つまみ
            const _SheetGrip(),
            const SizedBox(height: AppSpace.lg),
            NestPanel(
              diameter: 160,
              glow: egg.isNearHatch(params) ? rarity.glow : null,
              subject: EggSubject(rarity: egg.rarity, stage: stage),
              caption: Text('${egg.rarity.label}のたまご', style: AppType.title),
              footer: Column(
                children: [
                  GrowthProgressBar(value: egg.progress(params)),
                  const SizedBox(height: AppSpace.sm),
                  Text(
                    '${egg.growthPoints} / ${params.eggThresholds.hatch}pt',
                    style: AppType.numLabel,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xl),

            // ヒビ段階ラダー（0/100/250/500）。
            _StageLadder(egg: egg, params: params),
            const SizedBox(height: AppSpace.xl),

            // アクション群。
            if (canHatch)
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: '孵化させる',
                  icon: Icons.auto_awesome_rounded,
                  // オフライン: 孵化確定不可（グレーアウト / S8）。
                  onPressed: state.isOffline ? null : onHatch,
                ),
              )
            else if (inIncubator && !egg.isActive)
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(label: 'この卵を育てる', onPressed: onSetActive),
              ),

            if (state.isOffline && canHatch) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                '孵化準備完了・接続したら確定します',
                style: AppType.caption.copyWith(color: AppColors.offline),
                textAlign: TextAlign.center,
              ),
            ],

            const SizedBox(height: AppSpace.sm),

            // 枠移動（育成中→保管 / 保管→育成）。
            if (inIncubator)
              _SecondaryAction(
                label: '保管庫に戻す',
                onTap: onMoveToStorage,
              )
            else if (emptySlots.isNotEmpty)
              _SecondaryAction(
                label: '育成枠にセット（枠${emptySlots.first}）',
                onTap: () => onMoveToIncubator(emptySlots.first),
              )
            else
              Text(
                '育成枠が満杯です。どれかを保管庫に戻すとセットできます。',
                style: AppType.caption,
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}

/// 成長段階ラダー: 0/100/250/500pt のしきい値到達を可視化（§4-5）。
/// ボトムシート上端のつまみ。
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

class _StageLadder extends StatelessWidget {
  const _StageLadder({required this.egg, required this.params});
  final Egg egg;
  final EconomyParams params;

  @override
  Widget build(BuildContext context) {
    final t = params.eggThresholds;
    final steps = <(String, int)>[
      ('たまご', 0),
      ('ヒビ①', t.crack1),
      ('ヒビ②', t.crack2),
      ('孵化', t.hatch),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('成長のしるし', style: AppType.bodyStrong),
        const SizedBox(height: AppSpace.md),
        for (final s in steps)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: Row(
              children: [
                Icon(
                  egg.growthPoints >= s.$2
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: egg.growthPoints >= s.$2
                      ? AppColors.success
                      : AppColors.textDisabled,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(child: Text(s.$1, style: AppType.body)),
                Text('${s.$2}pt', style: AppType.numLabel),
              ],
            ),
          ),
      ],
    );
  }
}

class _SecondaryAction extends StatelessWidget {
  const _SecondaryAction({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.primary,
          side: const BorderSide(color: AppColors.primary),
          minimumSize: const Size.fromHeight(52),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.pillR),
        ),
        child: Text(label),
      ),
    );
  }
}

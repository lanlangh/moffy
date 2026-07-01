import 'package:flutter/material.dart';

import '../../../../core/constants/economy.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/egg_models.dart';
import '../egg_visuals.dart';

/// 育成枠3スロット（横並び / SCREEN_FLOWS §3）。
/// アクティブ枠を orange 縁 + 微発光で強調（S6: 加点は1枠のみ）。空きは「空の巣」。
class IncubatorSlots extends StatelessWidget {
  const IncubatorSlots({
    super.key,
    required this.state,
    required this.onSelectSlot,
  });

  final EggsState state;

  /// 卵入りスロットのタップ（詳細を開く）。
  final ValueChanged<Egg> onSelectSlot;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < state.slotCount; i++) ...[
          Expanded(
            child: _Slot(
              egg: state.incubatorSlots[i],
              params: state.params,
              onTap: () {
                final egg = state.incubatorSlots[i];
                if (egg != null) onSelectSlot(egg);
              },
            ),
          ),
          if (i < state.slotCount - 1) const SizedBox(width: AppSpace.md),
        ],
      ],
    );
  }
}

class _Slot extends StatelessWidget {
  const _Slot({required this.egg, required this.params, required this.onTap});

  final Egg? egg;
  final EconomyParams params;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = egg;
    if (e == null) {
      // 空きスロット（保管庫から入れ替え誘導）。
      return Column(
        children: [
          const NestRing(
            diameter: 72,
            dimmed: true,
            child: Icon(Icons.add_rounded, color: AppColors.textDisabled),
          ),
          const SizedBox(height: AppSpace.xs),
          Text('空き', style: AppType.caption),
        ],
      );
    }

    final rarity = RarityVisuals.ofEgg(e.rarity);
    final active = e.isActive;
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          // 育成中は NestRing 自身の縁を orange 化して同心強調（外側に別円を重ねると
          // 地面影ぶん中心がズレるため）。
          NestRing(
            diameter: 72,
            glow: active ? rarity.glow : null,
            borderColor: active ? AppColors.primary : null,
            child: EggSubject(rarity: e.rarity, stage: e.stage(params)),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            active ? '育成中' : 'まちぼうけ',
            style: AppType.caption.copyWith(
              color: active ? AppColors.primary : AppColors.textSecondary,
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

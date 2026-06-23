import 'package:flutter/material.dart';

import '../../../../core/constants/economy.dart';
import '../../../../core/theme/tokens.dart';

/// 対象4アプリ別の時間チップ（SCREEN_FLOWS §2-5）。
/// 各アプリ（TikTok/Instagram/YouTube/X）の利用分を表示。0分も正常表示（§5-1）。
class AppUsageChips extends StatelessWidget {
  const AppUsageChips({super.key, required this.perAppMinutes});

  /// パッケージ名 -> 利用分。
  final Map<String, int> perAppMinutes;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        for (final def in AppConstants.defaultAndroidTargets)
          _Chip(
            label: def.label,
            minutes: perAppMinutes[def.packageName] ?? 0,
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.minutes});

  final String label;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.pillR,
        boxShadow: AppElevation.card,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // SVGアイコンは後続でアセット差し替え。MVPはラベル先頭文字の代替表示。
          CircleAvatar(
            radius: 10,
            backgroundColor: AppColors.surfaceNest,
            child: Text(
              label.characters.first,
              style: AppType.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Text('$label ', style: AppType.caption),
          Text(_format(minutes), style: AppType.numLabel),
        ],
      ),
    );
  }

  String _format(int m) {
    if (m >= 60) return '${m ~/ 60}h${m % 60}m';
    return '${m}m';
  }
}

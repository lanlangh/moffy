import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 通貨/pt表示バッジ（StatBadge / DESIGN_SYSTEM §7）。
/// pill + アイコン + Baloo数字。数字は必ず Baloo 2（[AppType.numLabel]）。
class StatBadge extends StatelessWidget {
  const StatBadge({
    super.key,
    required this.icon,
    required this.value,
    this.color = AppColors.primarySoft,
    this.iconColor = AppColors.primary,
  });

  final IconData icon;
  final int value;
  final Color color;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(color: color, borderRadius: AppRadius.pillR),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: AppSpace.xs),
          Text('$value', style: AppType.numLabel),
        ],
      ),
    );
  }
}

/// 成長/削減プログレスバー（ProgressBar / DESIGN_SYSTEM §7）。
/// 高さ12 / pill / 地 nest.sand / 満は孵化=orange or 削減=green。
class GrowthProgressBar extends StatelessWidget {
  const GrowthProgressBar({
    super.key,
    required this.value, // 0.0〜1.0
    this.fillColor = AppColors.primary,
  });

  final double value;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: AppRadius.pillR,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              Container(height: 12, color: AppColors.surfaceNest),
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOut,
                height: 12,
                width: constraints.maxWidth * clamped,
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: AppRadius.pillR,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 主CTA（PrimaryButton / DESIGN_SYSTEM §7）。pill / 高さ52 / orange。
/// 実体は [ElevatedButtonTheme]（app_theme）に委譲し、ラベルのみ受ける。
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed; // null で無効（オフライン時グレーアウト）
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (icon == null) {
      return ElevatedButton(onPressed: onPressed, child: Text(label));
    }
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label),
    );
  }
}

/// セクション見出し + 子（カード）をまとめる小コンポーネント。
class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(AppSpace.lg),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.lgR,
        boxShadow: AppElevation.card,
      ),
      child: child,
    );
  }
}

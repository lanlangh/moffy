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

/// 孵化までの段階を示す点（0018 / §4-5「孵化までの5つの点 ●●●○○」）。
///
/// [total] 個の点のうち、[reached] 個（いまの段階まで）を塗る。
/// 進捗バーが「段階の中の 0〜100%」になったので、全体の位置はこちらで示す。
class StageDots extends StatelessWidget {
  const StageDots({
    super.key,
    required this.reached,
    required this.total,
    this.color = AppColors.primary,
  });

  /// 塗る点の数（1 = 最初の段階にいる）。
  final int reached;

  /// 点の総数（= 段階の数。既定 5）。
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final n = total < 1 ? 1 : total;
    final r = reached.clamp(0, n);
    return Semantics(
      label: '孵化まで $n 段階のうち $r 段階目',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < n; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs / 2),
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < r ? color : Colors.transparent,
                  border: Border.all(
                    color: i < r ? color : AppColors.textDisabled,
                    width: 1.5,
                  ),
                ),
              ),
            ),
        ],
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

/// 下から出る詳細シートの高さの上限（画面の85%）。
///
/// 中身が画面より高いとシートが全面に広がり、外側をタップして閉じる場所が無くなる。
/// 下へ引く操作も中身のスクロールに取られ、iPhone では閉じられなくなった
/// （2026-10-26 オーナー報告・卵の詳細）。上に必ず閉じられる余白を残す。
BoxConstraints detailSheetConstraints(BuildContext context) =>
    BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85);

/// 詳細シートの「閉じる」ボタン（右上に固定し、中身をスクロールしても隠れない）。
class SheetCloseButton extends StatelessWidget {
  const SheetCloseButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: () => Navigator.of(context).maybePop(),
      tooltip: '閉じる',
      icon: const Icon(Icons.close_rounded),
      color: AppColors.textSecondary,
      style: IconButton.styleFrom(
        backgroundColor: AppColors.surface.withValues(alpha: 0.85),
      ),
    );
  }
}

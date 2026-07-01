import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 署名要素「巣リング」（DESIGN_SYSTEM §1 Step3 / §7）。
///
/// 円形被写体（卵・Mofi・空枠・ローディング）は必ずこの「巣のリング + 地面の楕円影」の
/// 上に乗せる。ホーム主役・たまご・図鑑サムネ・空状態まで全画面で反復し、隠しても
/// Moffyと分かる核にする（DESIGN_SYSTEM §8 最終チェック）。
///
/// [child] は円の中央に置く被写体（卵画像/Mofi/アイコン等）。
/// [glow] を指定するとリング外周がそのレアリティ色で微発光する（孵化間近・SSR等）。
class NestRing extends StatelessWidget {
  const NestRing({
    super.key,
    required this.child,
    this.diameter = 160,
    this.glow,
    this.dimmed = false,
    this.borderColor,
  });

  /// リングの直径（円形被写体の土台サイズ）。
  final double diameter;

  /// 中央に乗せる被写体。
  final Widget child;

  /// 外周の微発光色（null=発光なし）。
  final Color? glow;

  /// オフライン/無効時に彩度を落として表示する（state.offline 表現）。
  final bool dimmed;

  /// 縁取りの色（null=既定の nest.bark）。強調時（育成中の枠など）に orange を渡すと、
  /// リング本体の縁が同心で太く色づく（外側に別の円を重ねてズレるのを避ける）。
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 巣リング本体（nest.sand 地 + nest.bark 2px 縁取り = 署名の輪郭）
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceNest,
              border: Border.all(
                color: borderColor ?? AppColors.nestBark,
                width: borderColor != null ? 3 : 2,
              ),
              boxShadow: glow == null
                  ? null
                  : [
                      BoxShadow(
                        color: glow!.withValues(alpha: 0.55),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ],
            ),
          ),
          // 中央の被写体（円内に収める）
          Padding(
            padding: EdgeInsets.all(diameter * 0.14),
            child: FittedBox(child: child),
          ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dimmed)
          ColorFiltered(
            colorFilter: const ColorFilter.mode(
              AppColors.offline,
              BlendMode.saturation,
            ),
            child: ring,
          )
        else
          ring,
        const SizedBox(height: AppSpace.sm),
        // 地面の楕円影（elev.ground / 被写体を地面に「置く」）
        Container(
          width: diameter * 0.62,
          height: diameter * 0.12,
          decoration: const BoxDecoration(
            color: AppElevation.ground,
            borderRadius: BorderRadius.all(Radius.elliptical(100, 24)),
          ),
        ),
      ],
    );
  }
}

/// 巣リングを土台にした主役パネル（NestPanel / DESIGN_SYSTEM §7）。
/// ホームの主役卵・たまご画面で再利用する。`radius.lg` / `nest.sand` 地。
class NestPanel extends StatelessWidget {
  const NestPanel({
    super.key,
    required this.subject,
    this.diameter = 180,
    this.glow,
    this.dimmed = false,
    this.caption,
    this.footer,
  });

  /// 中央被写体（卵/Mofi/空枠アイコン）。
  final Widget subject;
  final double diameter;
  final Color? glow;
  final bool dimmed;

  /// 巣の上の吹き出し文言（例「孵化まであと120pt」）。
  final Widget? caption;

  /// パネル下部に置く要素（プログレスバー等）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        vertical: AppSpace.xxl,
        horizontal: AppSpace.lg,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surfaceNest,
        borderRadius: AppRadius.lgR,
      ),
      child: Column(
        children: [
          if (caption != null) ...[
            caption!,
            const SizedBox(height: AppSpace.md),
          ],
          NestRing(diameter: diameter, glow: glow, dimmed: dimmed, child: subject),
          if (footer != null) ...[
            const SizedBox(height: AppSpace.lg),
            footer!,
          ],
        ],
      ),
    );
  }
}

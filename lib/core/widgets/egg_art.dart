import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// レアリティ色帯 → 卵の本番イラストアセット（背景透過 PNG・docs/ART_ASSETS.md）。
///
/// アセットはコンセプト参照シートから卵だけを切り出した透過 PNG（巣は含めない＝
/// 巣リングはアプリ側 [NestRing] が描く）。読み込めない場合は [EggArt] が
/// 暫定ベクター（[_EggPainter]）にフォールバックする。
String eggAssetFor(RarityToken rarity) => switch (rarity) {
      RarityToken.common => 'assets/images/egg/egg_common.png',
      RarityToken.rare => 'assets/images/egg/egg_rare.png',
      RarityToken.sr => 'assets/images/egg/egg_sr.png',
      RarityToken.ssr => 'assets/images/egg/egg_ssr.png',
    };

/// 卵のイラスト（**本番アセット + ベクターフォールバック**）。
///
/// レアリティ（[RarityToken]）ごとの背景透過イラスト（[eggAssetFor]）を表示する。
/// アセットが見つからない場合は陰影・斑点・つや・成長ヒビ付きの暫定ベクター
/// （[_EggPainter]・[progress] でヒビ段階を出す）にフォールバックする。
///
/// 卵=1ウィジェットに閉じているので、差し替え点はここだけ（active_egg_panel /
/// eggs 画面の [EggSubject] 経由を含む全画面がこのウィジェットを通る）。
class EggArt extends StatelessWidget {
  const EggArt({
    super.key,
    required this.rarity,
    this.progress = 0,
    this.size = 120,
  });

  final RarityToken rarity;

  /// 0..1 の孵化進捗。フォールバック時のヒビ段階の決定に使う。
  final double progress;

  /// 描画サイズ（NestRing 内では FittedBox で拡縮される）。
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        eggAssetFor(rarity),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        // アセット欠落・読み込み失敗時は暫定ベクターで必ず卵を表示する。
        errorBuilder: (context, error, stack) => CustomPaint(
          painter: _EggPainter(rarity: rarity, progress: progress.clamp(0, 1)),
        ),
      ),
    );
  }
}

class _EggPainter extends CustomPainter {
  _EggPainter({required this.rarity, required this.progress});

  final RarityToken rarity;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final eggW = w * 0.62;
    final eggH = h * 0.82;
    final cx = w / 2;
    final top = h * 0.08;
    final bottom = top + eggH;
    final left = cx - eggW / 2;
    final right = cx + eggW / 2;

    // 卵形パス（上が細く下がふっくら）。
    final egg = Path()
      ..moveTo(cx, top)
      ..cubicTo(
        right + eggW * 0.06, top + eggH * 0.10,
        right, bottom - eggH * 0.16,
        cx, bottom,
      )
      ..cubicTo(
        left, bottom - eggH * 0.16,
        left - eggW * 0.06, top + eggH * 0.10,
        cx, top,
      )
      ..close();

    // 地面の影。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, bottom + eggH * 0.02),
        width: eggW * 0.9,
        height: eggH * 0.12,
      ),
      Paint()
        ..color = AppElevation.ground
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // 本体グラデ（左上ハイライト → レアリティ色）。
    final bodyRect = Rect.fromLTRB(left, top, right, bottom);
    canvas.drawPath(
      egg,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.6),
          radius: 1.1,
          colors: [
            Color.lerp(rarity.glow, Colors.white, 0.55)!,
            rarity.glow,
            rarity.main,
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(bodyRect),
    );

    // 斑点（固定シードで毎回同じ配置）。
    canvas.save();
    canvas.clipPath(egg);
    final speck = Paint()..color = rarity.main.withValues(alpha: 0.40);
    final rnd = math.Random(7);
    for (var i = 0; i < 12; i++) {
      final px = left + eggW * (0.16 + rnd.nextDouble() * 0.68);
      final py = top + eggH * (0.20 + rnd.nextDouble() * 0.68);
      final r = eggW * (0.025 + rnd.nextDouble() * 0.03);
      canvas.drawOval(
        Rect.fromCenter(center: Offset(px, py), width: r * 2, height: r * 1.6),
        speck,
      );
    }
    canvas.restore();

    // つや（左上の白ハイライト）。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - eggW * 0.18, top + eggH * 0.24),
        width: eggW * 0.22,
        height: eggH * 0.16,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.5),
    );

    // やわらかい輪郭。
    canvas.drawPath(
      egg,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, w * 0.012)
        ..color = AppColors.nestBark.withValues(alpha: 0.30),
    );

    // 成長ヒビ。
    final crack = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, w * 0.018)
      ..strokeJoin = StrokeJoin.round
      ..color = AppColors.nestBark.withValues(alpha: 0.75);
    if (progress >= 0.2) {
      canvas.drawPath(
        Path()
          ..moveTo(cx + eggW * 0.10, top + eggH * 0.30)
          ..lineTo(cx + eggW * 0.02, top + eggH * 0.38)
          ..lineTo(cx + eggW * 0.12, top + eggH * 0.44)
          ..lineTo(cx + eggW * 0.04, top + eggH * 0.50),
        crack,
      );
    }
    if (progress >= 0.5) {
      canvas.drawPath(
        Path()
          ..moveTo(left + eggW * 0.06, top + eggH * 0.56)
          ..lineTo(left + eggW * 0.30, top + eggH * 0.50)
          ..lineTo(left + eggW * 0.48, top + eggH * 0.58)
          ..lineTo(left + eggW * 0.68, top + eggH * 0.50)
          ..lineTo(left + eggW * 0.92, top + eggH * 0.57),
        crack,
      );
    }

    // SSR はきらめき。
    if (rarity == RarityToken.ssr) {
      _sparkle(
        canvas,
        Offset(right - eggW * 0.04, top + eggH * 0.14),
        eggW * 0.08,
        Paint()..color = Colors.white.withValues(alpha: 0.9),
      );
    }
  }

  void _sparkle(Canvas c, Offset o, double r, Paint p) {
    c.drawPath(
      Path()
        ..moveTo(o.dx, o.dy - r)
        ..lineTo(o.dx + r * 0.25, o.dy - r * 0.25)
        ..lineTo(o.dx + r, o.dy)
        ..lineTo(o.dx + r * 0.25, o.dy + r * 0.25)
        ..lineTo(o.dx, o.dy + r)
        ..lineTo(o.dx - r * 0.25, o.dy + r * 0.25)
        ..lineTo(o.dx - r, o.dy)
        ..lineTo(o.dx - r * 0.25, o.dy - r * 0.25)
        ..close(),
      p,
    );
  }

  @override
  bool shouldRepaint(covariant _EggPainter old) =>
      old.rarity != rarity || old.progress != progress;
}

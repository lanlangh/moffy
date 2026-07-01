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
    final p = progress.clamp(0.0, 1.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            eggAssetFor(rarity),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            // アセット欠落・読み込み失敗時は暫定ベクターで必ず卵を表示する。
            errorBuilder: (context, error, stack) => CustomPaint(
              painter: _EggPainter(rarity: rarity, progress: p),
            ),
          ),
          // 成長ヒビ（画像・ベクター共通の上乗せ / §4-5）。孵化が近づくほど割れる。
          // 本番は段階別の卵イラスト（docs/ART_ASSETS.md）に差し替え可。
          if (p >= _crack1Threshold)
            CustomPaint(painter: _CrackOverlayPainter(progress: p)),
        ],
      ),
    );
  }
}

/// ヒビ①/②のしきい値比（§4-5: 100/500=0.2 / 250/500=0.5）。
const double _crack1Threshold = 0.2;
const double _crack2Threshold = 0.5;

/// 卵の上に重ねる成長ヒビ（画像・ベクター共通）。座標は卵の胴体（上部中央）に合わせた
/// ウィジェット 0..1 比率。PIL で実アセットに重ねて位置を検証済み。
class _CrackOverlayPainter extends CustomPainter {
  _CrackOverlayPainter({required this.progress});

  final double progress;

  static const List<Offset> _crack1 = [
    Offset(0.53, 0.20),
    Offset(0.47, 0.30),
    Offset(0.55, 0.37),
    Offset(0.48, 0.46),
  ];
  static const List<Offset> _crack2 = [
    Offset(0.30, 0.46),
    Offset(0.42, 0.40),
    Offset(0.50, 0.47),
    Offset(0.60, 0.40),
    Offset(0.70, 0.47),
  ];

  void _drawCrack(Canvas canvas, Size size, List<Offset> pts) {
    Path pathOf(List<Offset> ps) {
      final path = Path()
        ..moveTo(ps.first.dx * size.width, ps.first.dy * size.height);
      for (final o in ps.skip(1)) {
        path.lineTo(o.dx * size.width, o.dy * size.height);
      }
      return path;
    }

    // 影の割れ線。
    canvas.drawPath(
      pathOf(pts),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, size.width * 0.018)
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = AppColors.nestBark.withValues(alpha: 0.82),
    );
    // わずかにずらした淡いハイライトで割れの立体感。
    canvas.drawPath(
      pathOf([for (final o in pts) o.translate(0.006, 0.006)]),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, size.width * 0.010)
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white.withValues(alpha: 0.28),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (progress >= _crack1Threshold) _drawCrack(canvas, size, _crack1);
    if (progress >= _crack2Threshold) _drawCrack(canvas, size, _crack2);
  }

  @override
  bool shouldRepaint(covariant _CrackOverlayPainter old) =>
      old.progress != progress;
}

/// 空／ローディング状態の「卵型プレースホルダ（淡いゴースト）」。
///
/// 実物の卵（[EggArt]）ではなく「ここに卵が入る／読み込み中」を示す。Material の
/// 既製アイコン（`Icons.egg_*`）の代わりに使い、巣リング（[NestRing]）の中央に置く。
/// 卵アセット方針（DESIGN_SYSTEM §6・2026-06-30）: 空状態は卵の実画像を出さず、
/// 巣リング＝空の巣 の上にこの淡い卵型ゴーストだけを乗せる。
class NestPlaceholder extends StatelessWidget {
  const NestPlaceholder({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _EggGhostPainter()),
    );
  }
}

class _EggGhostPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // 巣リングの円いっぱいに卵型を出す（小さく見えないように枠のほぼ全体を使う）。
    final eggW = w * 0.80;
    final eggH = h * 0.96;
    final cx = w / 2;
    final top = h * 0.02;
    final bottom = top + eggH;
    final left = cx - eggW / 2;
    final right = cx + eggW / 2;

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

    // ごく淡い塗り＋点線でなく細い輪郭。「不在＝これから入る」を静かに示す。
    canvas.drawPath(
      egg,
      Paint()..color = AppColors.textDisabled.withValues(alpha: 0.12),
    );
    canvas.drawPath(
      egg,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, w * 0.012)
        ..color = AppColors.textDisabled.withValues(alpha: 0.5),
    );
  }

  @override
  bool shouldRepaint(covariant _EggGhostPainter old) => false;
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

    // 成長ヒビは共通の _CrackOverlayPainter が画像・ベクター双方の上に重ねて描く
    // （ここでは描かない＝二重描画回避）。

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

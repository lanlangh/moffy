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
          if (p >= _crackStartThreshold)
            CustomPaint(painter: _CrackOverlayPainter(progress: p)),
        ],
      ),
    );
  }
}

/// ヒビが出始める進捗しきい値（§4-5: 100/500=0.2）。以降は「1本のヒビが伸びて太くなる」。
const double _crackStartThreshold = 0.2;

/// 卵の上に重ねる成長ヒビ（画像・ベクター共通）。1本の横向きジグザグ亀裂が、進捗とともに
/// 中央から左右へ伸び、太くなる（＝ヒビが「大きくなる」）。2本目を並べる方式はやめた（ユーザーFB）。
/// 座標は卵の胴中央（0..1 比率・左右対称）。孵化間近だけ中央から短い枝ヒビを足す。
class _CrackOverlayPainter extends CustomPainter {
  _CrackOverlayPainter({required this.progress});

  final double progress;

  // 卵の胴中央を横切る1本のジグザグ（左右対称）のフルの姿。
  static const List<Offset> _crack = [
    Offset(0.16, 0.44),
    Offset(0.28, 0.39),
    Offset(0.38, 0.45),
    Offset(0.50, 0.40),
    Offset(0.62, 0.46),
    Offset(0.72, 0.39),
    Offset(0.84, 0.45),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (progress < _crackStartThreshold) return;
    // 開始しきい値〜1.0 を 0..1 に正規化＝ヒビの成長度。
    final t = ((progress - _crackStartThreshold) / (1 - _crackStartThreshold))
        .clamp(0.0, 1.0);

    final full = Path()
      ..moveTo(_crack.first.dx * size.width, _crack.first.dy * size.height);
    for (final o in _crack.skip(1)) {
      full.lineTo(o.dx * size.width, o.dy * size.height);
    }

    // 中央から外側へ「伸びる」（reveal）＋進捗で「太くなる」（strokeW）。
    final reveal = (0.34 + 0.66 * t).clamp(0.0, 1.0);
    final strokeW = math.max(2.0, size.width * (0.014 + 0.016 * t));

    final shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = AppColors.nestBark.withValues(alpha: 0.85);
    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, strokeW * 0.45)
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.28);

    for (final m in full.computeMetrics()) {
      final seg = m.extractPath(
        m.length * (0.5 - reveal / 2),
        m.length * (0.5 + reveal / 2),
      );
      canvas.drawPath(seg, shadow);
      canvas.drawPath(seg.shift(const Offset(0.6, 0.8)), highlight);
    }

    // 孵化間近: 中央から上下に短い枝ヒビ（“もう割れる”感。平行な2本目にはしない）。
    if (t > 0.75) {
      final cx = 0.5 * size.width;
      final cy = 0.42 * size.height;
      final branch = Path()
        ..moveTo(cx, cy)
        ..lineTo(cx - size.width * 0.03, cy - size.height * 0.08)
        ..moveTo(cx, cy)
        ..lineTo(cx + size.width * 0.025, cy + size.height * 0.09);
      canvas.drawPath(
        branch,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW * 0.8
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = AppColors.nestBark.withValues(alpha: 0.7),
      );
    }
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

/// 空状態（「育てる卵を選ぼう」/「巣が空いています」）の“これから育てる卵”プレースホルダ。
/// オーナー用意の白い卵 `assets/images/egg/egg_empty.png` を薄く（半透明）表示する。
/// 未配置/読み込み失敗時はレア共通の [EggArt] にフォールバック（画像が届くまでも動く）。
class EmptyNestEgg extends StatelessWidget {
  const EmptyNestEgg({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.5,
      child: SizedBox.square(
        dimension: size,
        child: Image.asset(
          'assets/images/egg/egg_empty.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
          errorBuilder: (context, error, stack) =>
              const EggArt(rarity: RarityToken.common),
        ),
      ),
    );
  }
}

class _EggGhostPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final egg = eggOutlinePath(w, size.height);
    // ごく淡い塗り＋細い輪郭。「不在＝これから入る」を静かに示す（本物の卵型）。
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

/// 本物の卵型シルエット（底が丸く上が細い）を `w`×`h` の枠にほぼ収める。
/// 旧実装は上下とも尖った葉型で「卵に見えない」問題があったため、PIL で実描画検証した
/// 制御点に差し替えた。プレースホルダ等で共用する。
Path eggOutlinePath(double w, double h) {
  final scale = h * 0.96; // 高さいっぱい
  final cx = w / 2;
  final top = h * 0.02;
  // 単位ボックス（cx=0.5 / y:0上→1下）を uniform scale でピクセルへ。
  double px(double ux) => cx + (ux - 0.5) * scale;
  double py(double uy) => top + uy * scale;
  final path = Path()..moveTo(px(0.50), py(0.00));
  void c(double a, double b, double cc, double dd, double e, double f) {
    path.cubicTo(px(a), py(b), px(cc), py(dd), px(e), py(f));
  }

  c(0.80, 0.05, 0.84, 0.42, 0.84, 0.60); // 上 → 右の最大幅
  c(0.84, 0.86, 0.70, 1.00, 0.50, 1.00); // → 丸い底
  c(0.30, 1.00, 0.16, 0.86, 0.16, 0.60); // 底 → 左
  c(0.16, 0.42, 0.20, 0.05, 0.50, 0.00); // → 上へ
  path.close();
  return path;
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

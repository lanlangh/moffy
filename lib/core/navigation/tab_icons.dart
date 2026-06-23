import 'package:flutter/material.dart';

/// ボトムナビ5タブのアイコン（DESIGN_SYSTEM §6）。
///
/// 方針: アイコンは SVG で統一し、絵文字を代わりに使わない（PRD 禁止事項）。
///   * 線幅2px・角丸端・ink.600 基調、アクティブ時 warm.orange。
///   * 塗りつぶし版（アクティブ）とライン版（非アクティブ）の2状態を持つ。
/// 外部アセットに依存せず、[CustomPainter] でパス描画する（オフライン安定 / 審査安全）。
/// アセットSVG導入時はこの描画を差し替えるだけでよい（呼び出し側は [TabGlyph] のみ参照）。
enum TabGlyph { home, egg, dex, quest, menu }

/// タブアイコン。[filled] でライン/塗りの2状態を切り替える（DESIGN_SYSTEM §6）。
class TabIcon extends StatelessWidget {
  const TabIcon({
    super.key,
    required this.glyph,
    required this.color,
    required this.filled,
    this.size = 26,
  });

  final TabGlyph glyph;
  final Color color;
  final bool filled;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _TabIconPainter(glyph: glyph, color: color, filled: filled),
      ),
    );
  }
}

class _TabIconPainter extends CustomPainter {
  _TabIconPainter({
    required this.glyph,
    required this.color,
    required this.filled,
  });

  final TabGlyph glyph;
  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    // 24x24 ビューボックス基準で描き、実サイズへスケールする。
    final scale = size.width / 24.0;
    canvas.scale(scale);

    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final paths = _paths(glyph);
    for (final p in paths) {
      if (filled && p.fillable) {
        canvas.drawPath(p.path, fill);
      }
      // 塗りの上にも線を重ね、ライン/塗りで形が一致するようにする。
      canvas.drawPath(p.path, stroke);
    }
  }

  /// 各グリフのパス（24x24 viewBox / 角丸端）。
  List<_Glyph> _paths(TabGlyph g) {
    switch (g) {
      case TabGlyph.home:
        // 家（屋根 + 本体）。
        final body = Path()
          ..moveTo(4, 11)
          ..lineTo(12, 4)
          ..lineTo(20, 11)
          ..lineTo(20, 20)
          ..lineTo(4, 20)
          ..close();
        return [_Glyph(body, fillable: true)];
      case TabGlyph.egg:
        // 卵（上が細い楕円）。
        final egg = Path()
          ..moveTo(12, 3)
          ..cubicTo(7.5, 3, 5, 9, 5, 13.5)
          ..cubicTo(5, 18, 8.2, 21, 12, 21)
          ..cubicTo(15.8, 21, 19, 18, 19, 13.5)
          ..cubicTo(19, 9, 16.5, 3, 12, 3)
          ..close();
        return [_Glyph(egg, fillable: true)];
      case TabGlyph.dex:
        // 本（図鑑）。表紙 + 背。
        final cover = Path()
          ..moveTo(5, 4)
          ..lineTo(18, 4)
          ..lineTo(18, 20)
          ..lineTo(5, 20)
          ..close();
        final spine = Path()
          ..moveTo(8, 4)
          ..lineTo(8, 20);
        return [_Glyph(cover, fillable: true), _Glyph(spine, fillable: false)];
      case TabGlyph.quest:
        // 旗（ポール + なびく旗）。
        final pole = Path()
          ..moveTo(6, 3)
          ..lineTo(6, 21);
        final flag = Path()
          ..moveTo(6, 4)
          ..lineTo(18, 4)
          ..lineTo(15, 8)
          ..lineTo(18, 12)
          ..lineTo(6, 12)
          ..close();
        return [_Glyph(flag, fillable: true), _Glyph(pole, fillable: false)];
      case TabGlyph.menu:
        // 三本線。
        final lines = Path()
          ..moveTo(5, 7)
          ..lineTo(19, 7)
          ..moveTo(5, 12)
          ..lineTo(19, 12)
          ..moveTo(5, 17)
          ..lineTo(19, 17);
        return [_Glyph(lines, fillable: false)];
    }
  }

  @override
  bool shouldRepaint(covariant _TabIconPainter old) =>
      old.glyph != glyph || old.color != color || old.filled != filled;
}

class _Glyph {
  const _Glyph(this.path, {required this.fillable});
  final Path path;

  /// 塗り（アクティブ）時に塗りつぶす形か。線のみの要素（背・ポール）は false。
  final bool fillable;
}

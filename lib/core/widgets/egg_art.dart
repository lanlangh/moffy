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

/// S1「しろいたまご」の画像（オーナー作・2026-10-21）。全レア度共通。
/// 他の4枚と同じ工程（tools/process_egg_art.py）で輪郭と余白をそろえてあるので、
/// S1→S2 で同じ位置のままレア度の画像へ切り替えられる。
const String eggBlankAsset = 'assets/images/egg/egg_blank.png';

/// たまごの見た目の段階（0018 / docs/design/EGG_PACING_DESIGN.md §4-2）。
///
/// 毎回**ちがう種類の変化**（色 → 線 → 光 → 誕生）にして、静止画でも見分けがつくようにする。
/// [step] は「最後に見た段階」として端末に保存する値（0..5）と一致させる。
enum EggLook {
  /// S1 しろいたまご（0〜99pt）。真っ白・模様なし＝レア度が分からない。
  blank,

  /// S2 もよう（100〜199pt）。レア度の色と模様（本番PNGそのもの）。
  pattern,

  /// S3 ヒビ（200〜299pt）。中央に短いヒビ1本。
  crack,

  /// S4 ひかり（300〜399pt）。ヒビが全幅に伸びて枝分かれし、光が漏れる＋光の筋4本。
  glow,

  /// S4 強まる（400〜499pt）。光の筋が9本に増え、光の粒が舞う。段階は S4 のまま。
  glowStrong,

  /// S5 うまれる！（500pt〜）。卵全体が明るく光る（孵化ボタンは呼び出し側）。
  ready;

  /// 「最後に見た段階」として保存する値。
  int get step => index;

  static EggLook fromStep(int step) =>
      EggLook.values[step.clamp(0, EggLook.values.length - 1)];

  bool get hasCrack => index >= EggLook.crack.index;
  bool get hasFullCrack => index >= EggLook.glow.index;
  bool get hasLight => index >= EggLook.glow.index;
  bool get hasStrongLight => index >= EggLook.glowStrong.index;

  /// レア度を隠す段階か（S1 は「何が生まれるか分からない」）。
  bool get hidesRarity => this == EggLook.blank;

  /// 段階名（吹き出し・読み上げ用）。
  String get label => switch (this) {
        EggLook.blank => '白い卵',
        EggLook.pattern => '模様',
        EggLook.crack => 'ヒビ',
        EggLook.glow => '光',
        EggLook.glowStrong => '光',
        EggLook.ready => '孵化',
      };
}

/// 卵のイラスト（**本番アセット + 重ね描き + ベクターフォールバック**）。
///
/// [look] で見た目の段階を決める。S1 は白い卵の画像、S2 以降はレアリティ別の画像。
/// S3〜S5 のヒビと光はベクターで重ねる（新しい画像は要らない / §4-1）。
/// アセットが見つからない場合は陰影・斑点・つや付きの暫定ベクター（[_EggPainter]）に
/// フォールバックする。
///
/// 卵=1ウィジェットに閉じているので、差し替え点はここだけ（active_egg_panel /
/// eggs 画面の [EggSubject] 経由を含む全画面がこのウィジェットを通る）。
class EggArt extends StatelessWidget {
  const EggArt({
    super.key,
    required this.rarity,
    this.look = EggLook.pattern,
    this.size = 120,
    this.animated = false,
  });

  final RarityToken rarity;

  /// 見た目の段階。既定は S2（レア度の画像そのまま）＝装飾用途（ロゴ・報酬バッジ等）は
  /// 何も指定しなくても今までどおりレア度の卵が出る。
  final EggLook look;

  /// 描画サイズ（NestRing 内では FittedBox で拡縮される）。
  final double size;

  /// 「生きている」動きを付けるか（[_LivingEgg]）。
  ///
  /// 既定 false。**ホームの主役卵だけ true** にする想定で、図鑑グリッドのように
  /// 同時に何個も並ぶ場所では付けない（ティッカーが個数分走って無駄になる）。
  final bool animated;

  @override
  Widget build(BuildContext context) {
    // 画像＋ヒビ（動きの中で作り直さない部分）。
    final base = SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            look.hidesRarity ? eggBlankAsset : eggAssetFor(rarity),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            // アセット欠落・読み込み失敗時は暫定ベクターで必ず卵を表示する。
            errorBuilder: (context, error, stack) => CustomPaint(
              painter: _EggPainter(rarity: rarity, blank: look.hidesRarity),
            ),
          ),
          // 成長ヒビ（画像・ベクター共通の上乗せ）。座標は本番PNGの卵に合わせてある。
          if (look.hasCrack)
            CustomPaint(painter: _CrackPainter(full: look.hasFullCrack)),
        ],
      ),
    );
    final still = SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          base,
          if (look.hasLight)
            CustomPaint(painter: _LightPainter(look: look, flicker: 1.0)),
        ],
      ),
    );
    if (!animated) return still;
    // OS の「視差効果を減らす」を尊重する（アクセシビリティ。審査でも見られる項目）。
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) return still;
    return _LivingEgg(look: look, size: size, base: base);
  }
}

/// 卵に「生きている」感じを与える動き。
///
/// なぜ要るか: ホームの卵は静止画で、**数字を読まないと育っているのか止まっているのか
/// 分からなかった**。育成アプリとしてここが一番弱い。動きで「読まなくても分かる」状態にする。
///
/// 段階で動きを切り替える（見た目と動きが必ず一致する / §4-2）:
///   * S1・S2: ゆっくり呼吸（scale）。「生きている・順調」
///   * S3    : 呼吸のあと小さく震える
///   * S4    : 左右にゆれる（±1.4°）。強まると大きく（±4°）
///   * S5    : 脈打つ＋光が揺らぐ。「いま生まれる」
///
/// 電池: タブは `StatefulShellRoute.indexedStack` で裏に残るが、go_router が非アクティブ枝を
/// `TickerMode(enabled: false)` で包むためティッカーは止まる。アプリがバックグラウンドに
/// 入ればエンジンがフレーム生成を止める。＝常時描画にはならない。
class _LivingEgg extends StatefulWidget {
  const _LivingEgg({required this.look, required this.size, required this.base});

  final EggLook look;
  final double size;
  final Widget base;

  @override
  State<_LivingEgg> createState() => _LivingEggState();
}

class _LivingEggState extends State<_LivingEgg>
    with SingleTickerProviderStateMixin {
  /// 呼吸はゆっくり、ゆれは速い。人が「息」と「そわそわ」を区別できる速度差にする。
  static const _breathe = Duration(milliseconds: 2600);
  static const _wobble = Duration(milliseconds: 700);
  static const _pulse = Duration(milliseconds: 900);

  static Duration _durationFor(EggLook look) => switch (look) {
        EggLook.blank || EggLook.pattern || EggLook.crack => _breathe,
        EggLook.glow || EggLook.glowStrong => _wobble,
        EggLook.ready => _pulse,
      };

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _durationFor(widget.look),
  )..repeat(reverse: true);

  @override
  void didUpdateWidget(covariant _LivingEgg old) {
    super.didUpdateWidget(old);
    // ポイントが入って段階が変わった瞬間に、動きの種類を切り替える。
    final next = _durationFor(widget.look);
    if (_c.duration != next) {
      _c.duration = next;
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final look = widget.look;
    return AnimatedBuilder(
      animation: _c,
      // child を外から渡すのが要点。毎フレーム作り直されるのは Transform と光の
      // CustomPaint だけで、画像＋ヒビは再構築されない。
      child: widget.base,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);
        // 光の揺らぎ（S4〜）。消えはしない（0.75〜1.0）。
        final flicker = look == EggLook.ready ? 0.85 + 0.15 * t : 0.75 + 0.25 * t;
        final body = SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              child!,
              if (look.hasLight)
                CustomPaint(painter: _LightPainter(look: look, flicker: flicker)),
            ],
          ),
        );
        switch (look) {
          case EggLook.blank:
          case EggLook.pattern:
            // 初版は 0.985↔1.015（±1.5%）にしたが、実機で「動いていない」と判定された
            // （2026-08-19 オーナー確認）。呼吸は**気づける**必要があるので倍にする。
            // 上下にもわずかに動かすと「息をしている」感が出て、拡縮だけより伝わる。
            return Transform.translate(
              offset: Offset(0, (1 - t) * 3),
              child: Transform.scale(
                scale: 0.97 + 0.06 * t,
                alignment: Alignment.bottomCenter, // 底は地面に接したまま膨らむ
                child: body,
              ),
            );
          case EggLook.crack:
            // 呼吸の終わりに小さく震える（「中で何かが動いている」）。
            final tremble = ((t - 0.8) / 0.2).clamp(0.0, 1.0);
            final jitter = math.sin(_c.value * math.pi * 10) * 0.02 * tremble;
            return Transform.translate(
              offset: Offset(0, (1 - t) * 3),
              child: Transform.scale(
                scale: 0.97 + 0.06 * t,
                alignment: Alignment.bottomCenter,
                child: Transform.rotate(
                  angle: jitter,
                  alignment: Alignment.bottomCenter,
                  child: body,
                ),
              ),
            );
          case EggLook.glow:
          case EggLook.glowStrong:
            // 巣に接している底を支点にする。中心で回すと卵が巣から浮いて見える。
            final amp = look == EggLook.glowStrong ? 0.14 : 0.05; // ±約4° / ±約1.4°
            return Transform.rotate(
              angle: (t - 0.5) * amp,
              alignment: Alignment.bottomCenter,
              child: body,
            );
          case EggLook.ready:
            return Transform.scale(
              scale: 1.0 + 0.06 * t,
              alignment: Alignment.bottomCenter,
              child: body,
            );
        }
      },
    );
  }
}

/// 本番PNG（512×512）の卵の形に合わせた座標（0..1 比率）。
///
/// 見本 docs/design/egg_stages_preview.html の SVG から機械的に /512 したもの。
/// 卵は画像の **横 0.21〜0.79・縦 0.03〜0.75** あたりにあり、旧ベクター卵用の座標
/// （横 0.16〜0.84）はPNGだと卵の外にはみ出していた（設計書 §6「実装の注意」）。
abstract final class _EggGeometry {
  /// S3 の短いヒビ（卵の幅の3割ほど・中央）。
  static const List<Offset> crackShort = [
    Offset(0.344, 0.398),
    Offset(0.398, 0.359),
    Offset(0.449, 0.406),
    Offset(0.504, 0.363),
    Offset(0.555, 0.406),
    Offset(0.605, 0.367),
    Offset(0.656, 0.398),
  ];

  /// S4 以降の全幅のヒビ。
  static const List<Offset> crackFull = [
    Offset(0.238, 0.402),
    Offset(0.305, 0.363),
    Offset(0.363, 0.410),
    Offset(0.422, 0.359),
    Offset(0.480, 0.402),
    Offset(0.520, 0.367),
    Offset(0.566, 0.406),
    Offset(0.629, 0.359),
    Offset(0.691, 0.406),
    Offset(0.762, 0.371),
  ];

  /// 全幅のヒビの枝（上下へ1本ずつ）。
  static const Offset branchRoot = Offset(0.520, 0.367);
  static const Offset branchUp = Offset(0.504, 0.309);
  static const Offset branchDown = Offset(0.539, 0.441);

  /// 光の筋（S4）: (始点, 終点, 太さ比)。
  static const List<(Offset, Offset, double)> rays = [
    (Offset(0.453, 0.375), Offset(0.332, 0.180), 0.0137),
    (Offset(0.566, 0.379), Offset(0.695, 0.188), 0.0137),
    (Offset(0.391, 0.391), Offset(0.148, 0.293), 0.0117),
    (Offset(0.629, 0.383), Offset(0.871, 0.289), 0.0117),
  ];

  /// 増える光の筋（S4 強まる / 5本）。
  static const List<(Offset, Offset, double)> raysMore = [
    (Offset(0.512, 0.363), Offset(0.512, 0.078), 0.0156),
    (Offset(0.332, 0.402), Offset(0.090, 0.418), 0.0098),
    (Offset(0.684, 0.398), Offset(0.918, 0.418), 0.0098),
    (Offset(0.480, 0.371), Offset(0.418, 0.102), 0.0098),
    (Offset(0.547, 0.371), Offset(0.609, 0.102), 0.0098),
  ];

  /// 光の粒（S4 強まる）: (中心, 半径比)。
  static const List<(Offset, double)> sparks = [
    (Offset(0.188, 0.188), 0.0176),
    (Offset(0.820, 0.156), 0.0137),
    (Offset(0.883, 0.488), 0.0156),
    (Offset(0.121, 0.512), 0.0117),
    (Offset(0.352, 0.066), 0.0117),
    (Offset(0.684, 0.059), 0.0137),
  ];

  /// 漏れる光の中心と半径（楕円）。
  static const Offset leakCenter = Offset(0.504, 0.387);
  static const double leakRx = 0.234;
  static const double leakRy = 0.066;

  /// 卵の部分だけ（巣の前縁より上）を覆う形。光を卵の中に閉じ込めるクリップ。
  static Path eggTop(Size s) {
    final w = s.width;
    final h = s.height;
    return Path()
      ..moveTo(0.500 * w, 0.047 * h)
      ..cubicTo(0.676 * w, 0.047 * h, 0.785 * w, 0.258 * h, 0.785 * w, 0.461 * h)
      ..cubicTo(0.785 * w, 0.590 * h, 0.730 * w, 0.695 * h, 0.648 * w, 0.734 * h)
      ..quadraticBezierTo(0.500 * w, 0.773 * h, 0.352 * w, 0.734 * h)
      ..cubicTo(0.270 * w, 0.695 * h, 0.215 * w, 0.590 * h, 0.215 * w, 0.461 * h)
      ..cubicTo(0.215 * w, 0.258 * h, 0.324 * w, 0.047 * h, 0.500 * w, 0.047 * h)
      ..close();
  }

  static Path polyline(List<Offset> pts, Size s) {
    final p = Path()..moveTo(pts.first.dx * s.width, pts.first.dy * s.height);
    for (final o in pts.skip(1)) {
      p.lineTo(o.dx * s.width, o.dy * s.height);
    }
    return p;
  }
}

/// 卵の上に重ねるヒビ（画像・ベクター共通）。
///
/// S3 は中央に短い1本、S4 以降は全幅＋枝。段階で**ジャンプ**させる（連続的に伸ばさない）。
/// 以前は進捗に比例して少しずつ伸ばしていたため、日ごとの差が見えなかった（オーナー指摘）。
class _CrackPainter extends CustomPainter {
  _CrackPainter({required this.full});

  final bool full;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = full ? _EggGeometry.crackFull : _EggGeometry.crackShort;
    final path = _EggGeometry.polyline(pts, size);
    final strokeW = math.max(2.0, size.width * (full ? 0.0156 : 0.0176));

    final shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = AppColors.eggCrack.withValues(alpha: 0.92);
    final highlight = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, strokeW * 0.33)
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: 0.35);

    canvas.drawPath(path, shadow);
    canvas.drawPath(
      path.shift(Offset(size.width * 0.004, size.height * 0.006)),
      highlight,
    );

    if (full) {
      const root = _EggGeometry.branchRoot;
      final branch = Path()
        ..moveTo(root.dx * size.width, root.dy * size.height)
        ..lineTo(
          _EggGeometry.branchUp.dx * size.width,
          _EggGeometry.branchUp.dy * size.height,
        )
        ..moveTo(root.dx * size.width, root.dy * size.height)
        ..lineTo(
          _EggGeometry.branchDown.dx * size.width,
          _EggGeometry.branchDown.dy * size.height,
        );
      canvas.drawPath(
        branch,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, size.width * 0.0117)
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = AppColors.eggCrack.withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CrackPainter old) => old.full != full;
}

/// ヒビから漏れる光（S4〜）。
///
/// 全レア度で暖色の白〜金（[AppColors.eggLightSoft]〜[AppColors.eggLight]）。
/// [flicker] は 0..1 の揺らぎ（静止画では 1.0）。
class _LightPainter extends CustomPainter {
  _LightPainter({required this.look, required this.flicker});

  final EggLook look;
  final double flicker;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final f = flicker.clamp(0.0, 1.0);

    // ① 卵の中に閉じ込めた、やわらかい光のたまり（ヒビの周り）。
    canvas.save();
    canvas.clipPath(_EggGeometry.eggTop(size));
    const c = _EggGeometry.leakCenter;
    final leakRect = Rect.fromCenter(
      center: Offset(c.dx * w, c.dy * h),
      width: _EggGeometry.leakRx * 2 * w,
      height: _EggGeometry.leakRy * 2 * h,
    );
    canvas.drawOval(
      leakRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            AppColors.eggLightSoft.withValues(alpha: 0.95 * f),
            AppColors.eggLight.withValues(alpha: 0.0),
          ],
        ).createShader(leakRect)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.012),
    );
    // S5: 卵全体が明るく光る（白いベール）。
    if (look == EggLook.ready) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Colors.white.withValues(alpha: 0.42 * f),
      );
    }
    canvas.restore();

    // ② ヒビそのものが光る（全幅のヒビに沿って淡い線）。
    canvas.drawPath(
      _EggGeometry.polyline(_EggGeometry.crackFull, size),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.0, w * 0.006)
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = AppColors.eggLightSoft.withValues(alpha: 0.9 * f),
    );

    // ③ 光の筋（S4: 4本 / 強まる: +5本）。
    void rays(List<(Offset, Offset, double)> list, Color color, double alpha) {
      for (final (a, b, wr) in list) {
        canvas.drawLine(
          Offset(a.dx * w, a.dy * h),
          Offset(b.dx * w, b.dy * h),
          Paint()
            ..strokeWidth = math.max(1.5, w * wr)
            ..strokeCap = StrokeCap.round
            ..color = color.withValues(alpha: alpha * f),
        );
      }
    }

    rays(_EggGeometry.rays, AppColors.eggLightRay, 0.85);
    if (look.hasStrongLight) {
      rays(_EggGeometry.raysMore, AppColors.eggLightRayPale, 0.9);
      // ④ 光の粒（揺らぎで少し浮き沈みする）。
      final lift = (1 - f) * h * 0.02;
      for (final (p, r) in _EggGeometry.sparks) {
        canvas.drawCircle(
          Offset(p.dx * w, p.dy * h - lift),
          math.max(1.5, r * w),
          Paint()..color = AppColors.eggLight.withValues(alpha: 0.9 * f),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LightPainter old) =>
      old.look != look || old.flicker != flicker;
}

/// 空／ローディング状態の「卵型プレースホルダ」。
///
/// 「ここに卵が入る／読み込み中」を示す。**署名の卵アート `egg_empty.png`** を薄く表示する
/// （[EmptyNestEgg] に委譲）。巣リング（[NestRing]）の中央に置く。旧実装のグレーのベクター
/// ゴースト（`_EggGhostPainter`）は廃止し、空状態/ローディングも卵イラストで統一した
/// （オーナーFB 2026-07-09）。これを使う全画面（各種 NestSkeleton / EmptyState）が自動で
/// ブランドの卵になる。
class NestPlaceholder extends StatelessWidget {
  const NestPlaceholder({super.key, this.size = 120});

  final double size;

  @override
  Widget build(BuildContext context) => EmptyNestEgg(size: size);
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

/// 暫定ベクターの卵（アセットが読めないときのフォールバック）。
/// [blank] が true なら S1 の白い卵（斑点なし）。
class _EggPainter extends CustomPainter {
  _EggPainter({required this.rarity, this.blank = false});

  final RarityToken rarity;
  final bool blank;

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

    // 本体グラデ（左上ハイライト → レアリティ色 / 白い卵はクリーム寄りの白）。
    final bodyRect = Rect.fromLTRB(left, top, right, bottom);
    final glow = blank ? AppColors.bg : rarity.glow;
    final main = blank ? AppColors.surfaceNest : rarity.main;
    canvas.drawPath(
      egg,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.4, -0.6),
          radius: 1.1,
          colors: [
            Color.lerp(glow, Colors.white, 0.55)!,
            glow,
            main,
          ],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(bodyRect),
    );

    // 斑点（固定シードで毎回同じ配置）。白い卵には出さない（模様はS2から）。
    if (!blank) {
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
    }

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

    // SSR はきらめき。
    if (!blank && rarity == RarityToken.ssr) {
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
      old.rarity != rarity || old.blank != blank;
}

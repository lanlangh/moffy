import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/egg_art.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../domain/egg_models.dart';
import '../egg_visuals.dart';

/// 孵化演出オーバーレイ（SCREEN_FLOWS §3 孵化演出 / 色違いキラリ演出）。
///
/// フロー: 卵が揺れる（待ち）→ 割れる → Mofi登場（巣リング上）→ 結果カード。
///   * レアリティで光の色を変える（§2-3。SSRは黄金の強い光）。
///   * 色違い（2%）は専用キラリ演出: ホワイトフラッシュ + 虹色粒子 + 補色オーラ +
///     「色違い！」ラベル（絵文字でなくSVGきらめき）+ シェアCTA（口コミ拡散 / S13）。
///   * 演出中は操作ロック、右上に「スキップ」。
///
/// 抽選はサーバー責務（ARCHITECTURE §2-3）。本Widgetは受け取った [HatchResult] を
/// 演出するだけで、抽選・図鑑書き込みは行わない。
class HatchOverlay extends StatefulWidget {
  const HatchOverlay({
    super.key,
    required this.result,
    required this.onClose,
    required this.onGoToDex,
    required this.onShare,
  });

  final HatchResult result;

  /// 演出を閉じる（× / 背景）。
  final VoidCallback onClose;

  /// 「図鑑を見る」。
  final VoidCallback onGoToDex;

  /// 色違い時の「シェアする」（口コミ拡散の起点 / S13）。
  ///
  /// 結果カードのキャプチャPNG（生成失敗時は null）を受け取る。実際のファイル/テキスト
  /// 共有は呼び出し側（[HatchShareService] 経由）で行い、本Widgetは画像生成までを担う。
  final Future<void> Function(Uint8List? imageBytes) onShare;

  @override
  State<HatchOverlay> createState() => _HatchOverlayState();
}

class _HatchOverlayState extends State<HatchOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _shake = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// 演出フェーズ。shaking（卵が揺れる）→ revealed（Mofi登場 + 結果）。
  bool _revealed = false;

  /// シェア画像としてキャプチャする結果カードの境界（S13）。
  final GlobalKey _shareBoundaryKey = GlobalKey();

  /// 二重シェア防止（連打ガード）。
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _shake.repeat(reverse: true);
    // 待ち時間を演出に転化（SCREEN_FLOWS §3）。一定時間で結果へ。
    Future<void>.delayed(const Duration(milliseconds: 1400), _playReveal);
  }

  void _playReveal() {
    if (!mounted || _revealed) return;
    _shake.stop();
    setState(() => _revealed = true);
    _reveal.forward();
  }

  /// スキップ: 即座に結果表示へ（演出スキップ可 / §5-2）。
  void _skip() {
    if (_revealed) return;
    _playReveal();
  }

  /// 結果カード（[RepaintBoundary]）をPNGへキャプチャする（S13 シェア画像）。
  /// レンダリング前/失敗時は null を返し、テキストのみ共有へフォールバックさせる。
  Future<Uint8List?> _captureSharePng() async {
    try {
      final boundary = _shareBoundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return null;
      // 高解像度で書き出し（SNS表示で粗く見えないように）。
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null; // キャプチャ失敗はテキスト共有で吸収。
    }
  }

  /// シェアボタン押下: 結果カードをキャプチャして [HatchOverlay.onShare] へ渡す。
  Future<void> _handleShare() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final bytes = await _captureSharePng();
      await widget.onShare(bytes);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  void dispose() {
    _shake.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isShiny = widget.result.isShiny;
    final rarity = RarityVisuals.ofMofi(widget.result.species.rarity);

    return Material(
      // 演出中の操作ロック（背景タップは結果表示後のみ閉じる）。
      color: AppColors.textPrimary.withValues(alpha: 0.92),
      child: SafeArea(
        child: Stack(
          children: [
            Center(
              child: _revealed
                  ? _ResultView(
                      result: widget.result,
                      shareBoundaryKey: _shareBoundaryKey,
                      sharing: _sharing,
                      onGoToDex: widget.onGoToDex,
                      onShare: _handleShare,
                      onClose: widget.onClose,
                    )
                  : _ShakingEgg(animation: _shake, rarity: rarity),
            ),
            // 色違いキラリ演出: 割れる瞬間のホワイトフラッシュ + 虹粒子。
            if (_revealed && isShiny)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _reveal,
                    builder: (context, _) => CustomPaint(
                      painter: _ShinySparklePainter(progress: _reveal.value),
                    ),
                  ),
                ),
              ),
            // スキップ（演出中のみ / 右上）。
            if (!_revealed)
              Positioned(
                top: AppSpace.lg,
                right: AppSpace.lg,
                child: TextButton(
                  onPressed: _skip,
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.onPrimary,
                  ),
                  child: const Text('スキップ'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 割れる前の揺れる卵（待ち演出）。孵化間近＝本番の卵イラスト（[EggArt]）を揺らす。
class _ShakingEgg extends StatelessWidget {
  const _ShakingEgg({required this.animation, required this.rarity});
  final Animation<double> animation;
  final RarityToken rarity;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final angle = math.sin(animation.value * math.pi * 2) * 0.08;
            return Transform.rotate(angle: angle, child: child);
          },
          child: NestRing(
            diameter: 200,
            glow: rarity.glow,
            // 孵化直前なので進捗を高くしてヒビ表現（フォールバック時）を出す。
            child: EggArt(rarity: rarity, progress: 0.9),
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        Text(
          'たまごが揺れている…',
          style: AppType.title.copyWith(color: AppColors.onPrimary),
        ),
      ],
    );
  }
}

/// 孵化結果（Mofi登場 + 名前/レア/色違い + CTA）。
class _ResultView extends StatelessWidget {
  const _ResultView({
    required this.result,
    required this.shareBoundaryKey,
    required this.sharing,
    required this.onGoToDex,
    required this.onShare,
    required this.onClose,
  });

  final HatchResult result;

  /// シェア画像としてキャプチャする結果カードの境界（S13）。
  final GlobalKey shareBoundaryKey;

  /// シェア処理中（連打防止のためボタンを無効化）。
  final bool sharing;
  final VoidCallback onGoToDex;
  final VoidCallback onShare;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final isShiny = result.isShiny;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 結果カード本体（= シェア画像としてキャプチャされる領域 / S13）。
          // 明るいカードに載せることで、共有画像が単体でも見栄えする。
          RepaintBoundary(
            key: shareBoundaryKey,
            child: _HatchShareCard(result: result),
          ),
          const SizedBox(height: AppSpace.xl),
          // 色違いはシェアCTAを主役に（口コミ拡散 / S13）。
          if (isShiny) ...[
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: sharing ? 'シェアを準備中…' : 'シェアする',
                icon: Icons.ios_share_rounded,
                onPressed: sharing ? null : onShare,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
          ],
          SizedBox(
            width: double.infinity,
            child: isShiny
                ? OutlinedButton(
                    onPressed: onGoToDex,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.onPrimary,
                      side: const BorderSide(color: AppColors.onPrimary),
                      minimumSize: const Size.fromHeight(52),
                      shape: const RoundedRectangleBorder(
                        borderRadius: AppRadius.pillR,
                      ),
                    ),
                    child: const Text('図鑑を見る'),
                  )
                : PrimaryButton(label: '図鑑を見る', onPressed: onGoToDex),
          ),
          const SizedBox(height: AppSpace.sm),
          TextButton(
            onPressed: onClose,
            style: TextButton.styleFrom(foregroundColor: AppColors.primarySoft),
            child: const Text('とじる'),
          ),
        ],
      ),
    );
  }
}

/// 孵化結果のカード（明るい面に Mofi + 名前/レア + ブランド署名）。
///
/// この Widget が [RepaintBoundary] でキャプチャされ、そのままシェア画像になる（S13）。
/// 暗いスクリム上の loose な列ではなく独立したカードにすることで、共有先（SNS）でも
/// 1枚絵として成立させる。文字色はカード（明色）前提で textPrimary 系を使う。
class _HatchShareCard extends StatelessWidget {
  const _HatchShareCard({required this.result});

  final HatchResult result;

  @override
  Widget build(BuildContext context) {
    final isShiny = result.isShiny;
    final rarity = RarityVisuals.ofMofi(result.species.rarity);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.xl,
        vertical: AppSpace.xl,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.lgR,
        boxShadow: AppElevation.float,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 色違いラベル（明色カード上 / 絵文字でなくアイコン）。
          // 色は祝いのブランド色（warn=警告色の流用をやめる。ごほうびに警告色は意味が衝突）。
          if (isShiny)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.lg,
                vertical: AppSpace.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.16),
                borderRadius: AppRadius.pillR,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 18,
                    color: AppColors.primaryDeep,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Text(
                    '色違い！',
                    style: AppType.bodyStrong
                        .copyWith(color: AppColors.primaryDeep),
                  ),
                  const SizedBox(width: AppSpace.xs),
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 18,
                    color: AppColors.primaryDeep,
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpace.lg),
          // Mofi登場（巣リング上 / 色違いは補色オーラ）。
          NestRing(
            diameter: 200,
            glow: isShiny ? rarity.glow.withValues(alpha: 0.9) : rarity.main,
            child: MofiSubject(
              family: result.species.family,
              rarity: result.species.rarity,
            ),
          ),
          const SizedBox(height: AppSpace.xl),
          Text(result.species.name, style: AppType.display),
          const SizedBox(height: AppSpace.xs),
          Text(
            '${result.species.rarity.label}・${result.species.family.label}',
            style: AppType.body.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            '図鑑に登録しました',
            style: AppType.caption,
          ),
          const SizedBox(height: AppSpace.lg),
          // ブランド署名（シェア画像にのみ意味を持つ。出所を示し拡散を促す）。
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EggArt(rarity: RarityToken.common, size: 18),
              const SizedBox(width: AppSpace.xs),
              Text(
                'Moffy',
                style: AppType.numLabel.copyWith(color: AppColors.primary),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 色違い専用「キラリ」: 巣リングから舞う虹色粒子 + ホワイトフラッシュ（S13）。
class _ShinySparklePainter extends CustomPainter {
  _ShinySparklePainter({required this.progress});

  /// 0.0〜1.0。前半でホワイトアウト、後半で粒子が広がる。
  final double progress;

  // 虹色パレットは全てトークン参照（生の色値は tokens.dart のみ / DESIGN_SYSTEM SSOT）。
  // RarityToken.*.main は enum フィールド getter で const 不可のため static final。
  static final List<Color> _rainbow = [
    AppColors.error,
    AppColors.warn,
    AppColors.success,
    RarityToken.rare.main,
    RarityToken.sr.main,
    RarityToken.ssr.main,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 前半: ホワイトフラッシュ（フェードアウト）。
    final flash = (1.0 - progress * 2).clamp(0.0, 1.0);
    if (flash > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = AppColors.surface.withValues(alpha: flash * 0.8),
      );
    }

    // 後半: 虹色粒子が中心から放射状に舞う。
    final spread = (progress).clamp(0.0, 1.0);
    final maxR = size.shortestSide * 0.5;
    final rng = math.Random(7); // 安定した粒子配置（再描画でちらつかない）
    const count = 28;
    for (var i = 0; i < count; i++) {
      final angle = (i / count) * math.pi * 2 + rng.nextDouble();
      final dist = maxR * spread * (0.4 + rng.nextDouble() * 0.6);
      final pos = center + Offset(math.cos(angle), math.sin(angle)) * dist;
      final r = 3.0 + rng.nextDouble() * 3.0;
      final color = _rainbow[i % _rainbow.length];
      canvas.drawCircle(
        pos,
        r * (1.0 - spread * 0.4),
        Paint()..color = color.withValues(alpha: (1.0 - spread) * 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ShinySparklePainter old) =>
      old.progress != progress;
}

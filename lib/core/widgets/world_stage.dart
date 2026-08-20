import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 「Moffy の世界」の風景を敷く背景（たまごタブの主役ステージ / 図鑑の詳細で共用）。
///
/// なぜ共通部品にしたか: たまごタブと図鑑の両方で同じ絵を使う。片方だけ寄りや
/// 溶かし方を変えると「同じ世界に見えない」ので、寄せ方・境目の処理をここに集約する。
///
/// 設計の要点:
///   * **上下の境目はコード側で溶かす**（画像に単色帯を焼き込まない）。
///     画像側で処理すると空や雲まで失われ、絵が暗く平板になる（実地で失敗済み）。
///     この分担なら、将来「雲を流す」ときも雲だけの透過画像を重ねれば済む。
///   * **拡大して切り取る**。正方形の絵を画面幅に合わせると風景全体が縮んで
///     「遠景」になり、スマホでは小さく見える（オーナー実機確認で判明）。
///   * 画像が読めない場合は**何も描かない**＝呼び出し側の地色がそのまま出る。
class WorldStageBackground extends StatelessWidget {
  const WorldStageBackground({
    super.key,
    this.zoom = 1.45,
    this.fadeTop = true,
    this.fadeBottom = true,
  });

  /// 背景の寄り。1.0 で絵の全体、大きいほど寄る（＝風景が大きく見える）。
  final double zoom;

  /// 上端を地色へ溶かす（画面上部に置くとき用）。
  final bool fadeTop;

  /// 下端を地色へ溶かす（下にカードが続くとき用）。
  final bool fadeBottom;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final w = MediaQuery.sizeOf(context).width;
    // 透明なクリーム。単に Colors.transparent にすると白へ抜けて濁るため、
    // 地色と同じ色相のまま alpha だけ 0 にする。
    const clear = Color(0x00FBF6EA);
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Transform.scale(
            scale: zoom,
            alignment: const Alignment(0, 0.15),
            child: Image.asset(
              'assets/images/bg/home_stage.jpg',
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              // 表示解像度でデコードする。指定しないと端末に関係なく
              // フルサイズの GPU テクスチャが常駐する。
              cacheWidth: (w * dpr * 1.5).round(),
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  fadeTop ? AppColors.bg : clear,
                  clear,
                  clear,
                  fadeBottom ? AppColors.bg : clear,
                ],
                stops: const [0.0, 0.10, 0.86, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 風景の上に置く文字の座布団。
///
/// 背景が明るい空や鮮やかな草なので、濃い文字を直に置くとコントラストが足りない。
/// クリーム地を半透明で敷いて、文字は従来どおりの地の上に乗せる。
/// モックが吹き出しを使っているのは装飾ではなく、この可読性の担保。
class StageChip extends StatelessWidget {
  const StageChip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.88),
        borderRadius: AppRadius.lgR,
      ),
      child: child,
    );
  }
}

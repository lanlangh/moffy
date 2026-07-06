import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/egg_art.dart';
import '../../collection/domain/mofi_models.dart';
import '../domain/egg_models.dart';

/// 卵・Mofi のレアリティ色マッピング（DESIGN_SYSTEM §2-3 / 厳密統一）。
/// 色は必ず [RarityToken]（AppColors 経由）を使い、直書きしない。
abstract final class RarityVisuals {
  /// 卵レアリティ → レアリティ色帯。
  /// 卵は4段階（normal/rare/epic/legend）、色帯はMofiの4色に対応付ける。
  static RarityToken ofEgg(EggRarity rarity) => switch (rarity) {
        EggRarity.normal => RarityToken.common,
        EggRarity.rare => RarityToken.rare,
        EggRarity.epic => RarityToken.sr,
        EggRarity.legend => RarityToken.ssr,
      };

  /// Mofiレアリティ → レアリティ色帯。
  static RarityToken ofMofi(MofiRarity rarity) => switch (rarity) {
        MofiRarity.common => RarityToken.common,
        MofiRarity.rare => RarityToken.rare,
        MofiRarity.sr => RarityToken.sr,
        MofiRarity.ssr => RarityToken.ssr,
      };
}

/// 卵の被写体（本番イラスト / SCREEN_FLOWS §3）。
/// NestRing の中央に置く。レアリティ色帯ごとの透過イラストを [EggArt] で表示し、
/// 成長段階（[stage]）は孵化進捗に写してフォールバック時のヒビ段階に反映する。
class EggSubject extends StatelessWidget {
  const EggSubject({
    super.key,
    required this.rarity,
    required this.stage,
  });

  final EggRarity rarity;
  final EggGrowthStage stage;

  @override
  Widget build(BuildContext context) {
    // 段階 → 進捗（フォールバックのベクター描画のヒビ段階に使う・§4-5 のしきい値比）。
    final progress = switch (stage) {
      EggGrowthStage.intact => 0.0,
      EggGrowthStage.crack1 => 0.3,
      EggGrowthStage.crack2 => 0.6,
      EggGrowthStage.ready => 0.95,
    };
    return EggArt(rarity: RarityVisuals.ofEgg(rarity), progress: progress);
  }
}

/// Mofi の被写体アイコン（孵化結果・図鑑で使用）。
/// シルエット（未発見）と色違い（虹枠は呼び出し側）で見え方を変える。
class MofiSubject extends StatelessWidget {
  const MofiSubject({
    super.key,
    required this.speciesId,
    required this.family,
    required this.rarity,
    this.stage = 1,
    this.silhouette = false,
    this.isShiny = false,
  });

  /// 個体ID（'slime_01' 等）。イラストのファイル名に使う。
  final String speciesId;
  final MofiFamily family;
  final MofiRarity rarity;

  /// 進化段階（1=ベビー / 2=アダルト / docs/EVOLUTION.md）。イラスト差し替えに使う。
  final int stage;
  final bool silhouette;

  /// 色違い（shiny）。true のとき、まず手描きの本番色違いイラスト
  /// （mofi_<id>_<stage>_shiny.png）を表示し、未配置なら従来の色相回転フィルタに
  /// フォールバックする（アートが届いた個体・段階から自動で本物へ切り替わる）。
  final bool isShiny;

  @override
  Widget build(BuildContext context) {
    final color = silhouette
        ? AppColors.textDisabled
        : RarityVisuals.ofMofi(rarity).main;
    // 種族ごとのフォールバックアイコン（本番イラスト未配置・シルエット時）。
    final fallbackIcon = switch (family) {
      MofiFamily.slime => Icons.water_drop_rounded,
      MofiFamily.critter => Icons.pets_rounded,
      MofiFamily.dragon => Icons.local_fire_department_rounded,
      MofiFamily.beast => Icons.whatshot_rounded,
    };
    // NestRing の FittedBox は「子の本来サイズ」を枠に合わせて拡縮する。サイズ未指定の
    // Image は読込前 0×0 になり FittedBox が何も描かない（Mofiが消える）ため、EggArt と
    // 同じく確定サイズの箱で包む（フォールバック Icon も FittedBox で枠いっぱいに拡大）。
    const dimension = 120.0;
    final fallback = FittedBox(child: Icon(fallbackIcon, color: color));
    // 未発見はイラストを出さずシルエット（種族アイコンを textDisabled で）。
    if (silhouette) {
      return SizedBox.square(dimension: dimension, child: fallback);
    }
    // 本番イラスト（mofi_<id>_<stage>.png / 進化段階で差し替え）。未配置・読み込み失敗時は
    // 種族アイコンにフォールバック（アート未着でも動き、届いた分から自動で切り替わる）。
    final content = SizedBox.square(
      dimension: dimension,
      child: Image.asset(
        'assets/images/mofi/mofi_${speciesId}_$stage.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => fallback,
      ),
    );
    if (!isShiny) return content;
    // 色違い: まず手描きの本番色違いイラスト（mofi_<id>_<stage>_shiny.png）を表示する。
    // 未配置・読み込み失敗時は従来の色相回転フィルタにフォールバック（アートが届いた
    // 個体・段階から自動で本物へ切り替わる）。虹枠は呼び出し側の rimGradient が担当。
    // FittedBox の 0×0 描画消失を避けるため、通常絵と同じく確定サイズの箱で包む。
    return SizedBox.square(
      dimension: dimension,
      child: Image.asset(
        'assets/images/mofi/mofi_${speciesId}_${stage}_shiny.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        errorBuilder: (context, error, stack) => ColorFiltered(
          colorFilter: _shinyHueFilter(shinyHueDegFor(speciesId)),
          child: content,
        ),
      ),
    );
  }
}

/// 色違いの色相回転 ColorFilter（度）。PIL 見本と同一の feColorMatrix hue-rotate。
ColorFilter _shinyHueFilter(double deg) {
  final a = deg * math.pi / 180.0;
  final c = math.cos(a);
  final s = math.sin(a);
  return ColorFilter.matrix(<double>[
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715,
    0.072 - c * 0.072 + s * 0.928, 0, 0, //
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140,
    0.072 - c * 0.072 - s * 0.283, 0, 0, //
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715,
    0.072 + c * 0.928 + s * 0.072, 0, 0, //
    0, 0, 0, 1, 0,
  ]);
}

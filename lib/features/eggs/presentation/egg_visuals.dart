import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
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

/// 卵の被写体アイコン（成長段階でヒビ表現を変える / SCREEN_FLOWS §3）。
/// NestRing の中央に置く。色はレアリティ色帯。
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
    final color = RarityVisuals.ofEgg(rarity).main;
    // ヒビ段階に応じてアイコンを変える（孵化可能は割れかけ表現）。
    final icon = switch (stage) {
      EggGrowthStage.intact => Icons.egg_rounded,
      EggGrowthStage.crack1 => Icons.egg_rounded,
      EggGrowthStage.crack2 => Icons.egg_alt_rounded,
      EggGrowthStage.ready => Icons.egg_alt_outlined,
    };
    return Icon(icon, color: color);
  }
}

/// Mofi の被写体アイコン（孵化結果・図鑑で使用）。
/// シルエット（未発見）と色違い（虹枠は呼び出し側）で見え方を変える。
class MofiSubject extends StatelessWidget {
  const MofiSubject({
    super.key,
    required this.rarity,
    this.silhouette = false,
  });

  final MofiRarity rarity;
  final bool silhouette;

  @override
  Widget build(BuildContext context) {
    final color = silhouette
        ? AppColors.textDisabled
        : RarityVisuals.ofMofi(rarity).main;
    // MVPは個体イラスト未配置のため、丸い被写体アイコンで代替（後続でアセット差替）。
    return Icon(Icons.pets_rounded, color: color);
  }
}

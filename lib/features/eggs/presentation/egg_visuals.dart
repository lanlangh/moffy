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

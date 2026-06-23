/// 卵の育成・孵化まわりのドメインモデル（ARCHITECTURE §1-2 domain / S5,S6,S13）。
///
/// 信頼境界（ARCHITECTURE §0-2 / §2-3）:
///   * 成長pt加算・孵化確定・図鑑登録はサーバーRPC（`fn_apply_growth` / `fn_hatch_egg`）の
///     責務。クライアントは「結果を受け取って演出・表示する」だけ（抽選はサーバー）。
///   * 卵レアリティは入手時に確定し、孵化時は再抽選しない（S5）。
///   * 成長ptは卵ごとに保持。育成枠↔保管枠を移動しても失われない（S6）。
library;

import '../../../core/constants/economy.dart';
import '../../collection/domain/mofi_models.dart';

/// 卵レアリティ（migration: egg_rarity enum / §4-4）。
enum EggRarity {
  normal,
  rare,
  epic,
  legend;

  String get wire => name;

  static EggRarity fromWire(String s) => switch (s) {
        'rare' => EggRarity.rare,
        'epic' => EggRarity.epic,
        'legend' => EggRarity.legend,
        _ => EggRarity.normal,
      };

  String get label => switch (this) {
        EggRarity.normal => 'ノーマル',
        EggRarity.rare => 'レア',
        EggRarity.epic => 'エピック',
        EggRarity.legend => 'レジェンド',
      };
}

/// 卵の所在（migration: egg_location enum / S6）。
enum EggLocation { incubating, storage, hatched }

/// 卵の成長段階（§4-5: ヒビ①100 / ヒビ②250 / 孵化500）。
enum EggGrowthStage {
  /// 0〜99pt: ヒビなし。
  intact,

  /// 100〜249pt: ヒビ①。
  crack1,

  /// 250〜499pt: ヒビ②。
  crack2,

  /// 500pt〜: 孵化可能。
  ready;

  /// 表示ラベル（卵詳細のヒビ段階表示 / SCREEN_FLOWS §3）。
  String get label => switch (this) {
        EggGrowthStage.intact => 'たまご',
        EggGrowthStage.crack1 => 'ヒビ①',
        EggGrowthStage.crack2 => 'ヒビ②',
        EggGrowthStage.ready => '孵化可能',
      };

  /// 累積成長pt + 経済パラメータ（しきい値SSOT）から段階を判定する。
  /// しきい値は [EconomyParams.eggThresholds] 経由（マジックナンバー禁止 / ARCHITECTURE §0-1）。
  static EggGrowthStage of(int growthPoints, EconomyParams params) {
    final t = params.eggThresholds;
    if (growthPoints >= t.hatch) return EggGrowthStage.ready;
    if (growthPoints >= t.crack2) return EggGrowthStage.crack2;
    if (growthPoints >= t.crack1) return EggGrowthStage.crack1;
    return EggGrowthStage.intact;
  }
}

/// ユーザーの卵（migration: eggs）。
class Egg {
  final String id;
  final EggRarity rarity;

  /// 累積成長pt（§4-5: 100=ヒビ① / 250=ヒビ② / 500=孵化）。
  final int growthPoints;
  final EggLocation location;

  /// 育成枠スロット番号（1..3 / incubating のとき）。保管枠は null。
  final int? slotIndex;

  /// このユーザーで「いま加点される」アクティブ卵か（S6: 加点は1枠のみ）。
  final bool isActive;

  /// 入手元（'starter' / 'quest' / 'premium' / 'standard'）。
  final String acquiredSource;

  const Egg({
    required this.id,
    required this.rarity,
    required this.growthPoints,
    required this.location,
    required this.slotIndex,
    required this.isActive,
    required this.acquiredSource,
  });

  /// 成長段階（しきい値SSOT経由）。
  EggGrowthStage stage(EconomyParams params) =>
      EggGrowthStage.of(growthPoints, params);

  /// 孵化までの進捗 0.0〜1.0。
  double progress(EconomyParams params) {
    final hatch = params.eggThresholds.hatch;
    return hatch <= 0 ? 0 : (growthPoints / hatch).clamp(0.0, 1.0);
  }

  /// 孵化まで残りpt。
  int remaining(EconomyParams params) {
    final hatch = params.eggThresholds.hatch;
    return (hatch - growthPoints).clamp(0, hatch);
  }

  /// 孵化可能（500pt到達 / SCREEN_FLOWS §3）。
  bool canHatch(EconomyParams params) =>
      growthPoints >= params.eggThresholds.hatch;

  /// 孵化間近（巣リング微発光・残50pt以内 / SCREEN_FLOWS §2, S9と同基準）。
  bool isNearHatch(EconomyParams params) {
    final r = remaining(params);
    return r <= 50 && r > 0;
  }

  factory Egg.fromJson(Map<String, Object?> j) => Egg(
        id: j['id']! as String,
        rarity: EggRarity.fromWire(j['rarity']! as String),
        growthPoints: (j['growth_points'] as num?)?.toInt() ?? 0,
        location: switch (j['location']) {
          'incubating' => EggLocation.incubating,
          'hatched' => EggLocation.hatched,
          _ => EggLocation.storage,
        },
        slotIndex: (j['slot_index'] as num?)?.toInt(),
        isActive: j['is_active'] == true,
        acquiredSource: (j['acquired_source'] as String?) ?? 'standard',
      );

  Egg copyWith({
    EggLocation? location,
    int? slotIndex,
    bool? isActive,
    bool clearSlot = false,
  }) =>
      Egg(
        id: id,
        rarity: rarity,
        growthPoints: growthPoints,
        location: location ?? this.location,
        slotIndex: clearSlot ? null : (slotIndex ?? this.slotIndex),
        isActive: isActive ?? this.isActive,
        acquiredSource: acquiredSource,
      );
}

/// 孵化結果（サーバーRPC `fn_hatch_egg` が返す抽選結果 / S5,S13）。
///
/// クライアントは抽選しない。RPCが「レア→個体→色違い」を確定して返した値を
/// 受け取り、演出（色違いはキラリ演出）と図鑑登録の表示に使う（ARCHITECTURE §2-3）。
class HatchResult {
  /// 確定したMofi個体。
  final MofiSpecies species;

  /// 色違いか（独立2.0%判定の結果 / S13）。専用キラリ演出のトリガ。
  final bool isShiny;

  /// この孵化で図鑑が初めて埋まったか（達成演出/マイルストーン判定の補助）。
  final bool isNewDexEntry;

  /// 孵化元の卵ID（演出と整合確認用）。
  final String fromEggId;

  const HatchResult({
    required this.species,
    required this.isShiny,
    required this.isNewDexEntry,
    required this.fromEggId,
  });

  factory HatchResult.fromJson(Map<String, Object?> j) => HatchResult(
        species: MofiSpecies.fromJson(
          (j['species']! as Map).cast<String, Object?>(),
        ),
        isShiny: j['is_shiny'] == true,
        isNewDexEntry: j['is_new_dex_entry'] == true,
        fromEggId: j['from_egg_id']! as String,
      );
}

/// たまご画面の表示状態（育成3枠 + 保管枠 + プールpt / SCREEN_FLOWS §3）。
class EggsState {
  /// 育成枠（slotIndex 1..3）。null は空きスロット。
  final List<Egg?> incubatorSlots;

  /// 保管枠（無制限）。
  final List<Egg> storage;

  /// 空枠時にプールされたpt（S6 / 取りこぼし不安の解消表示）。
  final int pooledPoints;

  /// オフライン中か（孵化・通貨消費をグレーアウト / S8）。
  final bool isOffline;

  /// しきい値・上限の参照（SSOT）。
  final EconomyParams params;

  const EggsState({
    required this.incubatorSlots,
    required this.storage,
    required this.pooledPoints,
    required this.isOffline,
    required this.params,
  });

  /// 現在のアクティブ卵（加点対象 / S6: 最大1個）。無ければ null。
  Egg? get activeEgg {
    for (final e in incubatorSlots) {
      if (e != null && e.isActive) return e;
    }
    return null;
  }

  /// 育成枠が全て空（空枠誘導 / §5-2 空状態）。
  bool get hasNoIncubating => incubatorSlots.every((e) => e == null);

  /// 卵を1つも持っていない（保管も育成も空 → クエスト誘導 / SCREEN_FLOWS §3）。
  bool get isCompletelyEmpty =>
      hasNoIncubating && storage.isEmpty;

  /// 育成枠の総数（=3）。
  int get slotCount => incubatorSlots.length;
}

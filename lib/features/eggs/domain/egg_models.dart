/// 卵の育成・孵化まわりのドメインモデル（ARCHITECTURE §1-2 domain / S5,S6,S13）。
///
/// 信頼境界（ARCHITECTURE §0-2 / §2-3）:
///   * 成長pt加算・孵化確定・図鑑登録はサーバーRPC（`fn_apply_growth` / `fn_hatch_egg`）の
///     責務。クライアントは「結果を受け取って演出・表示する」だけ（抽選はサーバー）。
///   * 卵レアリティは入手時に確定し、孵化時は再抽選しない（S5）。
///   * 成長ptは卵ごとに保持。育成枠↔保管枠を移動しても失われない（S6）。
library;

import '../../../core/constants/economy.dart';
import '../../../core/widgets/egg_art.dart';
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

/// 保管枠が上限に達しているため保管できない（moveToStorage 時）。
///
/// サーバー（migration 0010 の storage_cap トリガーが送出する `storage_full`）と、Mock の
/// 上限チェックの双方が投げる。UI はこれを捕まえて「満杯（孵化 or プレミアムで拡張）」を
/// 案内する（無料20/プレミアム200 は実際に強制されており、この案内は事実に即す / 景表法）。
/// sealed [Failure] 階層には**加えない**（既存の網羅 switch を壊さない軽量例外）。
class StorageFullException implements Exception {
  const StorageFullException();

  @override
  String toString() => 'StorageFullException';
}

/// 卵の成長段階（0018 / 5段階: 0 / 100 / 200 / 300 / 500pt）。
///
/// 区切りは [EggThresholds.stages]（`app_config.egg_thresholds.stages` / SSOT）から決める。
/// 以前の4値（intact / crack1 / crack2 / ready）は「ヒビなし → ヒビが伸びる」の実質2段階で、
/// 日ごとの違いが見えなかった（docs/design/EGG_PACING_DESIGN.md §4）。
enum EggGrowthStage {
  /// S1 しろいたまご（0〜99pt）。何が生まれるか分からない＝レア度を隠す。
  blank,

  /// S2 もよう（100〜199pt）。レア度の色と模様が浮かぶ。
  pattern,

  /// S3 ヒビ（200〜299pt）。
  crack,

  /// S4 ひかり（300〜499pt）。400pt から光が強まる（[EggGrowthStage.isStrongGlow]）。
  glow,

  /// S5 うまれる！（500pt〜）。孵化可能。
  ready;

  /// 表示ラベル（吹き出し・卵詳細の段階表示）。
  String get label => switch (this) {
        EggGrowthStage.blank => '白い卵',
        EggGrowthStage.pattern => '模様',
        EggGrowthStage.crack => 'ヒビ',
        EggGrowthStage.glow => '光',
        EggGrowthStage.ready => '孵化',
      };

  /// 段階が上がった瞬間のひとこと（§4-2）。
  String get stageUpLine => switch (this) {
        EggGrowthStage.blank => '何が生まれるかな？',
        EggGrowthStage.pattern => '模様が浮かんできた！',
        EggGrowthStage.crack => 'ピキッ！',
        EggGrowthStage.glow => 'ヒビから光が…もうすぐ生まれそう',
        EggGrowthStage.ready => '孵化できます！',
      };

  /// レア度を隠す段階か（S1 は「なぞのたまご」）。
  bool get hidesRarity => this == EggGrowthStage.blank;

  /// 見た目（[EggArt] に渡す段階）。S4 は [strong] で「強まる」に切り替わる。
  EggLook look({bool strong = false}) => switch (this) {
        EggGrowthStage.blank => EggLook.blank,
        EggGrowthStage.pattern => EggLook.pattern,
        EggGrowthStage.crack => EggLook.crack,
        EggGrowthStage.glow => strong ? EggLook.glowStrong : EggLook.glow,
        EggGrowthStage.ready => EggLook.ready,
      };

  /// 累積成長pt ＋ しきい値（SSOT）から段階を判定する。
  ///
  /// `stages` の長さが 5 でない設定でも落ちない: 先頭＝blank、末尾＝ready、
  /// 間は順に pattern / crack / glow へ割り当てる（余れば glow）。
  static EggGrowthStage fromThresholds(int growthPoints, EggThresholds t) {
    final idx = t.stageIndexOf(growthPoints);
    final last = t.stages.length - 1;
    if (idx >= last) return EggGrowthStage.ready;
    if (idx <= 0) return EggGrowthStage.blank;
    return switch (idx) {
      1 => EggGrowthStage.pattern,
      2 => EggGrowthStage.crack,
      _ => EggGrowthStage.glow,
    };
  }

  /// [fromThresholds] の経済パラメータ版。
  static EggGrowthStage of(int growthPoints, EconomyParams params) =>
      fromThresholds(growthPoints, params.eggThresholds);

  /// S4 の「強まる」（400pt〜 / [EggThresholds.glowStrongAt]）か。
  static bool isStrongGlow(int growthPoints, EggThresholds t) =>
      fromThresholds(growthPoints, t) == EggGrowthStage.glow &&
      growthPoints >= t.glowStrongAt;

  /// 「最後に見た段階」として端末に保存する値（0..5 / [EggLook.step] と同じ）。
  /// S4 の「強まる」も 1 段として数える（§4-3）。
  static int visualStep(int growthPoints, EggThresholds t) =>
      fromThresholds(growthPoints, t)
          .look(strong: isStrongGlow(growthPoints, t))
          .step;
}

/// ユーザーの卵（migration: eggs）。
class Egg {
  final String id;
  final EggRarity rarity;

  /// 累積成長pt（0018: 0/100/200/300 で段階が変わり、500 で孵化）。
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

  /// S4 の「強まる」か。
  bool isStrongGlow(EconomyParams params) =>
      EggGrowthStage.isStrongGlow(growthPoints, params.eggThresholds);

  /// 見た目（[EggArt] 用）。
  EggLook look(EconomyParams params) =>
      stage(params).look(strong: isStrongGlow(params));

  /// 「最後に見た段階」の値（0..5）。
  int visualStep(EconomyParams params) =>
      EggGrowthStage.visualStep(growthPoints, params.eggThresholds);

  /// 孵化までの進捗 0.0〜1.0。
  double progress(EconomyParams params) {
    final hatch = params.eggThresholds.hatch;
    return hatch <= 0 ? 0 : (growthPoints / hatch).clamp(0.0, 1.0);
  }

  /// いまの段階の中での進捗 0.0〜1.0（進捗バー用 / §4-5）。
  double stageProgress(EconomyParams params) =>
      params.eggThresholds.stageProgressOf(growthPoints);

  /// つぎの変化まで残りpt（孵化可能なら 0）。
  int remainingToNextStage(EconomyParams params) =>
      params.eggThresholds.remainingToNextStage(growthPoints);

  /// 孵化まで残りpt。
  int remaining(EconomyParams params) {
    final hatch = params.eggThresholds.hatch;
    return (hatch - growthPoints).clamp(0, hatch);
  }

  /// 孵化可能（500pt到達 / SCREEN_FLOWS §3）。
  bool canHatch(EconomyParams params) =>
      growthPoints >= params.eggThresholds.hatch;

  /// 孵化間近（巣リング微発光のトリガ / SCREEN_FLOWS §2）。
  /// 0018: 残50pt ではなく **S4 の「強まる」（400pt〜）** に置き換えた（§4-2）。
  bool isNearHatch(EconomyParams params) =>
      isStrongGlow(params) && !canHatch(params);

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

  factory HatchResult.fromJson(Map<String, Object?> j) {
    final parsed = MofiSpecies.fromJson(
      (j['species']! as Map).cast<String, Object?>(),
    );
    // 🔴 名前だけはサーバーの返事を使わず、**アプリ内の [kMofiSpeciesSeed] で引き直す**。
    //
    // なぜ（2026-08-20 に実機直前で発覚）:
    //   * `fn_hatch_egg` が返す species は id/family/rarity/name/sort_order の5つだけで、
    //     **evolved_name を含まない**。そのまま使うと [MofiSpecies.evolvedName] が常に null になり、
    //     [MofiSpecies.nameForStage] が進化後でも進化前の名前へ倒れる。
    //     ＝ このリリースの目玉「進化すると名前が変わる」が、孵化まわりで**一度も出ない**。
    //   * さらに DB の name は改名前のまま（例: dragon_03 = 'らいりゅう'）。図鑑はアプリ内リスト
    //     由来で 'らいむ' を出すので、**孵化演出と図鑑で名前が食い違う**。
    //
    // 図鑑側（[CollectionRepository]）は元から kMofiSpeciesSeed から組んでいる。
    // ここを揃えることで、名前の出どころがアプリ内の1箇所に統一される。
    //
    // 抽選・図鑑登録の信頼境界は動かない（何が出たかを決めるのは今もサーバー。
    // ここで差し替えるのは **同じ id の表示名だけ**）。
    // 未知の id が来たらサーバーの値へ倒すので、種を追加しても壊れない。
    final species = kMofiSpeciesSeed.firstWhere(
      (s) => s.id == parsed.id,
      orElse: () => parsed,
    );
    return HatchResult(
      species: species,
      isShiny: j['is_shiny'] == true,
      isNewDexEntry: j['is_new_dex_entry'] == true,
      fromEggId: j['from_egg_id']! as String,
    );
  }
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
  bool get isCompletelyEmpty => hasNoIncubating && storage.isEmpty;

  /// 育成枠の総数（=3）。
  int get slotCount => incubatorSlots.length;

  /// The first empty incubator slot as a 1-based index, or null when full.
  int? get firstEmptySlotIndex {
    final index = incubatorSlots.indexWhere((egg) => egg == null);
    return index < 0 ? null : index + 1;
  }
}

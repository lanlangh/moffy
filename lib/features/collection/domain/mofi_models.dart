/// 図鑑（Mofi）まわりのドメインモデル（ARCHITECTURE §1-2 domain / S5,S13）。
///
/// 信頼境界（ARCHITECTURE §0-2）:
///   * Mofi個体マスタ（[MofiSpecies]）は `mofi_species` テーブルの読み取り公開データ。
///     真のSSOTはサーバー。本ファイルの [kMofiSpeciesSeed] は
///     `supabase/migrations/0001_init.sql` の seed と1:1で一致させた
///     オフライン/起動直後フォールバック。値を変えるときは migration も必ず合わせる。
///   * 図鑑登録（[MofiCollectionEntry]）はサーバーRPC `fn_hatch_egg` のみが書き込む
///     （クライアントは読み取りのみ / RLS で封鎖）。本モデルは表示用。
library;

/// Mofiレアリティ（migration: mofi_rarity enum）。
enum MofiRarity {
  common,
  rare,
  sr,
  ssr;

  /// DB enum / jsonb との相互変換。
  String get wire => name;

  static MofiRarity fromWire(String s) => switch (s) {
        'rare' => MofiRarity.rare,
        'sr' => MofiRarity.sr,
        'ssr' => MofiRarity.ssr,
        _ => MofiRarity.common,
      };

  /// 図鑑フィルタ等の表示ラベル。
  String get label => switch (this) {
        MofiRarity.common => 'Common',
        MofiRarity.rare => 'Rare',
        MofiRarity.sr => 'SR',
        MofiRarity.ssr => 'SSR',
      };
}

/// 種族（migration: mofi_family enum）。
enum MofiFamily {
  slime,
  critter,
  dragon;

  String get wire => name;

  static MofiFamily fromWire(String s) => switch (s) {
        'critter' => MofiFamily.critter,
        'dragon' => MofiFamily.dragon,
        _ => MofiFamily.slime,
      };

  /// 表示名（日本語）。
  String get label => switch (this) {
        MofiFamily.slime => 'スライム',
        MofiFamily.critter => '小動物',
        MofiFamily.dragon => 'ドラゴン',
      };
}

/// Mofi個体マスタ（§4-1 / mofi_species）。レアリティは個体ごと固定（S5）。
class MofiSpecies {
  /// 安定キー（'slime_01' 等）。
  final String id;
  final MofiFamily family;
  final MofiRarity rarity;
  final String name;
  final int sortOrder;

  const MofiSpecies({
    required this.id,
    required this.family,
    required this.rarity,
    required this.name,
    required this.sortOrder,
  });

  factory MofiSpecies.fromJson(Map<String, Object?> j) => MofiSpecies(
        id: j['id']! as String,
        family: MofiFamily.fromWire(j['family']! as String),
        rarity: MofiRarity.fromWire(j['rarity']! as String),
        name: j['name']! as String,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// §4-1 Mofi個体マスタ 15種（migration 0001_init.sql の seed と一致）。
/// スライム: C2/R2/SR1 / 小動物: C2/R2/SSR1 / ドラゴン: C1/R1/SR2/SSR1。
const List<MofiSpecies> kMofiSpeciesSeed = [
  MofiSpecies(id: 'slime_01', family: MofiFamily.slime, rarity: MofiRarity.common, name: 'ぷるりん', sortOrder: 1),
  MofiSpecies(id: 'slime_02', family: MofiFamily.slime, rarity: MofiRarity.common, name: 'もちすら', sortOrder: 2),
  MofiSpecies(id: 'slime_03', family: MofiFamily.slime, rarity: MofiRarity.rare, name: 'きらすら', sortOrder: 3),
  MofiSpecies(id: 'slime_04', family: MofiFamily.slime, rarity: MofiRarity.rare, name: 'にじすら', sortOrder: 4),
  MofiSpecies(id: 'slime_05', family: MofiFamily.slime, rarity: MofiRarity.sr, name: 'しずくおう', sortOrder: 5),
  MofiSpecies(id: 'critter_01', family: MofiFamily.critter, rarity: MofiRarity.common, name: 'ころみ', sortOrder: 6),
  MofiSpecies(id: 'critter_02', family: MofiFamily.critter, rarity: MofiRarity.common, name: 'ぽてうさ', sortOrder: 7),
  MofiSpecies(id: 'critter_03', family: MofiFamily.critter, rarity: MofiRarity.rare, name: 'まめきつ', sortOrder: 8),
  MofiSpecies(id: 'critter_04', family: MofiFamily.critter, rarity: MofiRarity.rare, name: 'ふわりす', sortOrder: 9),
  MofiSpecies(id: 'critter_05', family: MofiFamily.critter, rarity: MofiRarity.ssr, name: 'こんげつ', sortOrder: 10),
  MofiSpecies(id: 'dragon_01', family: MofiFamily.dragon, rarity: MofiRarity.common, name: 'とかげり', sortOrder: 11),
  MofiSpecies(id: 'dragon_02', family: MofiFamily.dragon, rarity: MofiRarity.rare, name: 'ほのおこ', sortOrder: 12),
  MofiSpecies(id: 'dragon_03', family: MofiFamily.dragon, rarity: MofiRarity.sr, name: 'らいりゅう', sortOrder: 13),
  MofiSpecies(id: 'dragon_04', family: MofiFamily.dragon, rarity: MofiRarity.sr, name: 'こおりば', sortOrder: 14),
  MofiSpecies(id: 'dragon_05', family: MofiFamily.dragon, rarity: MofiRarity.ssr, name: 'てんりゅう', sortOrder: 15),
];

/// 図鑑エントリ（= マスタ個体 × 色違い有無）。図鑑総数30はこの組み合わせ（S13）。
class MofiDexEntry {
  final MofiSpecies species;
  final bool isShiny;

  /// このユーザーが発見済みか（未発見はシルエット表示 / SCREEN_FLOWS §4）。
  final bool discovered;

  /// 発見日時（未発見は null）。図鑑詳細の表示項目。
  final DateTime? discoveredAt;

  /// 同一個体を引いた累計回数（重複は別行ではなくカウント / migration uq_collection_dex）。
  final int obtainedCount;

  const MofiDexEntry({
    required this.species,
    required this.isShiny,
    required this.discovered,
    this.discoveredAt,
    this.obtainedCount = 0,
  });

  /// 図鑑内の一意キー（species_id × shiny）。
  String get dexKey => '${species.id}:${isShiny ? 'shiny' : 'normal'}';

  /// 進化段階（1=ベビー / 2=アダルト / docs/EVOLUTION.md）。重複入手数
  /// [obtainedCount] が [stage2Count] 以上でアダルト。未発見は 1（表示はシルエット）。
  /// [obtainedCount] はサーバー専管の値なので、この段階は偽装できない（改ざん耐性維持）。
  int evolutionStage(int stage2Count) =>
      (discovered && obtainedCount >= stage2Count) ? 2 : 1;

  /// 次の進化まであと何体か。進化済み/未発見/しきい値≤1 は 0。
  int toNextEvolution(int stage2Count) {
    if (!discovered || stage2Count <= 1 || obtainedCount >= stage2Count) {
      return 0;
    }
    return stage2Count - obtainedCount;
  }
}

/// 図鑑全体のスナップショット（達成率算出 / SCREEN_FLOWS §4）。
class CollectionState {
  /// 30エントリ（発見/未発見すべて）。sortOrder × 色違いで安定順。
  final List<MofiDexEntry> entries;

  /// コンプ率の分母（app_config.dex_total_entries = 30）。
  final int totalEntries;

  /// オフライン中か（キャッシュ表示 + 上端バー / S8）。
  final bool isOffline;

  /// 進化アダルト化の重複しきい値（EconomyParams由来 / docs/EVOLUTION.md）。
  final int evolveStage2Count;

  const CollectionState({
    required this.entries,
    required this.totalEntries,
    required this.isOffline,
    this.evolveStage2Count = 3,
  });

  /// 発見済みエントリ数（達成率の分子）。
  int get discoveredCount => entries.where((e) => e.discovered).length;

  /// 達成率 0.0〜1.0。
  double get completionRatio =>
      totalEntries <= 0 ? 0 : (discoveredCount / totalEntries).clamp(0.0, 1.0);

  /// 1体も発見していない（空状態 / SCREEN_FLOWS §4）。
  bool get isEmpty => discoveredCount == 0;
}

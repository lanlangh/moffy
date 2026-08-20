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
  dragon,
  beast;

  String get wire => name;

  static MofiFamily fromWire(String s) => switch (s) {
        'critter' => MofiFamily.critter,
        'dragon' => MofiFamily.dragon,
        'beast' => MofiFamily.beast,
        _ => MofiFamily.slime,
      };

  /// 表示名（日本語）。
  String get label => switch (this) {
        MofiFamily.slime => 'スライム',
        MofiFamily.critter => '小動物',
        MofiFamily.dragon => 'ドラゴン',
        MofiFamily.beast => '獣',
      };
}

/// Mofi個体マスタ（§4-1 / mofi_species）。レアリティは個体ごと固定（S5）。
class MofiSpecies {
  /// 安定キー（'slime_01' 等）。
  final String id;
  final MofiFamily family;
  final MofiRarity rarity;
  final String name;

  /// 進化後（stage 2）の名前。null なら [name] をそのまま使う。
  ///
  /// なぜ別名にするか（オーナー判断 2026-08-19）:
  ///   収集ゲームで進化して名前が変わらないのは不自然。
  ///   進化前は略した子ども言葉（ぽてうさ・とかげり）なので、
  ///   進化後は正式な形や称号へ伸ばす（ぽてうさぎ・とかげりゅう）。
  ///
  /// サーバー（mofi_species.evolved_name）が真の情報源。未設定なら name に倒れるので、
  /// **DB へ適用する前でもアプリは壊れない**（段階的に反映できる）。
  final String? evolvedName;

  /// 表示する段階に応じた名前。stage 2 かつ [evolvedName] があればそちら。
  String nameForStage(int stage) =>
      (stage >= 2 && evolvedName != null && evolvedName!.isNotEmpty)
          ? evolvedName!
          : name;
  final int sortOrder;

  const MofiSpecies({
    required this.id,
    required this.family,
    required this.rarity,
    required this.name,
    required this.sortOrder,
    this.evolvedName,
  });

  factory MofiSpecies.fromJson(Map<String, Object?> j) => MofiSpecies(
        id: j['id']! as String,
        family: MofiFamily.fromWire(j['family']! as String),
        rarity: MofiRarity.fromWire(j['rarity']! as String),
        name: j['name']! as String,
        evolvedName: j['evolved_name'] as String?,
        sortOrder: (j['sort_order'] as num?)?.toInt() ?? 0,
      );
}

/// §4-1 Mofi個体マスタ 20種（migration 0001+0008 の seed と一致）。
/// スライム: C2/R2/SR1 / 小動物: C2/R2/SSR1 / ドラゴン: C1/R1/SR2/SSR1 /
/// 獣(かっこいい枠): C2/R1/SR1/SSR1。合計 C7/R6/SR4/SSR3。
const List<MofiSpecies> kMofiSpeciesSeed = [
  MofiSpecies(id: 'slime_01', family: MofiFamily.slime, rarity: MofiRarity.common, name: 'ぷるりん', sortOrder: 1, evolvedName: 'プルミエ'),
  MofiSpecies(id: 'slime_02', family: MofiFamily.slime, rarity: MofiRarity.common, name: 'もちすら', sortOrder: 2, evolvedName: 'モチルド'),
  MofiSpecies(id: 'slime_03', family: MofiFamily.slime, rarity: MofiRarity.rare, name: 'きらすら', sortOrder: 3, evolvedName: 'キラーレ'),
  MofiSpecies(id: 'slime_04', family: MofiFamily.slime, rarity: MofiRarity.rare, name: 'にじすら', sortOrder: 4, evolvedName: 'ニジェンテ'),
  MofiSpecies(id: 'slime_05', family: MofiFamily.slime, rarity: MofiRarity.sr, name: 'しずくおう', sortOrder: 5, evolvedName: 'シズクレイ'),
  MofiSpecies(id: 'critter_01', family: MofiFamily.critter, rarity: MofiRarity.common, name: 'ころみ', sortOrder: 6, evolvedName: 'コロミナ'),
  MofiSpecies(id: 'critter_02', family: MofiFamily.critter, rarity: MofiRarity.common, name: 'ぽてうさ', sortOrder: 7, evolvedName: 'ポテラビス'),
  MofiSpecies(id: 'critter_03', family: MofiFamily.critter, rarity: MofiRarity.rare, name: 'まめきつ', sortOrder: 8, evolvedName: 'マメキーゼ'),
  MofiSpecies(id: 'critter_04', family: MofiFamily.critter, rarity: MofiRarity.rare, name: 'ふわりす', sortOrder: 9, evolvedName: 'フワリスタ'),
  MofiSpecies(id: 'critter_05', family: MofiFamily.critter, rarity: MofiRarity.ssr, name: 'こんげつ', sortOrder: 10, evolvedName: 'コンルナ'),
  MofiSpecies(id: 'dragon_01', family: MofiFamily.dragon, rarity: MofiRarity.common, name: 'とかげり', sortOrder: 11, evolvedName: 'トカゲイル'),
  MofiSpecies(id: 'dragon_02', family: MofiFamily.dragon, rarity: MofiRarity.rare, name: 'ほのおこ', sortOrder: 12, evolvedName: 'ホノーガ'),
  MofiSpecies(id: 'dragon_03', family: MofiFamily.dragon, rarity: MofiRarity.sr, name: 'らいりゅう', sortOrder: 13, evolvedName: 'ライドール'),
  MofiSpecies(id: 'dragon_04', family: MofiFamily.dragon, rarity: MofiRarity.sr, name: 'こおりば', sortOrder: 14, evolvedName: 'コオリバル'),
  MofiSpecies(id: 'dragon_05', family: MofiFamily.dragon, rarity: MofiRarity.ssr, name: 'てんりゅう', sortOrder: 15, evolvedName: 'テンドラ'),
  // 獣（beast）＝“かっこいい”枠（男性ユーザー訴求 / 0007 で追加）。
  MofiSpecies(id: 'beast_01', family: MofiFamily.beast, rarity: MofiRarity.common, name: 'とらまる', sortOrder: 16, evolvedName: 'トラガル'),
  MofiSpecies(id: 'beast_02', family: MofiFamily.beast, rarity: MofiRarity.common, name: 'うるが', sortOrder: 17, evolvedName: 'ウルガン'),
  MofiSpecies(id: 'beast_03', family: MofiFamily.beast, rarity: MofiRarity.rare, name: 'れおん', sortOrder: 18, evolvedName: 'レオンド'),
  MofiSpecies(id: 'beast_04', family: MofiFamily.beast, rarity: MofiRarity.sr, name: 'くろば', sortOrder: 19, evolvedName: 'クロバルド'),
  MofiSpecies(id: 'beast_05', family: MofiFamily.beast, rarity: MofiRarity.ssr, name: 'びゃっこ', sortOrder: 20, evolvedName: 'ビャクレン'),
];

/// 色違い（shiny）の色相回転角（度 / クライアント表示のみ・追加アート不要）。
/// 既定は 150°（承認済みのスライム/虎の見た目）。色相回転が似合わないキャラだけ、
/// ここに `species_id: 角度` を足して個別上書きする（ユーザー確認後に微調整）。
const Map<String, double> kShinyHueOverride = <String, double>{
  // 例: 'critter_01': 300, 'dragon_02': 210, ... （確認後に追記）
};

/// 個体IDの色違い色相回転角（未指定は既定150°）。
double shinyHueDegFor(String speciesId) => kShinyHueOverride[speciesId] ?? 150;

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
  /// 40エントリ（発見/未発見すべて）。sortOrder × 色違いで安定順。
  final List<MofiDexEntry> entries;

  /// コンプ率の分母（app_config.dex_total_entries = 40）。
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

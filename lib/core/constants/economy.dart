/// 経済パラメータ（クライアント表示用デフォルト / 単一情報源の「初期値」）。
///
/// 重要（ARCHITECTURE §0-1 / 信頼境界）:
///   * 経済値の「真のSSOT（信頼できる唯一の情報源）」は Supabase の `app_config` /
///     `drop_tables`。本番では `remoteConfigProvider` がそこから取得した値を使う。
///   * 本ファイルは「リモート取得が未完了の起動直後」や「オフライン初回」に使う
///     フォールバックのデフォルトであり、`supabase/migrations/0001_init.sql` の
///     seed 値と一致させてある。値を変えるときは migration 側も必ず合わせる。
///   * 抽選確率（drop_tables）はサーバー側で抽選するため、ここには「表示用の参照値」
///     としてのみ持つ（クライアントは抽選しない / ARCHITECTURE §2-3）。
///   * いかなる計算ロジックにもマジックナンバーを直書きしない。必ずこの定数を参照する。
library;

/// ポイント・成長に関する経済パラメータ。
///
/// `app_config` の各キーに 1:1 対応する。`EconomyParams.fromConfig` で
/// リモート値からも構築できるようにし、UI / PointCalculator は本型のみ参照する。
class EconomyParams {
  /// §4-5 換算レート: 1分削減 = 1pt。
  final int pointPerMinute;

  /// S4 1日ポイント上限。倍率適用後の最終値で判定。
  final int dailyPointCap;

  /// §4-5 基準値の下限クランプ（分）。低利用ユーザーが0ptで詰むのを防ぐ（S2）。
  final int baselineFloorMinutes;

  /// S11 基準値 = 本日除く直近N日平均（欠損日除外）。
  final int baselineWindowDays;

  /// §4-5 卵成長しきい値（累積pt）。
  final EggThresholds eggThresholds;

  /// S1 初回ボーナス卵への自動付与（合計500ptで孵化保証）。
  final WarmupGrants warmupGrants;

  /// S14 ストリーク倍率（基礎ptのみ適用）。日数昇順。間の日数は直下段を適用。
  final List<StreakTier> streakMultipliers;

  /// S13 色違い出現率（1/50 = 0.02）。表示用（抽選はサーバー）。
  final double shinyRate;

  /// S6 アクティブ卵不在時のpt最大プール日数。
  final int pooledPointsMaxDays;

  /// S13 図鑑総エントリー数（15種×2色）。コンプ率の分母。
  final int dexTotalEntries;

  const EconomyParams({
    required this.pointPerMinute,
    required this.dailyPointCap,
    required this.baselineFloorMinutes,
    required this.baselineWindowDays,
    required this.eggThresholds,
    required this.warmupGrants,
    required this.streakMultipliers,
    required this.shinyRate,
    required this.pooledPointsMaxDays,
    required this.dexTotalEntries,
  });

  /// 起動直後/オフライン用のデフォルト（migration seed と一致）。
  static const EconomyParams defaults = EconomyParams(
    pointPerMinute: 1,
    dailyPointCap: 480,
    baselineFloorMinutes: 30,
    baselineWindowDays: 7,
    eggThresholds: EggThresholds.defaults,
    warmupGrants: WarmupGrants.defaults,
    streakMultipliers: StreakTier.defaults,
    shinyRate: 0.02,
    pooledPointsMaxDays: 3,
    dexTotalEntries: 30,
  );

  /// `app_config` から取得した key->value(jsonbデコード済み) マップで構築する。
  /// 欠損キーは [defaults] にフォールバックする（信頼性: リモート不整合で落とさない）。
  factory EconomyParams.fromConfig(Map<String, Object?> config) {
    const d = EconomyParams.defaults;
    return EconomyParams(
      pointPerMinute: _asInt(config['point_per_minute']) ?? d.pointPerMinute,
      dailyPointCap: _asInt(config['daily_point_cap']) ?? d.dailyPointCap,
      baselineFloorMinutes:
          _asInt(config['baseline_floor_min']) ?? d.baselineFloorMinutes,
      baselineWindowDays:
          _asInt(config['baseline_window_days']) ?? d.baselineWindowDays,
      eggThresholds: config['egg_thresholds'] is Map
          ? EggThresholds.fromJson(
              (config['egg_thresholds']! as Map).cast<String, Object?>(),
            )
          : d.eggThresholds,
      warmupGrants: config['warmup_grants'] is Map
          ? WarmupGrants.fromJson(
              (config['warmup_grants']! as Map).cast<String, Object?>(),
            )
          : d.warmupGrants,
      streakMultipliers: config['streak_multipliers'] is List
          ? (config['streak_multipliers']! as List)
              .whereType<Map<dynamic, dynamic>>()
              .map((e) => StreakTier.fromJson(e.cast<String, Object?>()))
              .toList()
          : d.streakMultipliers,
      shinyRate: _asDouble(config['shiny_rate']) ?? d.shinyRate,
      pooledPointsMaxDays:
          _asInt(config['pooled_points_max_days']) ?? d.pooledPointsMaxDays,
      dexTotalEntries: _asInt(config['dex_total_entries']) ?? d.dexTotalEntries,
    );
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
  static double? _asDouble(Object? v) =>
      v is double ? v : (v is num ? v.toDouble() : double.tryParse('$v'));
}

/// §4-5 卵成長しきい値。
class EggThresholds {
  final int crack1; // ヒビ① = 100pt
  final int crack2; // ヒビ② = 250pt
  final int hatch; // 孵化 = 500pt（累積）

  const EggThresholds({
    required this.crack1,
    required this.crack2,
    required this.hatch,
  });

  static const EggThresholds defaults =
      EggThresholds(crack1: 100, crack2: 250, hatch: 500);

  factory EggThresholds.fromJson(Map<String, Object?> j) => EggThresholds(
        crack1: (j['crack1'] as num?)?.toInt() ?? defaults.crack1,
        crack2: (j['crack2'] as num?)?.toInt() ?? defaults.crack2,
        hatch: (j['hatch'] as num?)?.toInt() ?? defaults.hatch,
      );
}

/// S1 初回ボーナス卵への自動付与。
class WarmupGrants {
  final int day1; // 200pt
  final int day2; // 300pt

  const WarmupGrants({required this.day1, required this.day2});

  static const WarmupGrants defaults = WarmupGrants(day1: 200, day2: 300);

  factory WarmupGrants.fromJson(Map<String, Object?> j) => WarmupGrants(
        day1: (j['day1'] as num?)?.toInt() ?? defaults.day1,
        day2: (j['day2'] as num?)?.toInt() ?? defaults.day2,
      );
}

/// S14 ストリーク倍率の1段。
class StreakTier {
  final int days; // 達成日数の下限
  final double mult; // 倍率

  const StreakTier({required this.days, required this.mult});

  /// 連続達成 [streakDays] に対して適用される倍率を返す。
  /// 間の日数はその直下の段を適用（例 5日目=×1.2 / S14）。
  static double multiplierFor(int streakDays, List<StreakTier> tiers) {
    var applied = 1.0;
    for (final t in tiers) {
      if (streakDays >= t.days) {
        applied = t.mult;
      } else {
        break; // 昇順前提
      }
    }
    return applied;
  }

  static const List<StreakTier> defaults = [
    StreakTier(days: 1, mult: 1.0),
    StreakTier(days: 3, mult: 1.2),
    StreakTier(days: 7, mult: 1.5),
    StreakTier(days: 30, mult: 2.0),
  ];

  factory StreakTier.fromJson(Map<String, Object?> j) => StreakTier(
        days: (j['days'] as num?)?.toInt() ?? 1,
        mult: (j['mult'] as num?)?.toDouble() ?? 1.0,
      );
}

/// 不変の構造定数（リモート化しないもの / ARCHITECTURE: app_constants 相当）。
class AppConstants {
  AppConstants._();

  /// Supabase Platform Channel 名（ネイティブ利用統計取得）。Kotlin側と一致必須。
  static const String usageChannel = 'com.moffy/usage_stats';

  /// S3 MVP対象4SNS（Android）。真のSSOTは app_config.target_packages_android。
  /// ここは起動直後のフォールバック・表示ラベルの対応付け用。
  static const List<TrackedAppDef> defaultAndroidTargets = [
    TrackedAppDef(packageName: 'com.zhiliaoapp.musically', label: 'TikTok'),
    TrackedAppDef(packageName: 'com.instagram.android', label: 'Instagram'),
    TrackedAppDef(packageName: 'com.google.android.youtube', label: 'YouTube'),
    TrackedAppDef(packageName: 'com.twitter.android', label: 'X'),
  ];
}

/// 対象アプリ定義（パッケージ名 + 表示ラベル）。
class TrackedAppDef {
  final String packageName;
  final String label;
  const TrackedAppDef({required this.packageName, required this.label});
}

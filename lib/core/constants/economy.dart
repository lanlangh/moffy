/// 経済パラメータ（クライアント表示用デフォルト / 単一情報源の「初期値」）。
///
/// 重要（ARCHITECTURE §0-1 / 信頼境界）:
///   * 経済値の「真のSSOT（信頼できる唯一の情報源）」は Supabase の `app_config` /
///     `drop_tables`。本番では `remoteConfigProvider` がそこから取得した値を使う。
///   * 本ファイルは「リモート取得が未完了の起動直後」や「オフライン初回」に使う
///     フォールバックのデフォルトであり、`supabase/migrations/0001_init.sql` と
///     `0018_egg_pacing_bands.sql` の seed 値と一致させてある。値を変えるときは migration 側も必ず合わせる。
///   * 抽選確率（drop_tables）はサーバー側で抽選するため、ここには「表示用の参照値」
///     としてのみ持つ（クライアントは抽選しない / ARCHITECTURE §2-3）。
///   * いかなる計算ロジックにもマジックナンバーを直書きしない。必ずこの定数を参照する。
///
/// 【2026-10-21 / 0018】ポイントの数え方を「前の週より何分減らしたか」から
///   「ふだんよりどれだけ離れていたか（◎/○/△）」へ変えた（docs/design/EGG_PACING_DESIGN.md）。
///   基準値（直近7日平均・下限クランプ）と連続倍率は**使わない**。フィールドは `app_config` の
///   キーと 1:1 で残してあるが、新しい計算は [dailyBands] / [usualMinutesDefault] /
///   [EggThresholds.stages] を見る。
library;

/// ポイント・成長に関する経済パラメータ。
///
/// `app_config` の各キーに 1:1 対応する。`EconomyParams.fromConfig` で
/// リモート値からも構築できるようにし、UI / 計算は本型のみ参照する。
class EconomyParams {
  /// §4-5 換算レート: 1分削減 = 1pt。**0018 以降は計算に使わない**（キー互換のため残す）。
  final int pointPerMinute;

  /// S4 1日ポイント上限。0018: ◎の 100pt と同値。
  final int dailyPointCap;

  /// §4-5 基準値の下限クランプ（分）。**0018 以降は計算に使わない**（キー互換のため残す）。
  final int baselineFloorMinutes;

  /// S11 直近N日。0018 では「R を実測で上方修正する母数（計測ありの確定日が N 日）」として使う。
  final int baselineWindowDays;

  /// §4-5 卵成長しきい値（累積pt）と 5段階の区切り。
  final EggThresholds eggThresholds;

  /// S1 初回ボーナス（0018: 1日目 300 / 2日目は初回ボーナス卵が無いときの値 200）。
  final WarmupGrants warmupGrants;

  /// S14 ストリーク倍率。0018 で廃止（全段 ×1.0）。連続日数の表示とクエストは残る。
  final List<StreakTier> streakMultipliers;

  /// S13 色違い出現率（1/50 = 0.02）。表示用（抽選はサーバー）。
  final double shinyRate;

  /// S6 アクティブ卵不在時のpt最大プール日数。
  final int pooledPointsMaxDays;

  /// S13 図鑑総エントリー数（20種×2色）。コンプ率の分母。
  final int dexTotalEntries;

  /// Mofi進化(v1.0 / docs/EVOLUTION.md): アダルトに進化する重複入手数（既定3）。
  /// `app_config.mofi_evolve_stage2_count` で上書き可（未設定＝3）。進化段階は
  /// この値と `mofi_collection.obtained_count`（サーバー専管）から算出する表示ロジック。
  final int mofiEvolveStage2Count;

  /// 0018: 1日の評価（◎/○/△）の条件と、評価ごとに卵へ入る pt。
  final DailyBands dailyBands;

  /// 0018: 未申告ユーザーの「ふだんのSNS時間」（分）。
  final int usualMinutesDefault;

  /// 0018: 「ふだんのSNS時間」の選択肢（分 / iOS のしきい値と同じ刻み）。
  final List<int> usualMinutesChoices;

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
    this.mofiEvolveStage2Count = 3,
    this.dailyBands = DailyBands.defaults,
    this.usualMinutesDefault = 120,
    this.usualMinutesChoices = const [30, 60, 120, 180, 300],
  });

  /// 起動直後/オフライン用のデフォルト（migration seed と一致 / 0018 後の値）。
  static const EconomyParams defaults = EconomyParams(
    pointPerMinute: 1,
    dailyPointCap: 100,
    baselineFloorMinutes: 30,
    baselineWindowDays: 7,
    eggThresholds: EggThresholds.defaults,
    warmupGrants: WarmupGrants.defaults,
    streakMultipliers: StreakTier.flat,
    shinyRate: 0.02,
    pooledPointsMaxDays: 3,
    dexTotalEntries: 40,
    mofiEvolveStage2Count: 3,
    dailyBands: DailyBands.defaults,
    usualMinutesDefault: 120,
    usualMinutesChoices: [30, 60, 120, 180, 300],
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
      mofiEvolveStage2Count: _asInt(config['mofi_evolve_stage2_count']) ??
          d.mofiEvolveStage2Count,
      dailyBands: config['daily_bands'] is Map
          ? DailyBands.fromJson(
              (config['daily_bands']! as Map).cast<String, Object?>(),
            )
          : d.dailyBands,
      usualMinutesDefault:
          _asInt(config['usual_minutes_default']) ?? d.usualMinutesDefault,
      usualMinutesChoices: _asIntList(config['usual_minutes_choices']) ??
          d.usualMinutesChoices,
    );
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v'));
  static double? _asDouble(Object? v) =>
      v is double ? v : (v is num ? v.toDouble() : double.tryParse('$v'));

  /// 正の整数だけを拾った昇順リスト。空や不正なら null（既定へ倒す）。
  static List<int>? _asIntList(Object? v) {
    if (v is! List) return null;
    final out = <int>[];
    for (final e in v) {
      final n = _asInt(e);
      if (n == null || n <= 0) return null;
      out.add(n);
    }
    if (out.isEmpty) return null;
    out.sort();
    return out;
  }
}

/// §4-5 卵成長しきい値 ＋ 0018 の 5段階の区切り。
///
/// `stages` は昇順・先頭 0・末尾 [hatch]。各要素が段階の開始 pt
/// （既定 `[0, 100, 200, 300, 500]` = しろいたまご / もよう / ヒビ / ひかり / うまれる）。
/// `crack1` / `crack2` は古いアプリ向けに残した値で、新しい見た目では使わない。
class EggThresholds {
  final int crack1; // ヒビ① = 100pt（旧2段階の見た目用 / 互換）
  final int crack2; // ヒビ② = 250pt（旧2段階の見た目用 / 互換）
  final int hatch; // 孵化 = 500pt（累積）

  /// 5段階の区切り（各段階の開始 pt）。長さは任意だが、先頭 0・末尾 [hatch]・昇順。
  final List<int> stages;

  const EggThresholds({
    required this.crack1,
    required this.crack2,
    required this.hatch,
    this.stages = const [0, 100, 200, 300, 500],
  });

  static const EggThresholds defaults = EggThresholds(
    crack1: 100,
    crack2: 250,
    hatch: 500,
    stages: [0, 100, 200, 300, 500],
  );

  factory EggThresholds.fromJson(Map<String, Object?> j) {
    final hatch = (j['hatch'] as num?)?.toInt() ?? defaults.hatch;
    return EggThresholds(
      crack1: (j['crack1'] as num?)?.toInt() ?? defaults.crack1,
      crack2: (j['crack2'] as num?)?.toInt() ?? defaults.crack2,
      hatch: hatch,
      stages: _validStages(j['stages'], hatch),
    );
  }

  /// リモートの `stages` を検証する。不正（降順・先頭が 0 でない・末尾が hatch でない・
  /// 2 要素未満）なら、hatch を 4 等分した既定の形に倒す（表示が壊れないことを優先）。
  static List<int> _validStages(Object? raw, int hatch) {
    if (raw is List) {
      final out = <int>[];
      for (final e in raw) {
        if (e is! num) return _fallbackStages(hatch);
        out.add(e.toInt());
      }
      if (out.length >= 2 && out.first == 0 && out.last == hatch) {
        var ascending = true;
        for (var i = 1; i < out.length; i++) {
          if (out[i] <= out[i - 1]) ascending = false;
        }
        if (ascending) return List.unmodifiable(out);
      }
    }
    return _fallbackStages(hatch);
  }

  static List<int> _fallbackStages(int hatch) {
    if (hatch <= 0) return const [0];
    if (hatch == defaults.hatch) return defaults.stages;
    // 既定の比率（0 / 1/5 / 2/5 / 3/5 / 1）で hatch から導く。
    final q = hatch ~/ 5;
    return List.unmodifiable([0, q, q * 2, q * 3, hatch]);
  }

  /// 段階の添字（0 = 最初の段階 … stages.length-1 = 孵化可能）。
  int stageIndexOf(int growthPoints) {
    var idx = 0;
    for (var i = 0; i < stages.length; i++) {
      if (growthPoints >= stages[i]) idx = i;
    }
    return idx;
  }

  /// いまの段階の開始 pt。
  int stageStartOf(int growthPoints) => stages[stageIndexOf(growthPoints)];

  /// つぎの段階の開始 pt。最終段階（孵化可能）なら null。
  int? nextStagePointsOf(int growthPoints) {
    final i = stageIndexOf(growthPoints);
    return i + 1 < stages.length ? stages[i + 1] : null;
  }

  /// つぎの変化まで残り pt（孵化可能なら 0）。
  int remainingToNextStage(int growthPoints) {
    final next = nextStagePointsOf(growthPoints);
    if (next == null) return 0;
    return (next - growthPoints).clamp(0, next);
  }

  /// いまの段階の中での進捗 0.0〜1.0（孵化可能なら 1.0）。
  double stageProgressOf(int growthPoints) {
    final i = stageIndexOf(growthPoints);
    if (i + 1 >= stages.length) return 1.0;
    final start = stages[i];
    final end = stages[i + 1];
    if (end <= start) return 1.0;
    return ((growthPoints - start) / (end - start)).clamp(0.0, 1.0);
  }

  /// 「ひかり」が強まる pt（最後の段階区間の中間 / 既定 400）。
  ///
  /// 段階は変えない小さな変化。毎日◎の人の 4 日目にも「何か変わった」を見せるためのもので、
  /// 区切りの数値から導くので新しいマジックナンバーを持たない。
  int get glowStrongAt {
    if (stages.length < 2) return hatch;
    final start = stages[stages.length - 2];
    return start + (hatch - start) ~/ 2;
  }
}

/// S1 ウォームアップ付与（0018: 1日目 300 / 2日目は初回ボーナス卵が無いときの 200）。
///
/// 2日目の実際の量はサーバー `fn_claim_warmup` が「孵化までの残り全部」として決める。
class WarmupGrants {
  final int day1; // 300pt
  final int day2; // 200pt（初回ボーナス卵が無い / 孵化済み / 保管中のとき）

  const WarmupGrants({required this.day1, required this.day2});

  static const WarmupGrants defaults = WarmupGrants(day1: 300, day2: 200);

  factory WarmupGrants.fromJson(Map<String, Object?> j) => WarmupGrants(
        day1: (j['day1'] as num?)?.toInt() ?? defaults.day1,
        day2: (j['day2'] as num?)?.toInt() ?? defaults.day2,
      );
}

/// 0018: 1日の評価 1段の条件（◎ / ○）。
///
/// 条件: `その日の分 <= max(absMin, floor(R × ratio))`。
///   * absMin … 絶対ライン（ふだんから少ない人が ◎○ を取れるようにする）
///   * ratio  … ふだん R に対する比率
class BandRule {
  final int absMin;
  final double ratio;

  /// この評価で卵に入る pt。
  final int points;

  const BandRule({
    required this.absMin,
    required this.ratio,
    required this.points,
  });

  /// R に対してこの評価になる上限（分）。
  int limitFor(int usualMinutes) {
    final byRatio = (usualMinutes * ratio).floor();
    return absMin > byRatio ? absMin : byRatio;
  }

  factory BandRule.fromJson(Map<String, Object?> j, BandRule d) => BandRule(
        absMin: (j['abs_min'] as num?)?.toInt() ?? d.absMin,
        ratio: (j['ratio'] as num?)?.toDouble() ?? d.ratio,
        points: (j['points'] as num?)?.toInt() ?? d.points,
      );
}

/// 0018: 1日の評価（◎/○/△）。`app_config.daily_bands` と 1:1。
class DailyBands {
  final BandRule great;
  final BandRule good;

  /// △（多めだった日）に卵へ入る pt。0 にすれば「進まない」になる（値だけで試せる）。
  final int poorPoints;

  const DailyBands({
    required this.great,
    required this.good,
    required this.poorPoints,
  });

  static const DailyBands defaults = DailyBands(
    great: BandRule(absMin: 30, ratio: 0.5, points: 100),
    good: BandRule(absMin: 60, ratio: 0.75, points: 70),
    poorPoints: 15,
  );

  factory DailyBands.fromJson(Map<String, Object?> j) {
    const d = DailyBands.defaults;
    final great = j['great'];
    final good = j['good'];
    final poor = j['poor'];
    return DailyBands(
      great: great is Map
          ? BandRule.fromJson(great.cast<String, Object?>(), d.great)
          : d.great,
      good: good is Map
          ? BandRule.fromJson(good.cast<String, Object?>(), d.good)
          : d.good,
      poorPoints: poor is Map
          ? ((poor['points'] as num?)?.toInt() ?? d.poorPoints)
          : d.poorPoints,
    );
  }
}

/// S14 ストリーク倍率の1段。0018 で倍率は廃止したが、`app_config.streak_multipliers` の
/// 読み取りと連続日数の表示のために型は残す。
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

  /// 0018 以降の seed（倍率なし）。[EconomyParams.defaults] はこちら。
  static const List<StreakTier> flat = [StreakTier(days: 1, mult: 1.0)];

  /// 旧 seed（1日×1.0 / 3日×1.2 / 7日×1.5 / 30日×2.0）。倍率ロジックのテスト用に残す。
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

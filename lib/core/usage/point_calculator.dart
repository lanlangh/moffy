import 'dart:math' as math;

import '../constants/economy.dart';
import 'usage_models.dart';

/// 削減量からポイントを計算する抽象（ARCHITECTURE §2-2）。
///
/// 重要: ここで計算するのは「端末側の暫定値（楽観的更新用）」。確定値は必ず
/// サーバーRPC `fn_finalize_day` が再計算する（ARCHITECTURE §2-3: サーバーSSOT）。
/// 経済パラメータ（上限/クランプ/倍率）は [EconomyParams] 経由で参照し、
/// 計算ロジックにマジックナンバーを書かない（ARCHITECTURE §0-1）。
abstract interface class PointCalculator {
  UsageMode get mode;

  /// その日の基礎ポイント（倍率適用前）を計算する。
  /// 削減量 = baseline.appliedMinutes - today.totalMinutes。マイナスは 0 にクランプ（S2）。
  int calculateBasePoints({
    required DailyUsage today,
    required Baseline baseline,
    required EconomyParams params,
  });

  /// 基礎ptにストリーク倍率を適用し、1日上限でクランプした最終ポイントを返す（S14,S4）。
  /// 倍率は基礎ptにのみ適用。固定報酬（クエスト/ジェム/卵）には掛けない。
  int applyStreakAndCap({
    required int basePoints,
    required int currentStreakDays,
    required EconomyParams params,
  });
}

/// Android実装: 分単位の正確な削減量から線形にpt化（1分=1pt）。
final class ExactMinutesPointCalculator implements PointCalculator {
  const ExactMinutesPointCalculator();

  @override
  UsageMode get mode => UsageMode.exactMinutes;

  @override
  int calculateBasePoints({
    required DailyUsage today,
    required Baseline baseline,
    required EconomyParams params,
  }) {
    // 異常値（24h超 / S4）は加点せず0扱い（サーバーが破棄する）。
    if (today.isAnomaly) return 0;
    // 削減量 = 基準値(クランプ後) - 今日の利用。マイナスは下限0（S2）。
    final reduction = baseline.appliedMinutes - today.totalMinutes;
    final clamped = math.max(0, reduction);
    return clamped * params.pointPerMinute;
  }

  @override
  int applyStreakAndCap({
    required int basePoints,
    required int currentStreakDays,
    required EconomyParams params,
  }) {
    final mult = StreakTier.multiplierFor(
      currentStreakDays,
      params.streakMultipliers,
    );
    final boosted = (basePoints * mult).floor();
    // 1日上限480ptは倍率適用後の最終値で判定（S14）。
    return math.min(boosted, params.dailyPointCap);
  }
}

/// iOS実装（v1.1）: 段階しきい値の達成度を近似pt化（15/30分起点の刻み）。
/// 分数が取れないため「しきい値を何段クリアしたか」を擬似削減量に換算する。
/// 第1パスはAndroid縦スライスのため骨子のみ（実装は iOS 追従時 / PRD §6）。
final class ThresholdAchievementPointCalculator implements PointCalculator {
  const ThresholdAchievementPointCalculator();

  @override
  UsageMode get mode => UsageMode.thresholdAchievement;

  @override
  int calculateBasePoints({
    required DailyUsage today,
    required Baseline baseline,
    required EconomyParams params,
  }) {
    // v1.1で実装: 段階しきい値の達成段数 -> 近似削減量 -> pt。
    // 暫定として exact 互換のロジックにフォールバック（安全側）。
    if (today.isAnomaly) return 0;
    final reduction = baseline.appliedMinutes - today.totalMinutes;
    return math.max(0, reduction) * params.pointPerMinute;
  }

  @override
  int applyStreakAndCap({
    required int basePoints,
    required int currentStreakDays,
    required EconomyParams params,
  }) {
    final mult = StreakTier.multiplierFor(
      currentStreakDays,
      params.streakMultipliers,
    );
    return math.min((basePoints * mult).floor(), params.dailyPointCap);
  }
}

/// 基準値（S1 ウォームアップ方式の結果 / ARCHITECTURE §2-2）。
class Baseline {
  final DateTime date;

  /// 欠損除外後の生平均（分）。データ無しは null。
  final double? rawAverageMinutes;

  /// 30分クランプ後の適用値（§4-5）。
  final int appliedMinutes;

  /// 平均の分母（実データ日数）。
  final int sampleDays;

  /// warmup / provisional / confirmed（S1）。
  final BaselineStage stage;

  const Baseline({
    required this.date,
    required this.rawAverageMinutes,
    required this.appliedMinutes,
    required this.sampleDays,
    required this.stage,
  });

  /// 暫定基準（Day3〜6）はUIに「暫定」ラベルを出す（SCREEN_FLOWS §2）。
  bool get isProvisional => stage == BaselineStage.provisional;

  /// ウォームアップ期（Day1〜2）は削減計算をせず固定pt（S1）。
  bool get isWarmup => stage == BaselineStage.warmup;

  /// 直近N日の利用（本日除く・欠損除外）から基準値を算出する（S11,§4-5）。
  ///
  /// [history] は本日を含まない過去日の [DailyUsage] リスト（欠損日は含まない前提）。
  /// データ日数によって stage を決める（S1）:
  ///   * 0〜1日 -> warmup（基準計算しない。appliedMinutes は floor で安全側）
  ///   * 2〜6日 -> provisional（取得日の平均）
  ///   * 7日以上 -> confirmed（直近7日平均）
  static Baseline compute({
    required DateTime forDate,
    required List<DailyUsage> history,
    required EconomyParams params,
  }) {
    final sorted = [...history]..sort((a, b) => b.date.compareTo(a.date));
    final sampleDays = sorted.length;
    final floor = params.baselineFloorMinutes;

    if (sampleDays <= 1) {
      return Baseline(
        date: forDate,
        rawAverageMinutes: null,
        appliedMinutes: floor, // 計算しないが下限を安全側で保持
        sampleDays: sampleDays,
        stage: BaselineStage.warmup,
      );
    }

    final BaselineStage stage;
    final List<DailyUsage> window;
    if (sampleDays >= params.baselineWindowDays) {
      stage = BaselineStage.confirmed;
      window = sorted.take(params.baselineWindowDays).toList();
    } else {
      stage = BaselineStage.provisional;
      window = sorted;
    }

    final rawAvg =
        window.map((e) => e.totalMinutes).reduce((a, b) => a + b) /
            window.length;
    // §4-5 下限30分クランプ（低利用ユーザーの0pt詰み防止 / S2）。
    final applied = math.max(floor, rawAvg.round());

    return Baseline(
      date: forDate,
      rawAverageMinutes: rawAvg,
      appliedMinutes: applied,
      sampleDays: window.length,
      stage: stage,
    );
  }
}

/// 基準値の確定ステージ（S1）。
enum BaselineStage { warmup, provisional, confirmed }

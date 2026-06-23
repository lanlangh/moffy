import '../../../core/constants/economy.dart';
import '../../../core/usage/point_calculator.dart';
import '../../../core/usage/usage_models.dart';

/// ホーム画面の表示状態（ARCHITECTURE §1 domain）。
/// AsyncValue<HomeState> として AsyncNotifier が返す（loading/error はAsyncValueで担保）。
class HomeState {
  /// 利用統計の権限状態。granted 以外は削減カードをフォールバック表示（受け入れ §5-1）。
  final UsagePermissionStatus permission;

  /// 今日の対象SNS利用（端末暫定 / 楽観的更新）。権限なし or 未取得は null。
  final DailyUsage? todayUsage;

  /// 適用された基準値（S1 ウォームアップ）。warmup 期は削減計算しない。
  final Baseline baseline;

  /// 端末で暫定計算した今日の獲得pt（倍率適用後 / 表示用。確定はサーバー）。
  final int provisionalPoints;

  /// 昨日の利用分（昨日比表示用）。無ければ null。
  final int? yesterdayMinutes;

  /// 育成中アクティブ卵の概要（無ければ null = 空状態 / 空枠誘導）。
  final ActiveEggSummary? activeEgg;

  /// 通貨残高（キャッシュ即時表示 / オフラインでも表示）。
  final int pointBalance;
  final int gemBalance;

  /// 空枠時にプールされたpt（S6 / 取りこぼし不安の解消表示）。
  final int pooledPoints;

  /// オフライン中か（上端バー + 楽観的更新の明示 / S8）。
  final bool isOffline;

  /// 経済パラメータ（SSOT。表示の単位・しきい値はここから）。
  final EconomyParams params;

  const HomeState({
    required this.permission,
    required this.todayUsage,
    required this.baseline,
    required this.provisionalPoints,
    required this.yesterdayMinutes,
    required this.activeEgg,
    required this.pointBalance,
    required this.gemBalance,
    required this.pooledPoints,
    required this.isOffline,
    required this.params,
  });

  /// 権限が無く削減計算できない（フォールバックUI / §5-1）。
  bool get isPermissionMissing => !permission.isGranted;

  /// 初日ウォームアップ期（Day1〜2）。削減数値を出さず初回ボーナス卵を主役化（SCREEN_FLOWS §2）。
  bool get isWarmup => baseline.isWarmup;

  /// 削減量（分）。基準値 - 今日利用。マイナスは0（S2）。null安全。
  int get reductionMinutes {
    final usage = todayUsage;
    if (usage == null) return 0;
    final r = baseline.appliedMinutes - usage.totalMinutes;
    return r < 0 ? 0 : r;
  }

  /// 今日は利用が基準より多かった「マイナス日」か（責めない文言を出す / S2）。
  bool get isOverBaseline {
    final usage = todayUsage;
    if (usage == null || isWarmup) return false;
    return usage.totalMinutes > baseline.appliedMinutes;
  }

  /// 育成枠にアクティブ卵が無い空状態（空枠誘導 / §5-2）。
  bool get hasNoActiveEgg => activeEgg == null;
}

/// ホームに出す育成中卵の最小情報。
class ActiveEggSummary {
  final String eggId;
  final int growthPoints; // 累積成長pt
  final int hatchThreshold; // 孵化しきい値（=500）
  final String rarityLabel; // 'normal' 等（表示はレアリティ色に対応）

  const ActiveEggSummary({
    required this.eggId,
    required this.growthPoints,
    required this.hatchThreshold,
    required this.rarityLabel,
  });

  /// 孵化までの進捗（0.0〜1.0）。
  double get progress =>
      hatchThreshold <= 0 ? 0 : (growthPoints / hatchThreshold).clamp(0.0, 1.0);

  /// 孵化まで残りpt。
  int get remaining =>
      (hatchThreshold - growthPoints).clamp(0, hatchThreshold);

  /// 孵化間近（巣リング微発光のトリガ / SCREEN_FLOWS §2）。残50pt以内（S9と同基準）。
  bool get isNearHatch => remaining <= 50 && remaining > 0;
}

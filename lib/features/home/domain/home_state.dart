import '../../../core/constants/economy.dart';
import '../../../core/usage/day_band.dart';
import '../../../core/usage/usage_models.dart';
import '../../../core/widgets/egg_art.dart';
import '../../eggs/domain/egg_models.dart';

/// ホーム画面の表示状態（ARCHITECTURE §1 domain）。
/// AsyncValue<HomeState> として AsyncNotifier が返す（loading/error はAsyncValueで担保）。
///
/// 【0018】基準値（直近7日平均）は持たない。代わりに「ふだんのSNS時間」R と、
/// きのうの結果（サーバー確定）・きょうのペース（端末暫定）を持つ
/// （docs/design/EGG_PACING_DESIGN.md §4-5）。
class HomeState {
  /// 利用統計の権限状態。granted 以外は結果カードをフォールバック表示（受け入れ §5-1）。
  final UsagePermissionStatus permission;

  /// 今日の対象SNS利用（端末暫定 / 楽観的更新）。権限なし or 未取得は null。
  final DailyUsage? todayUsage;

  /// 利用取得に失敗したときのメッセージ（null = 失敗していない）。
  final String? usageErrorMessage;

  /// ふだんのSNS時間 R（分）。サーバーの値（profiles.usual_minutes）を優先し、
  /// 取れなければ端末の申告値、それも無ければ既定（params.usualMinutesDefault）。
  final int usualMinutes;

  /// R の出どころ（'default' | 'reported' | 'measured'）。
  final String usualMinutesSource;

  /// きのうの結果（サーバー確定）。記録が無ければ null（開かなかった日・初日）。
  final YesterdayResult? yesterday;

  /// きのうの結果を取得できなかった（オフライン / 通信・サーバーエラー）。
  /// [yesterday] が null でもこれが true なら「開かなかった」とは言わない（事実と違う断定を避ける）。
  final bool yesterdayUnavailable;

  /// ローカル初回起動日が今日か（「きのうの結果」は明日から / S1）。
  final bool isFirstDay;

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

  /// ウォームアップ自動付与（F-01 / S1）の今回結果。
  ///
  /// 付与に成功（新規付与）した場合のみ非null。未対象/オフライン/エラー/受取済みは null
  /// （= 通常ホーム。責めない・黙って通常表示 / 受け入れ §5-1）。
  final WarmupGrantSummary? warmupGrant;

  const HomeState({
    required this.permission,
    required this.todayUsage,
    required this.usualMinutes,
    required this.usualMinutesSource,
    required this.yesterday,
    required this.isFirstDay,
    required this.activeEgg,
    required this.pointBalance,
    required this.gemBalance,
    required this.pooledPoints,
    required this.isOffline,
    required this.params,
    this.usageErrorMessage,
    this.warmupGrant,
    this.yesterdayUnavailable = false,
  });

  /// 権限が無く計測できない（フォールバックUI / §5-1）。
  bool get isPermissionMissing => !permission.isGranted;

  /// きょうの計測分（未取得なら 0）。
  int get todayMinutes => todayUsage?.totalMinutes ?? 0;

  /// きょうのペース（端末暫定の評価）。利用が取れていなければ null。
  ///
  /// 確定はサーバー（翌日の `fn_finalize_day`）。ここは「いまのままなら」の目安。
  DayBand? get todayBand {
    final usage = todayUsage;
    if (usage == null || usage.isAnomaly) return null;
    return DayBandCalculator.evaluate(
      minutes: usage.totalMinutes,
      usualMinutes: usualMinutes,
      bands: params.dailyBands,
    );
  }

  /// ◎ になる上限（分）。
  int get greatLimit =>
      DayBandCalculator.greatLimit(usualMinutes, params.dailyBands);

  /// ○ になる上限（分）。
  int get goodLimit =>
      DayBandCalculator.goodLimit(usualMinutes, params.dailyBands);

  /// 育成枠にアクティブ卵が無い空状態（空枠誘導 / §5-2）。
  bool get hasNoActiveEgg => activeEgg == null;

  /// ウォームアップ付与の祝福表示を出すか（新規付与時のみ / F-01 ハッピーパス）。
  bool get showWarmupCelebration => warmupGrant != null;
}

/// きのうの結果（サーバー確定 / 0018 §4-5「きのうの結果」）。
class YesterdayResult {
  /// 対象日。年月日だけに意味がある（サーバー由来はローカル 0 時、代用は UTC 0 時なので、
  /// 時刻や TZ を比較・表示に使わない）。
  final DateTime date;

  /// サーバーが確定済みか。false = 提出はあるがまだ確定していない（計算中）。
  final bool finalized;

  /// 計測できていた日か。
  final bool measured;

  /// 評価。未確定・計測なしは [DayBand.unmeasured]。
  final DayBand band;

  /// 卵に入った pt。
  final int points;

  /// その日の計測分。
  final int minutes;

  const YesterdayResult({
    required this.date,
    required this.finalized,
    required this.measured,
    required this.band,
    required this.points,
    required this.minutes,
  });
}

/// ウォームアップ付与（F-01 / S1）の祝福表示用サマリ。
///
/// サーバー RPC `fn_claim_warmup` の結果のうち、UIで使う分だけを domain 型へ落とす
/// （wire モデル [WarmupClaimResult] をプレゼンテーション層へ漏らさない / ARCHITECTURE §1）。
class WarmupGrantSummary {
  /// 対象日（1 | 2）。
  final int day;

  /// 今回新規に付与された pt（0018: Day1=300 / Day2=孵化までの残り全部）。
  final int grantedPoints;

  const WarmupGrantSummary({required this.day, required this.grantedPoints});
}

/// ホームに出す育成中卵の最小情報。
class ActiveEggSummary {
  final String eggId;
  final int growthPoints; // 累積成長pt

  /// 段階の区切りと孵化しきい値（SSOT）。
  final EggThresholds thresholds;
  final String rarityLabel; // 'normal' 等（表示はレアリティ色に対応）

  const ActiveEggSummary({
    required this.eggId,
    required this.growthPoints,
    required this.thresholds,
    required this.rarityLabel,
  });

  /// 孵化しきい値（=500）。
  int get hatchThreshold => thresholds.hatch;

  /// 孵化までの進捗（0.0〜1.0）。
  double get progress =>
      hatchThreshold <= 0 ? 0 : (growthPoints / hatchThreshold).clamp(0.0, 1.0);

  /// 孵化まで残りpt。
  int get remaining =>
      (hatchThreshold - growthPoints).clamp(0, hatchThreshold);

  /// 孵化可能（500pt 到達）。
  bool get canHatch => remaining == 0;

  /// 成長段階（5段階）。
  EggGrowthStage get stage =>
      EggGrowthStage.fromThresholds(growthPoints, thresholds);

  /// S4 の「強まる」（400pt〜）。
  bool get isStrongGlow =>
      EggGrowthStage.isStrongGlow(growthPoints, thresholds);

  /// 見た目（[EggArt] 用）。
  EggLook get look => stage.look(strong: isStrongGlow);

  /// 「最後に見た段階」の値（0..5）。
  int get visualStep => EggGrowthStage.visualStep(growthPoints, thresholds);

  /// いまの段階の添字（0 = S1）。孵化までの点の塗り数は [stageIndex] + 1。
  int get stageIndex => thresholds.stageIndexOf(growthPoints);

  /// 段階の数（点の総数 / 既定 5）。
  int get stageCount => thresholds.stages.length;

  /// いまの段階の中での進捗 0.0〜1.0（進捗バー用）。
  double get stageProgress => thresholds.stageProgressOf(growthPoints);

  /// つぎの変化まで残りpt（孵化可能なら 0）。
  int get remainingToNextStage => thresholds.remainingToNextStage(growthPoints);

  /// 孵化間近（巣リング微発光のトリガ / SCREEN_FLOWS §2）。
  /// 0018: 残50pt ではなく **S4 の「強まる」（400pt〜）** に置き換えた（§4-2）。
  bool get isNearHatch => isStrongGlow && !canHatch;
}

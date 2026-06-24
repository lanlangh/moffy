/// fn_finalize_day（確定RPC）まわりの wire モデル（ARCHITECTURE §1-5 / §2-3 / S8）。
///
/// 信頼境界（§2-3）: ポイント確定はサーバーが SSOT。クライアントは
///   1. 端末の生データ（[UsageDailyDraft]）を usage_daily へ提出し、
///   2. サーバー RPC `fn_finalize_day(p_date)` が確定計算した結果（[FinalizeDayResult]）を
///      受け取って表示・キャッシュ更新に使うだけ（クライアントは確定計算しない）。
///
/// 本ファイルは「提出ペイロードの生成」と「確定レスポンスのパース」を純粋ロジックとして
/// 切り出し、単体テスト対象にする（Supabase 依存を持たない）。
library;

import '../usage/usage_models.dart';

/// usage_daily へ提出する日次生データ（端末 SSOT → サーバー / S8）。
///
/// migration 0001 の usage_daily カラムに 1:1 対応する。RLS（`usage_insert_own` /
/// `usage_update_own_unfinalized`）で本人・未確定行のみ提出/更新可。
class UsageDailyDraft {
  /// ユーザーTZの暦日（usage_date）。日付のみ（時刻成分は無視する）。
  final DateTime usageDate;

  /// 対象4SNSの合計利用分（total_minutes）。
  final int totalMinutes;

  /// アプリ別内訳（per_app_minutes / 監査・分析用）。
  final Map<String, int> perAppMinutes;

  /// 取得元計算モード（source_mode）。
  final UsageMode mode;

  /// S4 異常値の端末側ヒント（1440分超）。**ローカルの楽観pt計算専用**。
  ///
  /// 信頼境界（H4-1/M4-1 / migration 0004 G-4）: usage_daily.is_anomaly は
  /// サーバー専管列（クライアントは列GRANTで書込不可）になったため、この値は
  /// DB へは送らない（[toUsageRow] に含めない）。異常判定の権威は
  /// fn_finalize_day（サーバー / total_minutes > app_config.daily_minutes_max）にある。
  /// 端末はこの値を [PointCalculator] の楽観表示と sync_queue ローカル復元にのみ使う。
  final bool isAnomaly;

  /// 端末で暫定計算した「その日の確定相当pt」。
  /// S8 競合解決（確定ptを減らさない方向のみ反映）の比較基準に使う（サーバー確定前の楽観値）。
  final int localPoints;

  const UsageDailyDraft({
    required this.usageDate,
    required this.totalMinutes,
    required this.perAppMinutes,
    required this.mode,
    this.isAnomaly = false,
    this.localPoints = 0,
  });

  /// 端末の [DailyUsage]（楽観的に算出した確定相当pt付き）から提出ドラフトを作る。
  factory UsageDailyDraft.fromDailyUsage(
    DailyUsage usage, {
    int localPoints = 0,
  }) =>
      UsageDailyDraft(
        usageDate: usage.date,
        totalMinutes: usage.totalMinutes,
        perAppMinutes: usage.perAppMinutes,
        mode: usage.mode,
        isAnomaly: usage.isAnomaly,
        localPoints: localPoints,
      );

  /// `p_date`（fn_finalize_day 引数）/ usage_date に渡す YYYY-MM-DD 文字列。
  String get dateKey {
    final y = usageDate.year.toString().padLeft(4, '0');
    final m = usageDate.month.toString().padLeft(2, '0');
    final d = usageDate.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// usage_daily への upsert 行（本人 user_id は呼び出し側で付与）。
  ///
  /// 信頼境界（H4-1/M4-1 / migration 0004 G-4）: クライアントが書けるのは
  /// 生データ列（usage_date / total_minutes / per_app_minutes / source_mode）のみ。
  /// is_finalized / is_anomaly は列GRANTでサーバー専管（送ると権限エラー）。
  /// id / created_at / updated_at は DB の default / トリガで自動充填される。
  Map<String, Object?> toUsageRow() => {
        'usage_date': dateKey,
        'total_minutes': totalMinutes,
        'per_app_minutes': perAppMinutes,
        'source_mode': mode.wire,
      };

  /// sync_queue（[SyncOperation.payload]）へ積む形へ直列化する。
  Map<String, Object?> toPayload() => {
        'usage_date': dateKey,
        'total_minutes': totalMinutes,
        'per_app_minutes': perAppMinutes,
        'source_mode': mode.wire,
        'is_anomaly': isAnomaly,
        'local_points': localPoints,
      };

  /// sync_queue ペイロードから復元する（[toPayload] の逆）。
  factory UsageDailyDraft.fromPayload(Map<String, Object?> p) {
    final raw = (p['per_app_minutes'] as Map?) ?? const {};
    final perApp = <String, int>{
      for (final e in raw.entries)
        '${e.key}': (e.value as num?)?.toInt() ?? 0,
    };
    return UsageDailyDraft(
      usageDate: DateTime.parse('${p['usage_date']}'),
      totalMinutes: (p['total_minutes'] as num?)?.toInt() ?? 0,
      perAppMinutes: perApp,
      mode: UsageMode.fromWire('${p['source_mode']}'),
      isAnomaly: p['is_anomaly'] == true,
      localPoints: (p['local_points'] as num?)?.toInt() ?? 0,
    );
  }
}

/// fn_finalize_day の戻り jsonb（migration 0002）のパース結果。
///
/// 成功時（finalized=true）は確定値一式を持つ。確定できない日（未提出/異常値/未来日）は
/// finalized=false + [reason] を持つ。クライアントはこの結果で UI/キャッシュを更新する。
class FinalizeDayResult {
  /// この日を確定したか（false: no_usage_data / anomaly 等）。
  final bool finalized;

  /// 未確定の理由（'no_usage_data' | 'anomaly' 等 / finalized=false 時のみ）。
  final String? reason;

  /// 今回の呼び出しで新規付与された確定pt（再実行/冪等スキップ時は 0）。
  final int pointsAwarded;

  /// 倍率適用前の基礎pt。
  final int basePoints;

  /// 適用されたストリーク倍率（S14）。
  final double multiplier;

  /// 適用基準値（分 / 30分クランプ後）。
  final int baselineMinutes;

  /// 削減分（max(0, baseline - today)）。
  final int reducedMinutes;

  /// 480pt上限でクランプされたか（S4）。
  final bool capped;

  /// 基準値の段階（'warmup' | 'provisional' | 'confirmed' / S1）。
  final String stage;

  /// 更新後のストリーク日数（S14）。
  final int streakAfter;

  /// 卵への成長pt反映結果（fn_apply_growth の戻り / null あり）。
  final Map<String, Object?>? eggApplied;

  /// 既に確定済みで今回は加算されなかった（冪等スキップ / S8）。
  final bool alreadyFinalized;

  const FinalizeDayResult({
    required this.finalized,
    this.reason,
    this.pointsAwarded = 0,
    this.basePoints = 0,
    this.multiplier = 1.0,
    this.baselineMinutes = 0,
    this.reducedMinutes = 0,
    this.capped = false,
    this.stage = 'warmup',
    this.streakAfter = 0,
    this.eggApplied,
    this.alreadyFinalized = false,
  });

  /// migration 0002 の `jsonb_build_object(...)` 形からパースする。
  factory FinalizeDayResult.fromJson(Map<String, Object?> j) {
    final finalized = j['finalized'] == true;
    if (!finalized) {
      return FinalizeDayResult(
        finalized: false,
        reason: j['reason'] as String?,
      );
    }
    return FinalizeDayResult(
      finalized: true,
      pointsAwarded: (j['points_awarded'] as num?)?.toInt() ?? 0,
      basePoints: (j['base_points'] as num?)?.toInt() ?? 0,
      multiplier: (j['multiplier'] as num?)?.toDouble() ?? 1.0,
      baselineMinutes: (j['baseline_minutes'] as num?)?.toInt() ?? 0,
      reducedMinutes: (j['reduced_minutes'] as num?)?.toInt() ?? 0,
      capped: j['capped'] == true,
      stage: (j['stage'] as String?) ?? 'warmup',
      streakAfter: (j['streak_after'] as num?)?.toInt() ?? 0,
      eggApplied: _asMap(j['egg_applied']),
      alreadyFinalized: j['already_finalized'] == true,
    );
  }

  /// egg_applied は jsonb（Map）または 'null'（SQLのnull→Dartのnull）で返る。
  static Map<String, Object?>? _asMap(Object? v) =>
      v is Map ? v.cast<String, Object?>() : null;
}

/// fn_claim_warmup（ウォームアップ自動付与RPC / F-01）の戻り jsonb のパース結果。
///
/// 信頼境界（§2-3 / S1）: ウォームアップ付与（Day1=200 / Day2=300）と初回ボーナス卵への
/// 充当はサーバー RPC `fn_claim_warmup(p_day)` の責務（冪等キーは生涯1回 = uid×'warmup'×day）。
/// クライアントは「Day1/Day2 の受取要求」を送り、結果を受け取って表示・キャッシュ更新するだけ。
/// 残高・卵 growth_points を加算するのはサーバー（クライアントは書かない）。
class WarmupClaimResult {
  /// RPC が実行されたか（常に true。例外時はそもそも本型を作らない）。
  final bool claimed;

  /// 対象日（1 | 2）。
  final int day;

  /// 今回新規に付与された pt（冪等スキップ時は 0）。
  final int granted;

  /// 充当先の初回ボーナス卵 id（生成/既存。無ければ null）。
  final String? eggId;

  /// 卵への成長pt反映結果（fn_apply_growth の戻り / null あり）。
  final Map<String, Object?>? eggApplied;

  /// 付与後の残高（初回付与時のみサーバーが返す / 冪等スキップ時は null）。
  final int? balanceAfter;

  /// 既に受取済みで今回は加算されなかった（冪等スキップ / 生涯1回）。
  final bool alreadyClaimed;

  const WarmupClaimResult({
    required this.claimed,
    required this.day,
    this.granted = 0,
    this.eggId,
    this.eggApplied,
    this.balanceAfter,
    this.alreadyClaimed = false,
  });

  /// migration 0003 の `jsonb_build_object(...)` 形からパースする。
  factory WarmupClaimResult.fromJson(Map<String, Object?> j) =>
      WarmupClaimResult(
        claimed: j['claimed'] == true,
        day: (j['day'] as num?)?.toInt() ?? 0,
        granted: (j['granted'] as num?)?.toInt() ?? 0,
        eggId: j['egg_id'] as String?,
        eggApplied: FinalizeDayResult._asMap(j['egg_applied']),
        balanceAfter: (j['balance_after'] as num?)?.toInt(),
        alreadyClaimed: j['already_claimed'] == true,
      );
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/economy.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/sync/finalize_models.dart';
import '../../../core/sync/usage_sync_repository.dart';
import '../../../core/usage/day_band.dart';
import '../../../core/usage/usage_models.dart';
import '../../../core/usage/usage_providers.dart';
import '../../eggs/data/egg_repository.dart';
import '../domain/home_state.dart';

/// ホームのデータ層（ARCHITECTURE §1-2 data）。
/// OS抽象（UsageProvider）から「今日の利用」を取り、サーバーから残高・卵・きのうの結果・
/// 「ふだんのSNS時間」を読む。Supabase の詳細は上位に漏らさず、ドメイン型のみ返す。
///
/// 【0018】基準値（直近7日平均）の計算は廃止。評価（◎/○/△）はサーバー `fn_finalize_day` が
/// 確定し、端末は「きょうのペース」を [DayBandCalculator] で暫定表示するだけ。
class HomeRepository {
  HomeRepository(this._ref);

  final Ref _ref;

  /// 今日の利用を取得する（端末暫定 / 権限なし・失敗でも画面を落とさない）。
  Future<HomeUsageResult> loadUsage({
    required List<String> targetPackages,
    DateTime? now,
  }) async {
    final usageProvider = _ref.read(usageProviderProvider);
    final today = now ?? DateTime.now();

    // 1. 権限チェック（無ければフォールバック / §5-1）。
    final permission = await usageProvider.checkPermission();
    if (!permission.isGranted) {
      return HomeUsageResult.noPermission(permission);
    }

    try {
      // 2. 今日の利用（端末暫定）。
      final todayUsage = await usageProvider.fetchDailyUsage(
        date: today,
        targetPackages: targetPackages,
      );
      return HomeUsageResult.success(
        permission: permission,
        todayUsage: todayUsage,
      );
    } on UsageException catch (e, st) {
      Log.e('usage fetch failed', error: e, stack: st);
      return HomeUsageResult.fetchError(permission, e.message);
    }
  }

  /// 通貨残高・アクティブ卵・プールpt・ふだんのSNS時間の取得
  /// （確定値SSOT = サーバー / ARCHITECTURE §1-5 step3）。
  ///
  /// 確定値（point_balance/gem_balance/pooled_points/アクティブ卵の growth_points）は
  /// すべてサーバーが SSOT。本メソッドは本人行を select するだけで、加算・改ざんはしない。
  /// Supabase 未設定/オフライン/取得失敗時は安全なデフォルト（0 / 卵なし）を返し、画面を落とさない。
  Future<HomeServerSnapshot> loadServerSnapshot(EconomyParams params) async {
    // モック/プレビュー（forceMock または Supabase 未設定）: たまご/図鑑タブの
    // モックと整合するテスト用スナップショットを返す（育成中の卵＋残高を表示）。
    // これが無いとホームだけ空の巣＋残高0になり、他タブと食い違う（ユーザーFB）。
    // 本番（useSupabase=true）はこの分岐を通らず、必ず実バックエンドを select する。
    if (!Env.useSupabase) {
      return _mockSnapshot(params);
    }
    if (!_ref.read(isOnlineProvider)) {
      return HomeServerSnapshot.empty;
    }
    try {
      final client = _ref.read(supabaseClientProvider);

      // 残高・プールpt（profiles の本人行 / RLS本人select）。
      final profile = await client
          .from('profiles')
          .select('point_balance, gem_balance, pooled_points')
          .maybeSingle();

      // アクティブ卵（育成中・is_active / S6: 1枠のみ）。無ければ空状態。
      final egg = await client
          .from('eggs')
          .select('id, rarity, growth_points')
          .eq('is_active', true)
          .eq('location', 'incubating')
          .maybeSingle();

      ActiveEggSummary? active;
      if (egg != null) {
        active = ActiveEggSummary(
          eggId: '${egg['id']}',
          growthPoints: (egg['growth_points'] as num?)?.toInt() ?? 0,
          thresholds: params.eggThresholds,
          rarityLabel: '${egg['rarity']}',
        );
      }

      // ふだんのSNS時間（0018 の列）。別クエリにしてあるのは、DB 側に 0018 が未適用でも
      // 残高・卵の取得まで巻き添えで失敗させないため（列が無い → この select だけ失敗）。
      int? usual;
      String? usualSource;
      try {
        final r = await client
            .from('profiles')
            .select('usual_minutes, usual_minutes_source')
            .maybeSingle();
        usual = (r?['usual_minutes'] as num?)?.toInt();
        usualSource = r?['usual_minutes_source'] as String?;
      } catch (e, st) {
        Log.e('usual_minutes select failed (0018 未適用?)', error: e, stack: st);
      }

      return HomeServerSnapshot(
        pointBalance: (profile?['point_balance'] as num?)?.toInt() ?? 0,
        gemBalance: (profile?['gem_balance'] as num?)?.toInt() ?? 0,
        pooledPoints: (profile?['pooled_points'] as num?)?.toInt() ?? 0,
        activeEgg: active,
        usualMinutes: usual,
        usualMinutesSource: usualSource,
      );
    } catch (e, st) {
      // 確定値が取れなくても画面は出す（5状態: オフライン/エラーは局所表示）。
      Log.e('loadServerSnapshot failed', error: e, stack: st);
      return HomeServerSnapshot.empty;
    }
  }

  /// きのうの結果（サーバー確定 / 0018 §4-5）。
  ///
  /// `usage_daily`（提出・確定の有無・計測の有無）と `point_ledger`（卵に入った pt と評価）を
  /// 本人 select で読む。行が無ければ null（＝その日は開かなかった / 初日）。
  /// 確定済みなのに台帳の評価が無い（0018 以前に確定した日）は、R から評価を再計算して出す。
  ///
  /// 「きのう」はサーバーに聞く（`fn_pending_finalize_date` が返す「確定すべき日」= サーバー基準の
  /// 前日 / 0011）。端末の時計・TZ で計算した日とサーバーが確定した日が食い違うと、結果があるのに
  /// 「開かなかった」と出る。読み込むたびに聞き直すので、値を持ち回って日跨ぎで古くなることもない。
  /// 聞けないときだけ [fallbackDate]（JST の暦日から出した代用）で引く。
  Future<YesterdayResult?> loadYesterdayResult({
    required DateTime fallbackDate,
    required int usualMinutes,
    required EconomyParams params,
    bool localFirstDay = false,
  }) async {
    // モック/プレビューにはサーバーが無いので、ローカル初日は「結果なし」にして
    // 初日の文言（きょうが1日目）を見られるようにする。本番はサーバーの行の有無で決まる。
    if (!Env.useSupabase) {
      return localFirstDay ? null : _mockYesterday(fallbackDate, params);
    }
    if (!_ref.read(isOnlineProvider)) return null;
    final date = await _serverYesterday(fallbackDate);
    try {
      final client = _ref.read(supabaseClientProvider);
      final key = _dateKey(date);
      final row = await client
          .from('usage_daily')
          .select('total_minutes, is_finalized, is_measured')
          .eq('usage_date', key)
          .maybeSingle();
      if (row == null) return null;
      final minutes = (row['total_minutes'] as num?)?.toInt() ?? 0;
      final finalized = row['is_finalized'] == true;
      // 0018 未適用の DB では列が無く null になる → 計測あり扱い（旧挙動と同じ）。
      final measured = row['is_measured'] != false;

      if (!finalized) {
        return YesterdayResult(
          date: date,
          finalized: false,
          measured: measured,
          band: DayBand.unmeasured,
          points: 0,
          minutes: minutes,
        );
      }
      if (!measured) {
        return YesterdayResult(
          date: date,
          finalized: true,
          measured: false,
          band: DayBand.unmeasured,
          points: 0,
          minutes: minutes,
        );
      }

      var points = 0;
      DayBand? band;
      final ledger = await client
          .from('point_ledger')
          .select('amount, meta')
          .eq('ledger_date', key)
          .eq('source', 'reduction')
          .maybeSingle();
      if (ledger != null) {
        points = (ledger['amount'] as num?)?.toInt() ?? 0;
        final meta = ledger['meta'];
        if (meta is Map && meta['band'] is String) {
          band = DayBand.fromWire(meta['band'] as String);
        }
      }
      band ??= DayBandCalculator.evaluate(
        minutes: minutes,
        usualMinutes: usualMinutes,
        bands: params.dailyBands,
      );
      return YesterdayResult(
        date: date,
        finalized: true,
        measured: true,
        band: band,
        points: points,
        minutes: minutes,
      );
    } catch (e, st) {
      // 取れなかったことは呼び出し側（HomeController）に伝える。null（記録なし）と区別しないと、
      // カードが「きのうは開かなかった」と事実と違う断定をする（反証レビュー #3）。
      Log.e('loadYesterdayResult failed', error: e, stack: st);
      rethrow;
    }
  }

  /// サーバーの「確定すべき日」（= きのう）。取れなければ [fallbackDate]。
  Future<DateTime> _serverYesterday(DateTime fallbackDate) async {
    try {
      final pending =
          await _ref.read(usageSyncRepositoryProvider).pendingFinalizeDate();
      return pending?.targetDate ?? fallbackDate;
    } catch (e, st) {
      Log.e('pendingFinalizeDate for yesterday failed', error: e, stack: st);
      return fallbackDate;
    }
  }

  static String _dateKey(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$y-$m-$dd';
  }

  /// プレビュー/モック用の「きのうの結果」（◎ +100pt）。本番はこの分岐を通らない。
  YesterdayResult _mockYesterday(DateTime date, EconomyParams params) =>
      YesterdayResult(
        date: date,
        finalized: true,
        measured: true,
        band: DayBand.great,
        points: DayBandCalculator.pointsFor(DayBand.great, params.dailyBands),
        minutes: 25,
      );

  /// プレビュー/モック用スナップショット。**たまごタブと同じモック(eggRepository)の育成中
  /// アクティブ卵を読み**、ホームと たまご の表示を一致させる（ハードコードだとホームだけ
  /// 卵が出て たまご は空、という不整合が起きるため / ユーザーFB）。本番はこの分岐を通らない。
  Future<HomeServerSnapshot> _mockSnapshot(EconomyParams params) async {
    final eggs = await _ref.read(eggRepositoryProvider).loadEggs(params);
    final active = eggs.activeEgg; // is_active な育成中の卵（無ければ null＝空の巣）
    return HomeServerSnapshot(
      pointBalance: 1240,
      gemBalance: 8,
      pooledPoints: eggs.pooledPoints,
      activeEgg: active == null
          ? null
          : ActiveEggSummary(
              eggId: active.id,
              growthPoints: active.growthPoints,
              thresholds: params.eggThresholds,
              rarityLabel: active.rarity.wire,
            ),
      usualMinutes: 120,
      usualMinutesSource: 'reported',
    );
  }

  /// ウォームアップ自動付与（S1 / F-01）をサーバーへ要求する。
  ///
  /// 信頼境界（§2-3 / S1）: 付与（0018: Day1=300 / Day2=孵化までの残り全部）と初回ボーナス卵への
  /// 充当はサーバー RPC `fn_claim_warmup(p_day)` の責務。冪等キーは **生涯1回**（uid×'warmup'×day）
  /// なので、初回体験ごとに無条件に呼んでよい（2回目以降はサーバーが冪等スキップ）。
  ///
  /// Supabase 未設定（Mock 時）/ オフライン時は no-op で null を返し、画面を落とさない
  /// （PoC/UI 確認では warmup はサーバー責務のため何もしない）。失敗時も例外を投げず null。
  Future<WarmupClaimResult?> claimWarmupIfNeeded(int day) async {
    // ⚠️ `useSupabase` であること（`hasSupabase` ではない）。FORCE_MOCK のプレビュー配信は
    //    Supabase 設定を持つため hasSupabase では倒れず、残高はモック表示のまま
    //    **実サーバーの fn_claim_warmup を叩いて生涯1回のウォームアップ枠を焼き切る**。
    //    同クラスの loadServerSnapshot は useSupabase で正しくモックに倒れており、
    //    ここだけ判定が食い違っていた（daily_submission.dart の明文ルール）。
    if (!Env.useSupabase || !_ref.read(isOnlineProvider)) {
      return null; // Mock/オフラインは no-op（サーバー責務）。
    }
    try {
      final client = _ref.read(supabaseClientProvider);
      final res = await client.rpc('fn_claim_warmup', params: {'p_day': day});
      if (res is! Map) return null;
      return WarmupClaimResult.fromJson(res.cast<String, Object?>());
    } catch (e, st) {
      // 付与に失敗しても画面は出す（生涯1回キーなので後続呼び出しで再試行可能）。
      Log.e('claimWarmupIfNeeded failed', error: e, stack: st);
      return null;
    }
  }
}

/// 利用取得の結果（成功/権限なし/取得失敗 を型で表現）。
class HomeUsageResult {
  final UsagePermissionStatus permission;
  final DailyUsage? todayUsage;
  final String? errorMessage;
  final HomeUsageStatus status;

  const HomeUsageResult._({
    required this.permission,
    required this.status,
    this.todayUsage,
    this.errorMessage,
  });

  factory HomeUsageResult.success({
    required UsagePermissionStatus permission,
    required DailyUsage todayUsage,
  }) =>
      HomeUsageResult._(
        permission: permission,
        status: HomeUsageStatus.ok,
        todayUsage: todayUsage,
      );

  factory HomeUsageResult.noPermission(UsagePermissionStatus p) =>
      HomeUsageResult._(permission: p, status: HomeUsageStatus.noPermission);

  factory HomeUsageResult.fetchError(UsagePermissionStatus p, String message) =>
      HomeUsageResult._(
        permission: p,
        status: HomeUsageStatus.fetchError,
        errorMessage: message,
      );
}

enum HomeUsageStatus { ok, noPermission, fetchError }

/// サーバー/キャッシュ由来のスナップショット。
class HomeServerSnapshot {
  final int pointBalance;
  final int gemBalance;
  final int pooledPoints;
  final ActiveEggSummary? activeEgg;

  /// ふだんのSNS時間（profiles.usual_minutes）。未申告・取得不能は null。
  final int? usualMinutes;

  /// 'default' | 'reported' | 'measured'。取得不能は null。
  final String? usualMinutesSource;

  const HomeServerSnapshot({
    required this.pointBalance,
    required this.gemBalance,
    required this.pooledPoints,
    required this.activeEgg,
    this.usualMinutes,
    this.usualMinutesSource,
  });

  /// 未配線/オフライン/取得失敗時の安全なデフォルト（画面を落とさない）。
  static const HomeServerSnapshot empty = HomeServerSnapshot(
    pointBalance: 0,
    gemBalance: 0,
    pooledPoints: 0,
    activeEgg: null,
  );
}

final homeRepositoryProvider = Provider<HomeRepository>((ref) {
  return HomeRepository(ref);
});

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/economy.dart';
import '../../../core/constants/remote_config.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/log.dart';
import '../../../core/observability/observability_providers.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/sync/day_finalized_tick.dart';
import '../../../core/sync/finalize_models.dart';
import '../../../core/usage/usage_provider.dart';
import '../../../core/usage/usage_providers.dart';
import '../../eggs/domain/egg_models.dart';
import '../../eggs/presentation/eggs_controller.dart';
import '../data/home_repository.dart';
import '../data/usual_minutes_repository.dart';
import '../data/warmup_tracker.dart';
import '../domain/home_state.dart';

/// ホームの状態管理（ARCHITECTURE §1-3 / AsyncNotifier）。
///
/// AsyncValue<HomeState> により loading / error が型で強制される（5状態のうち2つを担保）。
/// 権限なし・取得失敗・オフラインは [HomeState] のフラグ + data として返し、
/// 画面側で局所的に 5状態を出し分ける（全画面エラーにしない / SCREEN_FLOWS §2）。
class HomeController extends AsyncNotifier<HomeState> {
  @override
  Future<HomeState> build() async {
    return _load();
  }

  Future<HomeState> _load() async {
    final repo = ref.read(homeRepositoryProvider);
    final params = await ref.watch(economyParamsProvider.future);
    final targets = ref.read(targetPackagesProvider);
    final isOnline = ref.watch(isOnlineProvider);
    final now = DateTime.now();

    // 前日分のサーバー確定（DailySubmissionService）が成功したら再取得する。
    // 確定は起動/復帰の裏で走るため、これが無いと「ptが入ったのに画面が古いまま」
    // になり、次回起動か手動 pull-to-refresh まで獲得結果が見えない。
    ref.watch(dayFinalizedTickProvider);

    // 「ふだんのSNS時間」の未同期の申告があれば先に送る（オフライン等なら no-op）。
    final usualRepo = ref.read(usualMinutesRepositoryProvider);
    await usualRepo.syncPending();

    // F-01 ウォームアップ自動付与（S1）。
    // 信頼境界（§2-3）: 付与の正はサーバー RPC。クライアントは「いつ Day1/Day2 を呼ぶか」を
    // ローカル初回起動日から粗く決めて呼ぶだけ（冪等キーは生涯1回なので二重呼びは安全）。
    // 0018: Day2 は「初回起動日より後に最初に開いた日」（翌日限定をやめた）。
    // 5状態: 付与成功=祝福 / 未対象=通常 / オフライン=後で再試行 / エラー=黙って通常表示。
    final tracker = ref.read(warmupTrackerProvider);
    final day = await tracker.resolveWarmupDay(now);
    final warmupGrant = await _claimWarmup(repo, tracker, day);
    if (warmupGrant != null) {
      // 新規付与があれば卵が育っている。ホームもたまごタブも eggsController を単一情報源に
      // しているので、そこを作り直して両方を最新にする（ホームだけ古い、を作らない）。
      ref.invalidate(eggsControllerProvider);
    }

    // 育成中アクティブ卵は「たまごタブと同じ eggsController」を単一情報源にする。
    // これで枠移動/孵化にホームも自動追従し、「ホームだけ古い/幻の卵が残る」不整合を根治
    // （mock/本番どちらも同じ状態を見る / ユーザーFB 再発分）。
    // 卵の取得失敗でホーム全体を落とさない（卵は無しとして続行）。watch は依存を張るので、
    // 卵が変わればホームも再構築される。
    EggsState? eggsState;
    try {
      eggsState = await ref.watch(eggsControllerProvider.future);
    } catch (_) {
      eggsState = null;
    }
    final activeEgg = eggsState == null
        ? null
        : _toActiveSummary(eggsState.activeEgg, params);

    // サーバー/キャッシュ（通貨残高・ふだんのSNS時間）は権限の有無に関わらず取得。
    final snapshot = await repo.loadServerSnapshot(params);

    // R: サーバー → 端末の申告 → 既定（docs/design/EGG_PACING_DESIGN.md §2-1）。
    final local = await usualRepo.localReported();
    final usualMinutes =
        snapshot.usualMinutes ?? local ?? params.usualMinutesDefault;
    final usualSource = snapshot.usualMinutesSource ??
        (local != null ? 'reported' : 'default');

    // 利用取得（権限なし/失敗でも画面は出す）。
    final usage = await repo.loadUsage(targetPackages: targets, now: now);

    // きのうの結果。
    // 「きのう」はサーバーの経済日付（profiles.timezone＝Asia/Tokyo に正規化 / 0011）で決まる。
    // リポジトリが読み込むたびにサーバーへ「確定すべき日」を聞き直す（端末ローカルの「昨日」は
    // 使わない。第三者レビュー: 海外滞在・TZ 変更・時計ずれで別の日を引き「開かなかった」と
    // 誤表示し得た / 値を持ち回ると日跨ぎで古くなる）。聞けないときの代用だけ JST の暦日。
    // 初日判定もローカルの初回起動日だけで決めず、再インストール等で結果があればそちらを優先。
    final yesterday = await repo.loadYesterdayResult(
      fallbackDate: _jstToday(now).subtract(const Duration(days: 1)),
      usualMinutes: usualMinutes,
      params: params,
      localFirstDay: day == 1,
    );
    final isFirstDay = day == 1 && yesterday == null;

    return HomeState(
      permission: usage.permission,
      todayUsage: usage.todayUsage,
      usageErrorMessage: usage.errorMessage,
      usualMinutes: usualMinutes,
      usualMinutesSource: usualSource,
      yesterday: yesterday,
      isFirstDay: isFirstDay,
      activeEgg: activeEgg,
      pointBalance: snapshot.pointBalance,
      gemBalance: snapshot.gemBalance,
      pooledPoints: snapshot.pooledPoints,
      isOffline: !isOnline,
      params: params,
      warmupGrant: warmupGrant,
    );
  }

  /// サーバーの経済日付（Asia/Tokyo の暦日）の代用。本アプリは日本のみ配信で、
  /// profiles.timezone は 0011 で 'Asia/Tokyo' に正規化されている（他の値は不正）。
  /// UTC の DateTime で返す: 端末ローカルで作ると、夏時間のある地域では 1 日引いた結果が
  /// 2 日前に落ちることがある（切替の翌日は 1 日が 23 時間）。
  DateTime _jstToday(DateTime now) {
    final jst = now.toUtc().add(const Duration(hours: 9));
    return DateTime.utc(jst.year, jst.month, jst.day);
  }

  /// たまごの Egg → ホーム表示用 ActiveEggSummary（無ければ null＝空の巣）。
  ActiveEggSummary? _toActiveSummary(Egg? egg, EconomyParams params) {
    if (egg == null) return null;
    return ActiveEggSummary(
      eggId: egg.id,
      growthPoints: egg.growthPoints,
      thresholds: params.eggThresholds,
      rarityLabel: egg.rarity.wire,
    );
  }

  /// ウォームアップ Day（1|2）で付与要求し、**新規付与時のみ**祝福サマリを返す。
  ///
  /// 受取済み（生涯1回キーの冪等スキップ）/ 未対象 / オフライン / エラーは null
  /// （= 通常ホーム。責めない・黙って通常表示 / 受け入れ §5-1）。
  /// Day2 はサーバーが付与した、または受取済みと答えたら端末に記録し、以後は呼ばない。
  Future<WarmupGrantSummary?> _claimWarmup(
    HomeRepository repo,
    WarmupTracker tracker,
    int? day,
  ) async {
    if (day == null) return null; // ウォームアップ卒業。

    final WarmupClaimResult? res = await repo.claimWarmupIfNeeded(day);
    // null = Mock/オフライン/エラー（no-op）。再試行は次回ロードで可能（生涯1回キー）。
    if (res == null) return null;
    if (day == 2 && (res.granted > 0 || res.alreadyClaimed)) {
      // 付与した、または「もう付与しない」（受取済み／生涯上限／残り全部が 0 = 初回ボーナス卵が
      // 既に孵化できる）。どちらも終端なので記録し、以後の起動で day2 を呼ばない（0018）。
      await tracker.markDay2Claimed();
    }
    // 新規付与（granted>0）でのみ祝福を出す。冪等スキップ（既受取）は通常ホーム。
    if (res.granted <= 0 || res.alreadyClaimed) return null;
    return WarmupGrantSummary(day: res.day, grantedPoints: res.granted);
  }

  /// pull-to-refresh / 権限付与後の再取得。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// 権限要求（OS設定へ誘導）後に再読込する。画面の再付与ボタンから呼ぶ。
  Future<void> requestPermissionAndReload() async {
    final usageProvider = ref.read(usageProviderProvider);
    await usageProvider.requestPermission();
    await refresh();
  }

  /// 【2026-10-05 追加】対象アプリ（iOS の「見守るアプリ」）を選び直して再読込する。
  ///
  /// 権限はあるのに対象アプリが未選択だと **永久に0分**になる。ホームの案内から
  /// メニューを探させずに、その場で OS のピッカーを開くための入口。
  /// 選択という概念が無い実装（Android 等）では何もしない。
  Future<void> pickAppsAndReload() async {
    final usageProvider = ref.read(usageProviderProvider);
    if (usageProvider is! ScreenTimeAppSelection) return;
    // ScreenTimeAppSelection は UsageProvider のサブタイプではないため型プロモーションが
    // 効かない。is! ガード済みなので明示キャストは安全（target_apps_screen.dart と同じ）。
    final selection = usageProvider as ScreenTimeAppSelection;
    try {
      final result = await selection.presentAppPicker();
      // 未選択からの復帰を数える（この案内に意味があったかはここでしか分からない）。
      if (result.selected) {
        ref.read(analyticsProvider).capture(
          AnalyticsEvents.targetAppsSelected,
          properties: const {AnalyticsProps.source: 'home'},
        );
      }
    } catch (e, st) {
      // ピッカーが開けなくても画面は落とさない（次回の案内から再試行できる）。
      Log.e('presentAppPicker failed', error: e, stack: st);
    }
    // 選択状態のキャッシュを捨てて、バナーの出し分けを即座に更新する。
    ref.invalidate(hasAppSelectionProvider);
    await refresh();
  }

  /// 【0018】「ふだんのSNS時間」を申告して再読込する（既存ユーザーへの1回だけのシート用）。
  ///
  /// [minutes] が null ならスキップ（既定値のまま。次回は出さない）。
  Future<void> reportUsualMinutes(int? minutes) async {
    final usualRepo = ref.read(usualMinutesRepositoryProvider);
    if (minutes == null) {
      await usualRepo.markAsked();
    } else {
      await usualRepo.report(minutes);
    }
    ref.read(analyticsProvider).capture(
      AnalyticsEvents.usualMinutesReported,
      properties: {
        if (minutes != null) AnalyticsProps.minutes: minutes,
        AnalyticsProps.skipped: minutes == null,
      },
    );
    await refresh();
  }
}

/// ホームコントローラの Provider。
final homeControllerProvider =
    AsyncNotifierProvider<HomeController, HomeState>(HomeController.new);

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart' hide Baseline;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/navigation/bottom_nav_scaffold.dart';
import 'package:moffy/core/observability/analytics.dart';
import 'package:moffy/core/observability/analytics_events.dart';
import 'package:moffy/core/observability/observability_providers.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/core/usage/point_calculator.dart';
import 'package:moffy/core/usage/usage_models.dart';
import 'package:moffy/core/usage/usage_provider.dart';
import 'package:moffy/core/usage/usage_providers.dart';
import 'package:moffy/features/home/domain/home_state.dart';
import 'package:moffy/features/home/presentation/home_controller.dart';
import 'package:moffy/features/home/presentation/widgets/active_egg_panel.dart';
import 'package:moffy/features/home/presentation/widgets/reduction_card.dart';
import 'package:moffy/features/onboarding/data/onboarding_repository.dart';
import 'package:moffy/features/onboarding/presentation/onboarding_screen.dart';
import 'package:moffy/features/onboarding/presentation/welcome_screen.dart';

/// 「未選択で進まない」「孵化できるのに放置」の2つを潰した改善の回帰テスト
/// （2026-10-05 / ORG_STATE の実測を受けた修正）。
///
/// 実測で分かっていた事実:
///   * 削減ptを得たのは全期間で6人だけ。オーナー自身の iOS アカウントも3か月ずっと
///     `total_minutes=0 / per_app_minutes={}`（＝対象アプリ未選択）だった。
///     権限はあるのでホームは何の警告も出さず、「自分が使っていないから0」と誤解する。
///   * 500pt を超えた卵が2個、数週間〜数か月放置されていた。孵化はタップしないと
///     起きないのに、ホームには**ボタンが無く**気づかせる仕組みもなかった。
///
/// ここで固定するのは「気づける表示が出ること」そのもの。消えたら実害が戻る。
void main() {
  Future<void> withPlatform(
    TargetPlatform p,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = p;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  group('ホームの削減カード: 対象アプリ未選択を知らせる', () {
    Widget card({
      required UsagePermissionStatus permission,
      required bool hasAppSelection,
      VoidCallback? onPickApps,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: ReductionCard(
              state: _homeState(permission: permission),
              onRequestPermission: () {},
              hasAppSelection: hasAppSelection,
              onPickApps: onPickApps,
            ),
          ),
        );

    testWidgets('権限ありで未選択なら、理由と「アプリを選ぶ」が出る', (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        var picked = 0;
        await tester.pumpWidget(
          card(
            permission: UsagePermissionStatus.granted,
            hasAppSelection: false,
            onPickApps: () => picked++,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('見守るアプリが選ばれていません'), findsOneWidget);
        await tester.tap(find.text('アプリを選ぶ'));
        expect(picked, 1); // メニューを探させず、その場でピッカーへ
      });
    });

    testWidgets('選択済みなら案内を出さない（通常のカードに戻る）', (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(
          card(
            permission: UsagePermissionStatus.granted,
            hasAppSelection: true,
            onPickApps: () {},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('見守るアプリが選ばれていません'), findsNothing);
        expect(find.text('明日から計測スタート'), findsOneWidget);
      });
    });

    testWidgets('権限なしが未選択より優先される（先に許可の話をする）', (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(
          card(
            permission: UsagePermissionStatus.denied,
            hasAppSelection: false,
            onPickApps: () {},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('見守るアプリが選ばれていません'), findsNothing);
        expect(find.textContaining('スクリーンタイム'), findsOneWidget);
      });
    });

    testWidgets('選択の概念が無い実装（onPickApps=null）では案内を出さない', (tester) async {
      // Android は権限だけで端末全体を見られる。押しても何も起きない案内は出さない。
      await withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(
          card(
            permission: UsagePermissionStatus.granted,
            hasAppSelection: false,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('見守るアプリが選ばれていません'), findsNothing);
        expect(find.text('アプリを選ぶ'), findsNothing);
      });
    });
  });

  group('ホームの巣パネル: 孵化できるなら、その場で孵化へ送る', () {
    Widget panel({required int growth, VoidCallback? onHatch}) => MaterialApp(
          home: Scaffold(
            body: ActiveEggPanel(
              state: _homeState(
                permission: UsagePermissionStatus.granted,
                egg: ActiveEggSummary(
                  eggId: 'e1',
                  growthPoints: growth,
                  hatchThreshold: 500,
                  rarityLabel: 'normal',
                ),
              ),
              onSetEgg: () {},
              onHatch: onHatch,
            ),
          ),
        );

    testWidgets('残り0ptなら「孵化できます！」と「孵化する」が出る', (tester) async {
      var hatched = 0;
      await tester.pumpWidget(panel(growth: 500, onHatch: () => hatched++));
      await tester.pumpAndSettle();

      expect(find.text('孵化できます！'), findsOneWidget);
      await tester.tap(find.text('孵化する'));
      expect(hatched, 1);
    });

    testWidgets('しきい値を超えて貯まっていても孵化できる扱いにする', (tester) async {
      // 実測で放置されていた卵は 500pt を**超えて**いた（remaining は clamp 済み）。
      await tester.pumpWidget(panel(growth: 780, onHatch: () {}));
      await tester.pumpAndSettle();

      expect(find.text('孵化できます！'), findsOneWidget);
      expect(find.text('孵化する'), findsOneWidget);
    });

    testWidgets('まだ育ち途中なら孵化ボタンを出さない', (tester) async {
      await tester.pumpWidget(panel(growth: 460, onHatch: () {}));
      await tester.pumpAndSettle();

      expect(find.text('孵化まであと 40pt'), findsOneWidget);
      expect(find.text('孵化する'), findsNothing);
    });
  });

  group('下タブのバッジ: 孵化できる卵があるかの判定', () {
    ProviderContainer containerFor(HomeState state) {
      final c = ProviderContainer(
        overrides: [
          homeControllerProvider.overrideWith(() => _FakeHomeController(state)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('残り0ptの卵があれば true', () async {
      final c = containerFor(
        _homeState(
          permission: UsagePermissionStatus.granted,
          egg: const ActiveEggSummary(
            eggId: 'e1',
            growthPoints: 500,
            hatchThreshold: 500,
            rarityLabel: 'normal',
          ),
        ),
      );
      await c.read(homeControllerProvider.future);
      expect(c.read(hasHatchableEggProvider), isTrue);
    });

    test('育ち途中なら false', () async {
      final c = containerFor(
        _homeState(
          permission: UsagePermissionStatus.granted,
          egg: const ActiveEggSummary(
            eggId: 'e1',
            growthPoints: 499,
            hatchThreshold: 500,
            rarityLabel: 'normal',
          ),
        ),
      );
      await c.read(homeControllerProvider.future);
      expect(c.read(hasHatchableEggProvider), isFalse);
    });

    test('卵が無ければ false', () async {
      final c = containerFor(
        _homeState(permission: UsagePermissionStatus.granted),
      );
      await c.read(homeControllerProvider.future);
      expect(c.read(hasHatchableEggProvider), isFalse);
    });

    test('ホームの読み込みが終わる前は false（追加の通信をしない）', () {
      final c = containerFor(
        _homeState(permission: UsagePermissionStatus.granted),
      );
      expect(c.read(hasHatchableEggProvider), isFalse);
    });
  });

  group('計測: 対象アプリを選ばずに始めた人を数える', () {
    late _RecordingAnalytics analytics;

    Widget harness(UsageProvider usage) {
      analytics = _RecordingAnalytics();
      return ProviderScope(
        overrides: [
          usageProviderProvider.overrideWithValue(usage),
          isOnlineProvider.overrideWithValue(true),
          analyticsProvider.overrideWithValue(analytics),
          onboardingRepositoryProvider
              .overrideWithValue(_FakeOnboardingRepository()),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: OnboardingScreen.routePath,
            routes: [
              GoRoute(
                path: OnboardingScreen.routePath,
                builder: (_, __) => const OnboardingScreen(),
              ),
              GoRoute(
                path: WelcomeScreen.routePath,
                builder: (_, __) =>
                    const Scaffold(body: Center(child: Text('welcome-stub'))),
              ),
            ],
          ),
        ),
      );
    }

    /// 対象選択ページ（4ページ目）まで進める。
    ///
    /// 権限ページのボタンだけ OS で文言が違う（iOS=「次へ」/ Android=「設定を開く」）。
    /// 5.1.1(iv) 対応でこの文言自体が審査条件なので、テスト側で決め打ちにはしない。
    Future<void> goToPickerPage(
      WidgetTester tester, {
      required String grantLabel,
    }) async {
      await tester.tap(find.text('はじめる').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text('次へ').hitTestable());
      await tester.pumpAndSettle();
      await tester.tap(find.text(grantLabel).hitTestable());
      await tester.pumpAndSettle();
    }

    testWidgets('未選択のまま始めたら target_apps_skipped（許可ありを区別できる）',
        (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(harness(_FakeUsage(selected: false)));
        await tester.pumpAndSettle();
        await goToPickerPage(tester, grantLabel: '次へ');

        await tester.tap(find.text('あとで選んで始める').hitTestable());
        await tester.pumpAndSettle();

        final e = analytics.single(AnalyticsEvents.targetAppsSkipped);
        expect(e.props?[AnalyticsProps.permissionGranted], isTrue);
        expect(analytics.names, contains(AnalyticsEvents.onboardingCompleted));
        expect(
          analytics.names,
          isNot(contains(AnalyticsEvents.targetAppsSelected)),
        );
      });
    });

    testWidgets('許可が無くて選べなかった場合は permission_granted=false',
        (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(
          harness(
            _FakeUsage(
              selected: false,
              status: UsagePermissionStatus.permanentlyDenied,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await goToPickerPage(tester, grantLabel: '次へ');

        await tester.tap(find.text('あとで選んで始める').hitTestable());
        await tester.pumpAndSettle();

        final e = analytics.single(AnalyticsEvents.targetAppsSkipped);
        expect(e.props?[AnalyticsProps.permissionGranted], isFalse);
      });
    });

    testWidgets('選んで始めたら target_apps_selected（source=onboarding）',
        (tester) async {
      await withPlatform(TargetPlatform.iOS, () async {
        await tester.pumpWidget(harness(_FakeUsage(selected: true, count: 3)));
        await tester.pumpAndSettle();
        await goToPickerPage(tester, grantLabel: '次へ');

        await tester.tap(find.text('アプリを選ぶ').hitTestable());
        await tester.pumpAndSettle();
        await tester.tap(find.text('Moffyをはじめる（3件を見守る）').hitTestable());
        await tester.pumpAndSettle();

        final e = analytics.single(AnalyticsEvents.targetAppsSelected);
        expect(e.props?[AnalyticsProps.source], 'onboarding');
        expect(
          analytics.names,
          isNot(contains(AnalyticsEvents.targetAppsSkipped)),
        );
      });
    });

    testWidgets('Android では送らない（選択の概念が無く母数を汚す）', (tester) async {
      await withPlatform(TargetPlatform.android, () async {
        await tester.pumpWidget(harness(_FakeUsage(selected: false)));
        await tester.pumpAndSettle();
        await goToPickerPage(tester, grantLabel: '設定を開く');

        await tester.tap(find.text('Moffyをはじめる').hitTestable());
        await tester.pumpAndSettle();

        expect(
          analytics.names,
          isNot(contains(AnalyticsEvents.targetAppsSkipped)),
        );
        expect(
          analytics.names,
          isNot(contains(AnalyticsEvents.targetAppsSelected)),
        );
        expect(analytics.names, contains(AnalyticsEvents.onboardingCompleted));
      });
    });
  });

  group('対象アプリ選択の判定プロバイダ', () {
    test('選択の概念が無い実装では true（誤警告を出さない）', () async {
      final c = ProviderContainer(
        overrides: [
          usageProviderProvider
              .overrideWithValue(const UnsupportedUsageProvider()),
        ],
      );
      addTearDown(c.dispose);
      expect(await c.read(hasAppSelectionProvider.future), isTrue);
    });

    test('iOS 実装の返り値をそのまま使う', () async {
      final c = ProviderContainer(
        overrides: [
          usageProviderProvider.overrideWithValue(_FakeUsage(selected: false)),
        ],
      );
      addTearDown(c.dispose);
      expect(await c.read(hasAppSelectionProvider.future), isFalse);
    });

    test('判定が失敗したら true に倒す（警告を誤爆させない）', () async {
      final c = ProviderContainer(
        overrides: [
          usageProviderProvider.overrideWithValue(_ThrowingSelectionUsage()),
        ],
      );
      addTearDown(c.dispose);
      expect(await c.read(hasAppSelectionProvider.future), isTrue);
    });
  });
}

HomeState _homeState({
  required UsagePermissionStatus permission,
  ActiveEggSummary? egg,
}) =>
    HomeState(
      permission: permission,
      todayUsage: null,
      baseline: Baseline(
        date: DateTime(2026, 10, 5),
        rawAverageMinutes: null,
        appliedMinutes: 30,
        sampleDays: 0,
        stage: BaselineStage.warmup,
      ),
      provisionalPoints: 0,
      yesterdayMinutes: null,
      activeEgg: egg,
      pointBalance: 0,
      gemBalance: 0,
      pooledPoints: 0,
      isOffline: false,
      params: EconomyParams.defaults,
    );

/// build() が差し替えた状態をそのまま返すだけのホームコントローラ。
class _FakeHomeController extends HomeController {
  _FakeHomeController(this._state);
  final HomeState _state;

  @override
  Future<HomeState> build() async => _state;
}

/// capture された内容を覚えておくだけの Analytics。
class _RecordingAnalytics implements Analytics {
  final List<_Captured> captured = [];

  List<String> get names => captured.map((e) => e.event).toList();

  /// 指定イベントが**1回だけ**記録されていることを確かめ、その中身を返す。
  _Captured single(String event) {
    final hits = captured.where((e) => e.event == event).toList();
    expect(hits, hasLength(1), reason: '$event は1回だけ送られるべき');
    return hits.first;
  }

  @override
  void capture(String event, {Map<String, Object>? properties}) {
    captured.add(_Captured(event, properties));
  }

  @override
  void identifyAnonymous(String anonymousUserId) {}

  @override
  void reset() {}
}

class _Captured {
  const _Captured(this.event, this.props);
  final String event;
  final Map<String, Object>? props;
}

class _FakeOnboardingRepository implements OnboardingRepository {
  @override
  Future<bool> isCompleted() async => false;

  @override
  Future<void> markCompleted() async {}
}

/// 権限状態とピッカーの結果を指定できる fake。
class _FakeUsage implements UsageProvider, ScreenTimeAppSelection {
  _FakeUsage({
    required this.selected,
    this.count = 0,
    this.status = UsagePermissionStatus.granted,
  });

  final bool selected;
  final int count;
  final UsagePermissionStatus status;

  @override
  UsageMode get mode => UsageMode.thresholdAchievement;

  @override
  Future<UsagePermissionStatus> checkPermission() async => status;

  @override
  Future<UsagePermissionStatus> requestPermission() async => status;

  @override
  Future<DailyUsage> fetchDailyUsage({
    required DateTime date,
    required List<String> targetPackages,
  }) async =>
      DailyUsage(
        date: date,
        perAppMinutes: const {},
        totalMinutes: 0,
        mode: UsageMode.thresholdAchievement,
      );

  @override
  Future<List<DailyUsage>> fetchUsageRange({
    required DateTime startDate,
    required DateTime endDate,
    required List<String> targetPackages,
  }) async =>
      const [];

  @override
  Future<ScreenTimeSelectionResult> presentAppPicker() async =>
      ScreenTimeSelectionResult(selected: selected, count: count);

  @override
  Future<bool> hasAppSelection() async => selected;
}

/// hasAppSelection が例外を投げる fake（ネイティブ未実装・チャネル障害）。
class _ThrowingSelectionUsage extends _FakeUsage {
  _ThrowingSelectionUsage() : super(selected: false);

  @override
  Future<bool> hasAppSelection() async => throw StateError('channel down');
}

import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/observability/analytics.dart';
import 'package:moffy/core/observability/observability_providers.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/core/usage/point_calculator.dart';
import 'package:moffy/core/usage/usage_models.dart';
import 'package:moffy/core/usage/usage_provider.dart';
import 'package:moffy/core/usage/usage_providers.dart';
import 'package:moffy/features/home/domain/home_state.dart';
import 'package:moffy/features/home/presentation/widgets/reduction_card.dart';
import 'package:moffy/features/onboarding/presentation/onboarding_screen.dart';

/// 権限まわりの回帰テスト（App Store Guideline 5.1.1(iv) / 2.1）。
///
/// 背景:
///   iOS 1.1.0 (build 26) が **5.1.1(iv)** で却下された。Apple の指摘は2点:
///     1. OS の許可ダイアログを出す**前**の画面のボタンが「許可する」だった
///        → "Continue"/"Next" 相当にせよ
///     2. 「あとで設定する」で**権限要求そのものを先送り**できた
///        → 説明を読んだら必ず OS の要求まで進ませよ
///
///   修正後に第三者レビューを回したところ、**逃げ道を撤去したこと自体が新しい
///   行き止まりを作っていた**ことが判明した（要求中の画面には押せる要素がゼロで、
///   OS の要求が返らないと永久に固まる）。さらに、拒否した iOS ユーザーが全員
///   「押しても無反応のボタン」へ流し込まれる構造になっていた。
///
/// なぜこのテストが要るか:
///   `test/` にオンボーディングのテストは**1本も無かった**。CI の全通過は
///   この画面について何も保証していなかった。「あとで設定する」が将来こっそり
///   復活しても誰も止められない。**文言そのものが審査条件**なので文言を固定する。
void main() {
  /// テスト後に必ず戻す（他テストへ漏らさない）。
  void usePlatform(TargetPlatform p) {
    debugDefaultTargetPlatformOverride = p;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
  }

  Widget harness(UsageProvider usage) {
    return ProviderScope(
      overrides: [
        usageProviderProvider.overrideWithValue(usage),
        isOnlineProvider.overrideWithValue(true),
        analyticsProvider.overrideWithValue(const NoopAnalytics()),
      ],
      child: const MaterialApp(home: OnboardingScreen()),
    );
  }

  /// 権限ページ（3ページ目）まで進める。OB1 →「次へ」→ OB2 →「次へ」。
  Future<void> goToPermissionPage(WidgetTester tester) async {
    await tester.tap(find.text('次へ').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('次へ').first);
    await tester.pumpAndSettle();
  }

  group('5.1.1(iv) の指摘そのものを固定する', () {
    testWidgets('前置き画面に「許可する」「あとで設定する」が存在しない', (tester) async {
      usePlatform(TargetPlatform.iOS);
      await tester
          .pumpWidget(harness(_FakeUsage(UsagePermissionStatus.granted)));
      await tester.pumpAndSettle();
      await goToPermissionPage(tester);

      // ここが再発したら Apple に再び却下される。
      expect(find.text('許可する'), findsNothing);
      expect(find.text('あとで設定する'), findsNothing);
      // 見出しの誘導語も戻さない（B-6）。
      expect(find.text('スクリーンタイムを許可'), findsNothing);
    });

    testWidgets('iOS はボタンが「次へ」', (tester) async {
      usePlatform(TargetPlatform.iOS);
      await tester
          .pumpWidget(harness(_FakeUsage(UsagePermissionStatus.granted)));
      await tester.pumpAndSettle();
      await goToPermissionPage(tester);
      expect(find.text('次へ'), findsWidgets);
    });

    testWidgets('Android はボタンが「設定を開く」', (tester) async {
      usePlatform(TargetPlatform.android);
      await tester
          .pumpWidget(harness(_FakeUsage(UsagePermissionStatus.denied)));
      await tester.pumpAndSettle();
      await goToPermissionPage(tester);
      expect(find.text('設定を開く'), findsOneWidget);
    });
  });

  group('行き止まりを作らない（Guideline 2.1）', () {
    testWidgets('拒否されても次のページへ進む', (tester) async {
      usePlatform(TargetPlatform.iOS);
      await tester.pumpWidget(
        harness(_FakeUsage(UsagePermissionStatus.permanentlyDenied)),
      );
      await tester.pumpAndSettle();
      await goToPermissionPage(tester);

      await tester.tap(find.text('次へ').first);
      await tester.pumpAndSettle();
      expect(find.text('見守るアプリを選ぼう'), findsOneWidget);
    });

    testWidgets('MissingPluginException が飛んでも進む（catch の存在を固定）',
        (tester) async {
      usePlatform(TargetPlatform.iOS);
      await tester.pumpWidget(harness(_ThrowingUsage()));
      await tester.pumpAndSettle();
      await goToPermissionPage(tester);

      await tester.tap(find.text('次へ').first);
      await tester.pumpAndSettle();
      expect(find.text('見守るアプリを選ぼう'), findsOneWidget);
    });

    testWidgets('OS の要求が返ってこなくても閉じ込められない（timeout の存在を固定）',
        (tester) async {
      // これは B-1 の受け入れ条件。`.timeout()` を外すとこのテストは落ちる。
      usePlatform(TargetPlatform.iOS);
      await tester.pumpWidget(harness(_HangingUsage()));
      await tester.pumpAndSettle();
      await goToPermissionPage(tester);

      await tester.tap(find.text('次へ').first);
      await tester.pump(); // 要求中（押せる要素が無い状態）へ
      await tester.pump(const Duration(seconds: 31)); // タイムアウトを跨ぐ
      await tester.pumpAndSettle();

      expect(find.text('見守るアプリを選ぼう'), findsOneWidget);
    });
  });

  group('拒否した iOS ユーザーが無言の行き止まりに落ちない（B-2 / B-3）', () {
    testWidgets('未許可のままピッカーページに来たら理由が常設表示される', (tester) async {
      usePlatform(TargetPlatform.iOS);
      await tester.pumpWidget(
        harness(_FakeUsage(UsagePermissionStatus.permanentlyDenied)),
      );
      await tester.pumpAndSettle();
      await goToPermissionPage(tester);
      await tester.tap(find.text('次へ').first);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('スクリーンタイムが許可されていないため'),
        findsOneWidget,
      );
      // 「このまま始められる」という安心も必ず出す
      // （権限ページのフォールバック文言は自動遷移のせいで誰にも読まれなかった）。
      expect(find.textContaining('このまま始められます'), findsOneWidget);
    });
  });

  group('ホームの権限カード（B-4 / B-5）', () {
    Widget card(UsagePermissionStatus s) => MaterialApp(
          home: Scaffold(
            body: ReductionCard(
              state: _homeState(s),
              onRequestPermission: () {},
            ),
          ),
        );

    testWidgets('iOS に Android 専用の設定名を出さない', (tester) async {
      usePlatform(TargetPlatform.iOS);
      await tester.pumpWidget(card(UsagePermissionStatus.denied));
      await tester.pumpAndSettle();
      // iOS にこの設定は存在しない。
      expect(find.textContaining('使用状況へのアクセス'), findsNothing);
      expect(find.textContaining('スクリーンタイム'), findsOneWidget);
    });

    testWidgets('恒久拒否では押せないボタンを出さない', (tester) async {
      usePlatform(TargetPlatform.iOS);
      await tester.pumpWidget(card(UsagePermissionStatus.permanentlyDenied));
      await tester.pumpAndSettle();
      // OS はもう確認画面を出さない。押しても何も起きないボタンは出荷しない。
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.textContaining('設定 > スクリーンタイム'), findsOneWidget);
    });

    testWidgets('「許可する」というラベルは使わない', (tester) async {
      usePlatform(TargetPlatform.android);
      await tester.pumpWidget(card(UsagePermissionStatus.denied));
      await tester.pumpAndSettle();
      expect(find.text('許可する'), findsNothing);
    });
  });
}

HomeState _homeState(UsagePermissionStatus permission) => HomeState(
      permission: permission,
      todayUsage: null,
      baseline: Baseline(
        date: DateTime(2026, 8, 18),
        rawAverageMinutes: null,
        appliedMinutes: 30,
        sampleDays: 0,
        stage: BaselineStage.warmup,
      ),
      provisionalPoints: 0,
      yesterdayMinutes: null,
      activeEgg: null,
      pointBalance: 0,
      gemBalance: 0,
      pooledPoints: 0,
      isOffline: false,
      params: EconomyParams.defaults,
    );

/// 指定した権限状態を返すだけの fake。ピッカーは「未選択」を返す。
class _FakeUsage implements UsageProvider, ScreenTimeAppSelection {
  _FakeUsage(this.status);
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
      const ScreenTimeSelectionResult(selected: false, count: 0);

  @override
  Future<bool> hasAppSelection() async => false;
}

/// requestPermission が例外を投げる fake（プラグイン未実装など）。
class _ThrowingUsage extends _FakeUsage {
  _ThrowingUsage() : super(UsagePermissionStatus.denied);

  @override
  Future<UsagePermissionStatus> requestPermission() async =>
      throw MissingPluginException('no impl');
}

/// requestPermission が**永久に返らない** fake（OS 要求が詰まった状況）。
class _HangingUsage extends _FakeUsage {
  _HangingUsage() : super(UsagePermissionStatus.denied);

  @override
  Future<UsagePermissionStatus> requestPermission() =>
      Completer<UsagePermissionStatus>().future;
}

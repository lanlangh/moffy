import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:moffy/core/iap/iap_models.dart';
import 'package:moffy/core/iap/iap_providers.dart';
import 'package:moffy/core/iap/server_entitlement.dart';
import 'package:moffy/core/navigation/app_tab.dart';
import 'package:moffy/core/navigation/bottom_nav_scaffold.dart';
import 'package:moffy/core/navigation/tab_scroll.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/features/eggs/presentation/eggs_screen.dart';
import 'package:moffy/features/eggs/presentation/widgets/egg_detail_sheet.dart';

/// 2026-10-26 のオーナー報告2件を固定する。
///   1. 卵の詳細シートを開くと、iPhone で元の画面に戻れなかった
///      （中身が画面より高いとシートが全面に広がり、外側をタップする場所が無くなる。
///      下へ引く操作も中身のスクロールに取られる。閉じるボタンも無かった）。
///   2. 開いているタブをもう一度押したら、そのページの先頭へ戻ってほしい。
void main() {
  // 課金の状態は固定する（RevenueCat などのプラグインを呼ばせない）。
  final premiumOverrides = [
    premiumStatusProvider.overrideWith(
      (ref) => Stream.value(
        const PremiumStatus(isPremium: true, source: PremiumSource.mock),
      ),
    ),
    serverPremiumProvider.overrideWith((ref) async => null),
    isPremiumProvider.overrideWithValue(true),
  ];

  group('卵の詳細シート', () {
    /// 本番に近い形で出す: 下タブのシェルの中に たまご画面、上にステータスバー、下にホームバー。
    /// 以前はタブもステータスバーも無い状態で確かめていて、iPhone で「閉じる」が
    /// ステータスバーと重なる不具合（2026-10-26 TestFlight）を見逃した。
    Future<void> pumpEggsInShell(WidgetTester tester) async {
      // iPhone SE 相当の幅に、ノッチ付き端末のステータスバー(47)とホームバー(34)。
      tester.view.physicalSize = const Size(750, 1334);
      tester.view.devicePixelRatio = 2;
      tester.view.padding = const FakeViewPadding(top: 94, bottom: 68);
      tester.view.viewPadding = const FakeViewPadding(top: 94, bottom: 68);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isOnlineProvider.overrideWithValue(true),
            hasHatchableEggProvider.overrideWithValue(false),
            ...premiumOverrides,
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              initialLocation: AppTab.eggs.path,
              routes: [
                StatefulShellRoute.indexedStack(
                  builder: (context, state, shell) => BottomNavScaffold(
                    currentIndex: shell.currentIndex,
                    onTap: (_) {},
                    child: shell,
                  ),
                  branches: [
                    StatefulShellBranch(
                      routes: [
                        GoRoute(
                          path: AppTab.eggs.path,
                          builder: (_, __) => const EggsScreen(),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // 主役ステージの卵（モックは 350pt＝次の変化まで あと 150pt）をタップ。
      await tester.tap(find.textContaining('次の変化まで').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(EggDetailSheet), findsOneWidget);
    }

    testWidgets('タブとステータスバーがあっても、上に余白が残り「閉じる」が隠れない',
        (tester) async {
      await pumpEggsInShell(tester);

      // シートの上端はステータスバー(47)より十分下＝外側をタップできる余白が残る。
      final top = tester.getTopLeft(find.byType(EggDetailSheet)).dy;
      expect(top, greaterThanOrEqualTo(47 + 40));
      // 「閉じる」もステータスバーの下にある。
      final close = tester.getTopLeft(find.byTooltip('閉じる')).dy;
      expect(close, greaterThan(47));

      await tester.tap(find.byTooltip('閉じる'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(EggDetailSheet), findsNothing);
      expect(find.text('育成枠'), findsOneWidget); // 元の画面に戻っている
    });

    testWidgets('シートの操作（保管庫に戻す）が終わると、シートだけが閉じる', (tester) async {
      await pumpEggsInShell(tester);

      final button = find.text('保管庫に戻す');
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(EggDetailSheet), findsNothing);
      expect(find.text('育成枠'), findsOneWidget); // たまご画面は残っている
    });
  });

  group('下タブの再タップ', () {
    Widget shell({required int currentIndex, required List<int> taps}) {
      return ProviderScope(
        overrides: [
          // 広告の枠と孵化バッジは今回の対象外（プラグインや通信に触れないように固定）。
          ...premiumOverrides,
          hasHatchableEggProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          home: BottomNavScaffold(
            currentIndex: currentIndex,
            onTap: taps.add,
            child: Consumer(
              builder: (context, ref, _) => ListView(
                controller: ref.watch(tabScrollControllerProvider(AppTab.eggs)),
                children: [
                  for (var i = 0; i < 60; i++)
                    SizedBox(height: 80, child: Text('行$i')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    double offsetOf(WidgetTester tester) =>
        tester.widget<ListView>(find.byType(ListView)).controller!.offset;

    testWidgets('開いているタブをもう一度押すと、そのページの先頭へ戻る', (tester) async {
      final taps = <int>[];
      await tester.pumpWidget(shell(currentIndex: 1, taps: taps));
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      expect(offsetOf(tester), greaterThan(0));

      await tester.tap(find.text(AppTab.eggs.label));
      await tester.pumpAndSettle();

      expect(offsetOf(tester), 0);
      expect(taps, [1]); // 画面の積み重ねを戻す goBranch も呼ばれる
    });

    testWidgets('別のタブを押したときは、今のページのスクロールを動かさない',
        (tester) async {
      final taps = <int>[];
      await tester.pumpWidget(shell(currentIndex: 1, taps: taps));
      await tester.drag(find.byType(ListView), const Offset(0, -1500));
      await tester.pumpAndSettle();
      final before = offsetOf(tester);

      await tester.tap(find.text(AppTab.quests.label));
      await tester.pumpAndSettle();

      expect(offsetOf(tester), before);
      expect(taps, [3]);
    });
  });
}

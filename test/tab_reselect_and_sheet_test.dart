import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:moffy/core/iap/iap_providers.dart';
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
  group('卵の詳細シート', () {
    testWidgets('小さい iPhone でも、上に余白が残り「閉じる」で元の画面に戻れる',
        (tester) async {
      // iPhone SE（375x667）。中身はこの高さに収まらない。
      tester.view.physicalSize = const Size(750, 1334);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [isOnlineProvider.overrideWithValue(true)],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(path: '/', builder: (_, __) => const EggsScreen()),
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

      // 画面の 85% までに収まる＝上に外側をタップできる余白が残る。
      final sheetHeight = tester.getSize(find.byType(EggDetailSheet)).height;
      expect(sheetHeight, lessThanOrEqualTo(667 * 0.85 + 0.5));

      await tester.tap(find.byTooltip('閉じる'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(EggDetailSheet), findsNothing);
    });
  });

  group('下タブの再タップ', () {
    Widget shell({required int currentIndex, required List<int> taps}) {
      return ProviderScope(
        overrides: [
          // 広告の枠と孵化バッジは今回の対象外（プラグインや通信に触れないように固定）。
          isPremiumProvider.overrideWithValue(true),
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

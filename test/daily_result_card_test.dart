import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/usage/day_band.dart';
import 'package:moffy/core/usage/usage_models.dart';
import 'package:moffy/features/home/domain/home_state.dart';
import 'package:moffy/features/home/presentation/widgets/daily_result_card.dart';

/// ホームの「きのうの結果」の出し分け（0018 §4-5）。
/// とくに「取れなかった」と「記録が無い（開かなかった）」を混同しないこと（反証レビュー #3）。
void main() {
  Widget card(HomeState state) => MaterialApp(
        home: Scaffold(
          body: DailyResultCard(state: state, onRequestPermission: () {}),
        ),
      );

  testWidgets('初日は「きょうが1日目」', (tester) async {
    await tester.pumpWidget(card(_state(isFirstDay: true)));
    await tester.pumpAndSettle();
    expect(find.text('きょうが1日目'), findsOneWidget);
  });

  testWidgets('確定した結果は評価と pt を出す', (tester) async {
    await tester.pumpWidget(
      card(
        _state(
          yesterday: YesterdayResult(
            date: DateTime(2026, 10, 20),
            finalized: true,
            measured: true,
            band: DayBand.great,
            points: 100,
            minutes: 25,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('しっかり離れた日'), findsOneWidget);
    expect(find.text('+100'), findsOneWidget);
  });

  testWidgets('記録が無い日は「開かなかった」', (tester) async {
    await tester.pumpWidget(card(_state()));
    await tester.pumpAndSettle();
    expect(find.textContaining('きのうは開かなかった'), findsOneWidget);
  });

  testWidgets('取れなかったときは「開かなかった」と断定しない（オフライン）', (tester) async {
    await tester.pumpWidget(
      card(_state(yesterdayUnavailable: true, isOffline: true)),
    );
    await tester.pumpAndSettle();
    expect(find.text('きのうの結果を取得できませんでした'), findsOneWidget);
    expect(find.textContaining('オフライン'), findsOneWidget);
    expect(find.textContaining('開かなかった'), findsNothing);
  });

  testWidgets('取れなかったときは「開かなかった」と断定しない（通信エラー）', (tester) async {
    await tester.pumpWidget(card(_state(yesterdayUnavailable: true)));
    await tester.pumpAndSettle();
    expect(find.text('きのうの結果を取得できませんでした'), findsOneWidget);
    expect(find.textContaining('下に引っぱって'), findsOneWidget);
  });
}

HomeState _state({
  YesterdayResult? yesterday,
  bool isFirstDay = false,
  bool yesterdayUnavailable = false,
  bool isOffline = false,
}) =>
    HomeState(
      permission: UsagePermissionStatus.granted,
      todayUsage: null,
      usualMinutes: 120,
      usualMinutesSource: 'default',
      yesterday: yesterday,
      yesterdayUnavailable: yesterdayUnavailable,
      isFirstDay: isFirstDay,
      activeEgg: null,
      pointBalance: 0,
      gemBalance: 0,
      pooledPoints: 0,
      isOffline: isOffline,
      params: EconomyParams.defaults,
    );

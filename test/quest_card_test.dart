import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/theme/tokens.dart';
import 'package:moffy/core/widgets/common_widgets.dart';
import 'package:moffy/features/quests/domain/quest_models.dart';
import 'package:moffy/features/quests/presentation/widgets/quest_card.dart';

/// app_under（「○分まで」）クエストカードの描画テスト（磨き込み③）。
///
/// 目的: 「満タン＝達成に見える」誤読の解消を担保する。app_under は"予算メーター"で、
/// progress=使用分。バーは使用量ぶんだけ埋まり（未使用=空／上限で満タン=赤）、達成
/// （上限内・サーバー確定）のときだけ緑満タン＋受取。他タイプ（進捗=良い）と混同させない。
void main() {
  Quest appUnder({required int used, required bool completed}) => Quest(
        id: 'q',
        kind: QuestKind.daily,
        // 特定アプリ名を名指ししない中立フィクスチャ（アサーションは target=20 の数値のみに依存）。
        title: '対象アプリは20分まで',
        condition: const QuestCondition(
          type: QuestConditionType.appUnder,
          target: 20,
          package: 'com.x',
        ),
        reward: const QuestReward(points: 30),
        progress: used,
        isCompleted: completed,
        rewardGranted: false,
      );

  Future<void> pump(WidgetTester tester, Quest q) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuestCard(quest: q, onClaim: () {}, claiming: false),
          ),
        ),
      );

  GrowthProgressBar bar(WidgetTester tester) =>
      tester.widget<GrowthProgressBar>(find.byType(GrowthProgressBar));

  testWidgets('進行中: バーは使用量ぶん（12/20=0.6）で満タンにならず、達成表示も出ない', (tester) async {
    await pump(tester, appUnder(used: 12, completed: false));

    expect(find.text('あと8分（上限20分）'), findsOneWidget);
    expect(find.textContaining('達成'), findsNothing); // 未達で「達成」文言なし
    expect(find.text('受け取る'), findsNothing); // 未達で受取ボタンなし
    expect(bar(tester).value, closeTo(0.6, 0.001)); // 満タンではない
    expect(bar(tester).fillColor, isNot(AppColors.success)); // 達成色(緑)ではない
  });

  testWidgets('上限に近い（17/20>80%）: 警告色＋残り表示', (tester) async {
    await pump(tester, appUnder(used: 17, completed: false));

    expect(find.text('あと3分（上限20分）'), findsOneWidget);
    expect(bar(tester).fillColor, AppColors.warn);
  });

  testWidgets('超過（25/20）: 満タン赤＋オーバー表示（"満タン"は達成でなく上限超過を意味する）', (tester) async {
    await pump(tester, appUnder(used: 25, completed: false));

    expect(find.text('上限を5分オーバー'), findsOneWidget);
    expect(bar(tester).value, 1.0);
    expect(bar(tester).fillColor, AppColors.error);
  });

  testWidgets('達成（サーバー確定・上限内）: 緑満タン＋「上限内で達成」＋受取ボタン', (tester) async {
    await pump(tester, appUnder(used: 8, completed: true));

    expect(find.text('上限内で達成'), findsOneWidget);
    expect(find.text('受け取る'), findsOneWidget);
    expect(bar(tester).value, 1.0);
    expect(bar(tester).fillColor, AppColors.success);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/iap/iap_providers.dart';
import 'package:moffy/features/home/presentation/widgets/home_activity.dart';

/// プレミアム導線（磨き込み②）の表示ゲートのウィジェットテスト。
///
/// 鉄則: アップセルは **無料ユーザーだけ** に出す（加入者を煩わせない）。ホーム/図鑑の
/// 導線は共通して isPremiumProvider で丸ごと畳む。ここでは公開ウィジェット HomePremiumCard で
/// 「非プレミアム=表示・タップで遷移コールバック / プレミアム=非表示」を担保する
/// （図鑑側の _CollectionPremiumHint も同一パターン）。
void main() {
  Widget harness({
    required bool isPremium,
    required VoidCallback onOpen,
  }) {
    return ProviderScope(
      overrides: [isPremiumProvider.overrideWithValue(isPremium)],
      child: MaterialApp(
        home: Scaffold(body: HomePremiumCard(onOpen: onOpen)),
      ),
    );
  }

  testWidgets('非プレミアムは表示され、タップで onOpen が呼ばれる', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      harness(isPremium: false, onOpen: () => opened = true),
    );

    expect(find.text('Moffyプレミアム'), findsOneWidget);
    // 未実装特典（プレミアム卵/限定Mofi）は謳わない（実提供の訴求のみ）。
    expect(find.textContaining('限定Mofi'), findsNothing);
    expect(find.textContaining('プレミアム卵'), findsNothing);

    await tester.tap(find.text('Moffyプレミアム'));
    expect(opened, isTrue);
  });

  testWidgets('プレミアム加入者には出さない（丸ごと畳む）', (tester) async {
    await tester.pumpWidget(
      harness(isPremium: true, onOpen: () {}),
    );

    expect(find.text('Moffyプレミアム'), findsNothing);
    expect(find.byType(HomePremiumCard), findsOneWidget); // 存在はするが shrink
  });
}

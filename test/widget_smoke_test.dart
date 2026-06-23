import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/collection/presentation/collection_screen.dart';
import 'package:moffy/features/eggs/presentation/eggs_screen.dart';
import 'package:moffy/features/menu/presentation/menu_screen.dart';
import 'package:moffy/features/paywall/presentation/paywall_screen.dart';
import 'package:moffy/features/quests/presentation/quests_screen.dart';

/// 新規画面のスモークテスト（合成エラー・致命的なビルド崩れの検知）。
/// モックリポジトリ経由でデータ状態まで描画できることを確認する。
void main() {
  Widget host(Widget child) => ProviderScope(
        child: MaterialApp(home: child),
      );

  testWidgets('EggsScreen がモックデータで描画できる', (tester) async {
    await tester.pumpWidget(host(const EggsScreen()));
    await tester.pump(); // FutureProvider 解決
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('たまご'), findsOneWidget);
    expect(find.text('育成枠'), findsOneWidget);
  });

  testWidgets('CollectionScreen がモックデータで描画できる', (tester) async {
    await tester.pumpWidget(host(const CollectionScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('図鑑'), findsOneWidget);
    expect(find.text('図鑑達成率'), findsOneWidget);
  });

  testWidgets('QuestsScreen がモックデータで描画できる（デイリー/ウィークリー）', (tester) async {
    await tester.pumpWidget(host(const QuestsScreen()));
    await tester.pump(); // FutureProvider 解決
    await tester.pump(const Duration(milliseconds: 50));
    // タイトルとストリークヘッダ・デイリー見出し（上部）が出ることを確認。
    expect(find.text('クエスト'), findsOneWidget);
    expect(find.text('デイリー'), findsOneWidget);
    expect(find.text('日連続'), findsOneWidget); // ストリークヘッダ
  });

  testWidgets('MenuScreen がモックデータで描画できる（プロフィール統計）', (tester) async {
    await tester.pumpWidget(host(const MenuScreen()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // タイトルと先頭のプロフィール統計カードが出ることを確認。
    expect(find.text('メニュー'), findsOneWidget);
    expect(find.text('プロフィール'), findsOneWidget);
    expect(find.text('総削減時間'), findsOneWidget);
  });

  testWidgets('PaywallScreen が未設定時（no-op）に空状態へ落ちる（クラッシュしない）',
      (tester) async {
    // RevenueCat キー未注入のテスト環境では no-op サービス → 商品なし → 空状態。
    await tester.pumpWidget(host(const PaywallScreen()));
    await tester.pump(); // FutureProvider（offerings）解決
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('プレミアム'), findsOneWidget); // AppBar タイトル
    // 空状態の文言（プラン準備中）が出る（5状態の空が成立）。
    expect(find.text('プランを準備中です'), findsOneWidget);
  });
}

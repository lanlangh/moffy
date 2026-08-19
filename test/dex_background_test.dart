import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/widgets/world_stage.dart';
import 'package:moffy/features/collection/domain/mofi_models.dart';
import 'package:moffy/features/collection/presentation/widgets/mofi_detail_sheet.dart';

/// 図鑑の詳細に「世界の背景」が出ることを守る回帰テスト。
///
/// 背景（2026-08-19 オーナー指摘）:
///   「未発見は背景なしでも大丈夫ですが、**図鑑に載ったときに背景を忘れない**
///     ような形にしてください」
///   ＝ 気をつける、では守れない。**発見済みなら必ず背景が出る**ことを CI で固定する。
///   将来だれかが背景を外したり、条件を書き換えたりしたら、ここで止まる。
///
/// 未発見に背景を出さないのは意図的な設計（シルエットで正体を伏せる場面なので、
/// 背景を出すと発見の驚きが先に漏れる）。その意図もあわせて固定する。
void main() {
  MofiDexEntry entry({required bool discovered}) => MofiDexEntry(
        species: const MofiSpecies(
          id: 'slime_01',
          family: MofiFamily.slime,
          rarity: MofiRarity.common,
          name: 'ぷるりん',
          sortOrder: 1,
        ),
        isShiny: false,
        discovered: discovered,
        discoveredAt: discovered ? DateTime(2026, 8, 19) : null,
        obtainedCount: discovered ? 1 : 0,
      );

  Widget harness(MofiDexEntry e) => MaterialApp(
        home: Scaffold(
          body: MofiDetailSheet(entry: e, stage2Count: 3),
        ),
      );

  testWidgets('発見済みなら世界の背景が出る', (tester) async {
    await tester.pumpWidget(harness(entry(discovered: true)));
    await tester.pumpAndSettle();
    expect(find.byType(WorldStageBackground), findsOneWidget);
  });

  testWidgets('未発見では背景を出さない（発見の驚きを先に漏らさない）', (tester) async {
    await tester.pumpWidget(harness(entry(discovered: false)));
    await tester.pumpAndSettle();
    expect(find.byType(WorldStageBackground), findsNothing);
  });
}

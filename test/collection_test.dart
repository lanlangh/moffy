import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/collection/domain/mofi_models.dart';
import 'package:moffy/features/collection/presentation/collection_controller.dart';

/// 図鑑の達成率算出（S13: 40エントリ）・マスタ整合・フィルタの単体テスト。
void main() {
  group('Mofiマスタ（§4-1 / migration seed 整合）', () {
    test('20種ちょうど', () {
      expect(kMofiSpeciesSeed.length, 20);
    });

    test('レアリティ構成: Common7 / Rare6 / SR4 / SSR3', () {
      int count(MofiRarity r) =>
          kMofiSpeciesSeed.where((s) => s.rarity == r).length;
      expect(count(MofiRarity.common), 7);
      expect(count(MofiRarity.rare), 6);
      expect(count(MofiRarity.sr), 4);
      expect(count(MofiRarity.ssr), 3);
    });

    test('種族ごと5種ずつ（4系統）', () {
      int count(MofiFamily f) =>
          kMofiSpeciesSeed.where((s) => s.family == f).length;
      expect(count(MofiFamily.slime), 5);
      expect(count(MofiFamily.critter), 5);
      expect(count(MofiFamily.dragon), 5);
      expect(count(MofiFamily.beast), 5);
    });

    test('idは一意', () {
      final ids = kMofiSpeciesSeed.map((s) => s.id).toSet();
      expect(ids.length, kMofiSpeciesSeed.length);
    });
  });

  group('CollectionState 達成率（S13）', () {
    MofiDexEntry entry(MofiSpecies s, {required bool shiny, required bool found}) =>
        MofiDexEntry(
          species: s,
          isShiny: shiny,
          discovered: found,
          discoveredAt: found ? DateTime(2026, 6, 18) : null,
        );

    test('全40エントリ中 発見済み数 / 40 = 達成率', () {
      final entries = <MofiDexEntry>[];
      var found = 0;
      for (var i = 0; i < kMofiSpeciesSeed.length; i++) {
        final s = kMofiSpeciesSeed[i];
        // 通常色のうち先頭7体だけ発見済みにする。
        final isFound = i < 7;
        if (isFound) found++;
        entries.add(entry(s, shiny: false, found: isFound));
        entries.add(entry(s, shiny: true, found: false));
      }
      final state = CollectionState(
        entries: entries,
        totalEntries: 40,
        isOffline: false,
      );
      expect(state.discoveredCount, found);
      expect(state.totalEntries, 40);
      expect(state.completionRatio, closeTo(found / 40, 1e-9));
      expect(state.isEmpty, isFalse);
    });

    test('1体も未発見なら isEmpty', () {
      final entries = [
        for (final s in kMofiSpeciesSeed) ...[
          entry(s, shiny: false, found: false),
          entry(s, shiny: true, found: false),
        ],
      ];
      final state =
          CollectionState(entries: entries, totalEntries: 40, isOffline: false);
      expect(state.isEmpty, isTrue);
      expect(state.completionRatio, 0.0);
    });
  });

  group('CollectionFilter', () {
    final common = kMofiSpeciesSeed.firstWhere((s) => s.rarity == MofiRarity.common);
    final sr = kMofiSpeciesSeed.firstWhere((s) => s.rarity == MofiRarity.sr);

    MofiDexEntry e(MofiSpecies s, bool shiny) =>
        MofiDexEntry(species: s, isShiny: shiny, discovered: true);

    test('レアリティフィルタ', () {
      const f = CollectionFilter(rarity: MofiRarity.sr);
      expect(f.matches(e(sr, false)), isTrue);
      expect(f.matches(e(common, false)), isFalse);
    });

    test('色違いトグル', () {
      const f = CollectionFilter(shinyOnly: true);
      expect(f.matches(e(common, true)), isTrue);
      expect(f.matches(e(common, false)), isFalse);
    });

    test('レアリティ×色違いの複合', () {
      const f = CollectionFilter(rarity: MofiRarity.sr, shinyOnly: true);
      expect(f.matches(e(sr, true)), isTrue);
      expect(f.matches(e(sr, false)), isFalse);
      expect(f.matches(e(common, true)), isFalse);
    });
  });
}

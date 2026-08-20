import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/collection/domain/mofi_models.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';
import 'package:moffy/features/eggs/presentation/pending_hatch_provider.dart';

/// 孵化後の「ステージに残る Mofi」の導出を守る。
///
/// なぜテストが要るか（2026-08-20）:
///   この機能は**どこでも検証されていなかった**。Webプレビューの孵化ボタンは
///   決まった見本を出すだけの偽物で、この経路を一切通らない。実機でも
///   孵化には数日分の成長ポイントが要るので、オーナーは確認しようがない。
///   ＝ **目視では守れない**ので、ここで固定する。
///
/// この導出は過去に2回間違えている:
///   1. 種族IDだけで図鑑を照合し、色違いを孵化したのに通常（未発見）を拾った
///   2. 名前をサーバーの返事から取っていて図鑑と食い違った
/// どちらも画面の中に埋まっていてテストが書けなかったのが共通の原因。
void main() {
  MofiSpecies species(String id) =>
      kMofiSpeciesSeed.firstWhere((s) => s.id == id);

  HatchResult hatched(String id, {bool shiny = false}) => HatchResult(
        species: species(id),
        isShiny: shiny,
        isNewDexEntry: false,
        fromEggId: 'egg-1',
      );

  /// 通常色と色違いを**別エントリ**で持つ、本物と同じ形の図鑑を作る。
  CollectionState dexWith({
    required String id,
    required int normalCount,
    required int shinyCount,
    int stage2 = 3,
  }) =>
      CollectionState(
        entries: [
          for (final s in kMofiSpeciesSeed)
            for (final shiny in const [false, true])
              MofiDexEntry(
                species: s,
                isShiny: shiny,
                discovered:
                    s.id == id && (shiny ? shinyCount : normalCount) > 0,
                discoveredAt: null,
                obtainedCount:
                    s.id == id ? (shiny ? shinyCount : normalCount) : 0,
              ),
        ],
        totalEntries: 40,
        isOffline: false,
        evolveStage2Count: stage2,
      );

  group('進化の判定', () {
    test('しきい値ちょうどの回だけ「進化した」になる', () {
      final p = HatchPresentation.fromDex(
        result: hatched('slime_01'),
        dex: dexWith(id: 'slime_01', normalCount: 3, shinyCount: 0),
      );
      expect(p.justEvolved, isTrue);
      expect(p.stage, 2);
      expect(p.toNextEvolution, 0);
    });

    test('しきい値を超えた回は「進化した」を出さない（毎回祝わない）', () {
      final p = HatchPresentation.fromDex(
        result: hatched('slime_01'),
        dex: dexWith(id: 'slime_01', normalCount: 4, shinyCount: 0),
      );
      expect(p.justEvolved, isFalse);
      expect(p.stage, 2);
    });

    test('しきい値未満はベビーで、あと何体かが出る', () {
      final p = HatchPresentation.fromDex(
        result: hatched('slime_01'),
        dex: dexWith(id: 'slime_01', normalCount: 2, shinyCount: 0),
      );
      expect(p.justEvolved, isFalse);
      expect(p.stage, 1);
      expect(p.toNextEvolution, 1);
    });

    test('しきい値が変わっても追従する（app_config で変えられる）', () {
      final p = HatchPresentation.fromDex(
        result: hatched('slime_01'),
        dex: dexWith(id: 'slime_01', normalCount: 5, shinyCount: 0, stage2: 5),
      );
      expect(p.justEvolved, isTrue);
      expect(p.stage, 2);
    });
  });

  group('色違いと通常を取り違えない（2026-08-19 に実機で発覚した不具合）', () {
    test('色違いを孵化したら、色違いのエントリを見る', () {
      final p = HatchPresentation.fromDex(
        result: hatched('slime_01', shiny: true),
        dex: dexWith(id: 'slime_01', normalCount: 0, shinyCount: 3),
      );
      expect(p.justEvolved, isTrue, reason: '色違い側の3体を見ていない');
      expect(p.stage, 2);
    });

    test('通常色を孵化したら、色違いが進化済みでも影響されない', () {
      final p = HatchPresentation.fromDex(
        result: hatched('slime_01'),
        dex: dexWith(id: 'slime_01', normalCount: 1, shinyCount: 9),
      );
      expect(p.justEvolved, isFalse);
      expect(p.stage, 1);
      expect(p.toNextEvolution, 2);
    });
  });

  group('図鑑が読めなかったときも演出は壊れない', () {
    test('図鑑が null でもベビーとして成立する（オフライン等）', () {
      final p =
          HatchPresentation.fromDex(result: hatched('slime_01'), dex: null);
      expect(p.stage, 1);
      expect(p.justEvolved, isFalse);
      expect(p.toNextEvolution, 0);
      expect(p.result.species.id, 'slime_01');
    });

    test('図鑑に該当エントリが無くても落ちない', () {
      final p = HatchPresentation.fromDex(
        result: hatched('slime_01'),
        dex: const CollectionState(
          entries: [],
          totalEntries: 40,
          isOffline: false,
          evolveStage2Count: 3,
        ),
      );
      expect(p.stage, 1);
      expect(p.justEvolved, isFalse);
    });
  });

  test('ステージに残る Mofi の名前は、進化段階に追従する', () {
    final p = HatchPresentation.fromDex(
      result: hatched('dragon_03'),
      dex: dexWith(id: 'dragon_03', normalCount: 3, shinyCount: 0),
    );
    expect(p.stage, 2);
    final shown = p.result.species.nameForStage(p.stage);
    expect(shown, species('dragon_03').evolvedName);
    expect(shown, isNot(species('dragon_03').name));
  });
}

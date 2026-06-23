import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/collection/domain/mofi_models.dart';
import 'package:moffy/features/eggs/data/hatch_share_service.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';

/// 孵化シェア文面（S13 グロースの種）の純粋関数テスト。
///
/// 共有自体はプラグイン（share_plus/path_provider）依存で実機検証だが、文面組み立ては
/// 純粋関数として切り出してあるため単体で担保する。色違い時に専用の訴求になること、
/// 個体名・レアリティ・ハッシュタグが含まれることを検証する。
void main() {
  HatchResult result({required bool shiny, MofiRarity rarity = MofiRarity.sr}) =>
      HatchResult(
        species: MofiSpecies(
          id: 'dragon_03',
          family: MofiFamily.dragon,
          rarity: rarity,
          name: 'らいりゅう',
          sortOrder: 13,
        ),
        isShiny: shiny,
        isNewDexEntry: true,
        fromEggId: 'egg_abc',
      );

  group('buildHatchShareText', () {
    test('色違いは専用の訴求文 + 個体名/レア/ハッシュタグを含む', () {
      final text = buildHatchShareText(result(shiny: true));
      expect(text, contains('色違い'));
      expect(text, contains('らいりゅう'));
      expect(text, contains('SR'));
      expect(text, contains('#Moffy'));
    });

    test('通常色は色違い表記を含まない', () {
      final text = buildHatchShareText(result(shiny: false));
      expect(text, isNot(contains('色違い')));
      expect(text, contains('らいりゅう'));
      expect(text, contains('#Moffy'));
    });
  });

  group('buildHatchShareSubject', () {
    test('色違いと通常で件名が出し分けられる', () {
      expect(buildHatchShareSubject(result(shiny: true)), contains('色違い'));
      expect(
        buildHatchShareSubject(result(shiny: false)),
        isNot(contains('色違い')),
      );
    });
  });
}

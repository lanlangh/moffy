import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/collection/domain/mofi_models.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';

/// 孵化結果の Mofi 名が、**アプリ内の [kMofiSpeciesSeed] から引かれる**ことを守る。
///
/// 背景（2026-08-20・実機ビルドの直前に発覚）:
///   サーバーの `fn_hatch_egg` が返す species は id/family/rarity/name/sort_order の
///   5つだけで **evolved_name を含まない**。返事をそのまま使っていたため:
///     * 進化後の名前が孵化まわりで一度も出ない（このリリースの目玉が死ぬ）
///     * DB の name は改名前のままなので、孵化演出は「らいりゅう」、
///       直後に開いた図鑑は「らいむ」と、数秒のうちに名前が食い違う
///
/// なぜ既存のテストで捕まらなかったか:
///   Web プレビュー（FORCE_MOCK）のモックは元々アプリ内リストから引くので、
///   **この不具合だけは原理的に再現しない**。本番接続の実機でしか出ない。
///   ＝ 目視では守れない種類のバグなので、ここで固定する。
void main() {
  /// サーバーが実際に返す形（0005_economy_exploit_fix.sql の jsonb_build_object と同じキー）。
  /// name は **DB に入っている改名前の値**、evolved_name は **存在しない**。
  Map<String, Object?> serverJson({
    required String id,
    required String staleName,
  }) =>
      {
        'species': {
          'id': id,
          'family': 'dragon',
          'rarity': 'sr',
          'name': staleName,
          'sort_order': 13,
        },
        'is_shiny': false,
        'is_new_dex_entry': true,
        'from_egg_id': 'egg-1',
      };

  test('サーバーが古い名前を返しても、アプリ内の名前が使われる', () {
    final r = HatchResult.fromJson(
      serverJson(id: 'dragon_03', staleName: 'らいりゅう'),
    );
    final seed = kMofiSpeciesSeed.firstWhere((s) => s.id == 'dragon_03');
    expect(r.species.name, seed.name);
    expect(r.species.name, isNot('らいりゅう'));
  });

  test('サーバーが返さない進化後の名前が、孵化結果でも使える', () {
    final r = HatchResult.fromJson(
      serverJson(id: 'dragon_03', staleName: 'らいりゅう'),
    );
    // 進化後(stage2)の名前が出ること＝これが出ないと「進化で名前が変わる」が死ぬ。
    expect(r.species.evolvedName, isNotNull);
    expect(r.species.nameForStage(2), r.species.evolvedName);
    expect(r.species.nameForStage(2), isNot(r.species.nameForStage(1)));
  });

  test('全20種で、孵化結果の名前が図鑑の名前と一致する', () {
    for (final seed in kMofiSpeciesSeed) {
      final r = HatchResult.fromJson(
        serverJson(id: seed.id, staleName: '__DBの古い名前__'),
      );
      expect(r.species.name, seed.name, reason: '${seed.id} で食い違い');
      expect(r.species.evolvedName, seed.evolvedName, reason: '${seed.id} の進化後名');
    }
  });

  test('未知の id はサーバーの値へ倒れる（種を足しても壊れない）', () {
    final r = HatchResult.fromJson(
      serverJson(id: 'dragon_99_unknown', staleName: 'みらいのこ'),
    );
    expect(r.species.id, 'dragon_99_unknown');
    expect(r.species.name, 'みらいのこ');
  });

  test('孵化結果のその他の項目は、サーバーの返事のまま', () {
    final j = serverJson(id: 'dragon_03', staleName: 'らいりゅう');
    j['is_shiny'] = true;
    final r = HatchResult.fromJson(j);
    expect(r.isShiny, isTrue);
    expect(r.isNewDexEntry, isTrue);
    expect(r.fromEggId, 'egg-1');
  });
}

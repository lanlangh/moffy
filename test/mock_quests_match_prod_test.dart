import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/features/quests/data/quest_repository.dart';

/// モックのクエストが本番の `quest_definitions` とずれていないかの番人（2026-09-10）。
///
/// なぜ要るか:
///   Web プレビューは FORCE_MOCK で動くので、**ストアのスクリーンショットには
///   モックの内容が写る**。モックが本番とずれていると、実ユーザーには出ない
///   クエストがストアに出てしまう。2026-08-28 に実際そうなった
///   （'daily_sns_under_60' はモックにしか無いのに Play のスクショへ出た。
///   package を持たない app_under＝「合計型」がサーバー未実装で、DB に
///   seed されていなかった＝0015:74）。
///
/// 期待値は **DB の実測値**（`db-check-quests.yml` / SELECT のみ）から来ている。
/// migration でクエストを足す・止めるときは、[kMockQuestIds] とここも一緒に直すこと。
void main() {
  // supabase/migrations の is_active = true な定義（2026-09-10 実測）。
  //   0006 で5件 seed → 0013 で daily_tiktok_under_20 を is_active=false。
  const prodActiveQuestIds = <String>{
    'daily_reduce_30',
    'daily_streak_keep',
    'weekly_hatch_3',
    'weekly_points_1000',
  };

  test('宣言 kMockQuestIds が本番の is_active な定義と一致する', () {
    expect(
      kMockQuestIds.toSet(),
      prodActiveQuestIds,
      reason: 'ずれているとストアのスクショに実物と違うクエストが写る。'
          'migration を変えたなら kMockQuestIds とこの期待値も直すこと。',
    );
  });

  test('kMockQuestIds に重複が無い', () {
    expect(kMockQuestIds.toSet().length, kMockQuestIds.length);
  });

  // MockQuestRepository は Ref を取るので、テスト用のプロバイダ経由で組み立てる。
  // （questRepositoryProvider を使うと Env.useSupabase 次第で実装が変わるため使わない）
  final testRepoProvider =
      Provider<MockQuestRepository>((ref) => MockQuestRepository(ref));

  test('MockQuestRepository が実際に出すのも同じ4件（宣言と実装のずれを防ぐ）', () async {
    // isOnlineProvider だけ差し替えれば MockQuestRepository は動く。
    final container = ProviderContainer(
      overrides: [isOnlineProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);

    final repo = container.read(testRepoProvider);
    final state = await repo.loadQuests(EconomyParams.defaults);
    final got = [...state.daily, ...state.weekly].map((q) => q.id).toList();

    expect(
      got.toSet(),
      prodActiveQuestIds,
      reason: '_seedQuests() に足したのに kMockQuestIds を直し忘れていないか',
    );
    expect(
      got,
      kMockQuestIds,
      reason: '表示順も宣言どおりであること（スクショの見た目が変わるため）',
    );
  });
}

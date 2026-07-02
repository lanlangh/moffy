import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/economy.dart';
import '../../../core/constants/remote_config.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../domain/mofi_models.dart';

/// 図鑑 feature のデータ層（ARCHITECTURE §1-2 data / S5,S13）。
///
/// 図鑑登録（mofi_collection）の書き込みはサーバーRPC `fn_hatch_egg` のみ（RLSで封鎖）。
/// クライアントは読み取り専用。第2aパスは [MockCollectionRepository] で動作させる。
abstract interface class CollectionRepository {
  /// 図鑑全体（30エントリ = 15種×色違い）と発見状況を取得する。
  /// 未発見エントリもシルエット表示のため返す（SCREEN_FLOWS §4）。
  Future<CollectionState> loadCollection(EconomyParams params);
}

/// モック実装（第2aパス）。マスタ15種から30エントリを生成し、一部を発見済みにする。
/// TODO(第2b): Supabase `mofi_species`（公開select）+ `mofi_collection`（本人select）を
///   結合し、オフライン時は Drift キャッシュにフォールバック（S8）。
class MockCollectionRepository implements CollectionRepository {
  MockCollectionRepository(this._ref);

  final Ref _ref;

  @override
  Future<CollectionState> loadCollection(EconomyParams params) async {
    final isOnline = _ref.read(isOnlineProvider);

    // 発見済みモック（species_id × shiny）。本番は mofi_collection 由来。
    // TODO(第2b): select species_id, is_shiny, discovered_at, obtained_count
    //   from mofi_collection where user_id = auth.uid()。
    final discovered = <String, DateTime>{
      'slime_01:normal': DateTime(2026, 6, 14, 9, 30),
      'slime_02:normal': DateTime(2026, 6, 15, 20, 12),
      'critter_01:normal': DateTime(2026, 6, 16, 8, 5),
      'critter_03:normal': DateTime(2026, 6, 17, 21, 48),
      'dragon_02:normal': DateTime(2026, 6, 18, 7, 2),
      'slime_03:shiny': DateTime(2026, 6, 18, 22, 40), // 色違い1体
      'dragon_03:normal': DateTime(2026, 6, 19, 19, 15),
    };

    // プレビュー用の重複入手数（進化の見た目を確認するため / しきい値=3）。
    const counts = <String, int>{
      'slime_01:normal': 4, // アダルトに進化済み
      'critter_01:normal': 3, // ちょうど進化
      'slime_02:normal': 2, // ベビー・あと1体で進化（発見済み）
    };

    final entries = _buildAllEntries(discovered, counts);

    return CollectionState(
      entries: entries,
      totalEntries: params.dexTotalEntries,
      isOffline: !isOnline,
      evolveStage2Count: params.mofiEvolveStage2Count,
    );
  }

  /// マスタ15種 × {通常色, 色違い} = 30エントリを安定順で生成する。
  List<MofiDexEntry> _buildAllEntries(
    Map<String, DateTime> discovered,
    Map<String, int> counts,
  ) {
    final species = [...kMofiSpeciesSeed]
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final result = <MofiDexEntry>[];
    for (final s in species) {
      for (final shiny in const [false, true]) {
        final key = '${s.id}:${shiny ? 'shiny' : 'normal'}';
        final at = discovered[key];
        result.add(
          MofiDexEntry(
            species: s,
            isShiny: shiny,
            discovered: at != null,
            discoveredAt: at,
            obtainedCount: at != null ? (counts[key] ?? 1) : 0,
          ),
        );
      }
    }
    return result;
  }
}

/// Supabase 本実装（読み取り専用 / S5,S13）。
///
/// `mofi_collection`（本人select）で発見済みを取得し、マスタ15種×色違いの全30エントリへ
/// マージする。図鑑書き込みは `fn_hatch_egg` のみ（クライアントは加算しない / 信頼境界）。
class SupabaseCollectionRepository implements CollectionRepository {
  SupabaseCollectionRepository(this._ref, this._client);

  final Ref _ref;
  final SupabaseClient _client;

  @override
  Future<CollectionState> loadCollection(EconomyParams params) async {
    final isOnline = _ref.read(isOnlineProvider);
    try {
      final rows = await _client
          .from('mofi_collection')
          .select('species_id, is_shiny, discovered_at, obtained_count');

      final discovered = <String, _DexHit>{};
      for (final raw in (rows as List)) {
        final r = (raw as Map).cast<String, Object?>();
        final shiny = r['is_shiny'] == true;
        final key = '${r['species_id']}:${shiny ? 'shiny' : 'normal'}';
        discovered[key] = _DexHit(
          discoveredAt: DateTime.tryParse('${r['discovered_at']}'),
          count: (r['obtained_count'] as num?)?.toInt() ?? 1,
        );
      }

      final species = [...kMofiSpeciesSeed]
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      final entries = <MofiDexEntry>[];
      for (final s in species) {
        for (final shiny in const [false, true]) {
          final hit = discovered['${s.id}:${shiny ? 'shiny' : 'normal'}'];
          entries.add(
            MofiDexEntry(
              species: s,
              isShiny: shiny,
              discovered: hit != null,
              discoveredAt: hit?.discoveredAt,
              obtainedCount: hit?.count ?? 0,
            ),
          );
        }
      }

      return CollectionState(
        entries: entries,
        totalEntries: params.dexTotalEntries,
        isOffline: !isOnline,
        evolveStage2Count: params.mofiEvolveStage2Count,
      );
    } catch (e, st) {
      Log.e('loadCollection failed', error: e, stack: st);
      rethrow;
    }
  }
}

class _DexHit {
  final DateTime? discoveredAt;
  final int count;
  const _DexHit({required this.discoveredAt, required this.count});
}

/// 図鑑リポジトリの DI（ARCHITECTURE §1-3）。テストで override 可能。
/// Supabase 設定済みなら本実装、未設定/PoC時はモックにフォールバック。
final collectionRepositoryProvider = Provider<CollectionRepository>((ref) {
  if (Env.useSupabase) {
    return SupabaseCollectionRepository(ref, ref.read(supabaseClientProvider));
  }
  return MockCollectionRepository(ref);
});

/// 図鑑状態を供給する FutureProvider。
final collectionStateProvider = FutureProvider<CollectionState>((ref) async {
  final params = await ref.watch(economyParamsProvider.future);
  final repo = ref.read(collectionRepositoryProvider);
  return repo.loadCollection(params);
});

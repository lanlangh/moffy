import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/economy.dart';
import '../../../core/constants/remote_config.dart';
import '../../../core/error/failure.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/sync/finalize_models.dart';
import '../../collection/domain/mofi_models.dart';
import '../domain/egg_models.dart';

/// 卵 feature のデータ層（ARCHITECTURE §1-2 data / §2-3 信頼境界）。
///
/// 抽象 [EggRepository] を features 層に公開し、実装は Supabase/Drift の詳細を隠蔽する。
/// 第2aパスはサーバーRPC未実装のため [MockEggRepository] で動作させる。
/// 孵化・成長加算・枠移動の「確定書き込み」はサーバーRPCの責務であり、
/// 配線箇所は本ファイルの TODO に明示する（クライアントは抽選しない）。
abstract interface class EggRepository {
  /// たまご画面のスナップショット（育成3枠 + 保管 + プールpt）を取得する。
  Future<EggsState> loadEggs(EconomyParams params);

  /// FTUE 最初の卵保証（復帰フォールバック / migration 0009）。
  ///
  /// 巣が完全に空（育成枠も保管枠も空 = 未孵化の卵を1つも持たない）のとき、サーバーへ
  /// 標準卵を1つ**冪等**付与要求する。結果 [EnsureFirstEggResult]（granted / is_first_ever）を
  /// 返す。既に卵を持つ（no-op）/ 未配線（Mock）/ オフライン / 失敗は granted=false
  /// （[EnsureFirstEggResult.notGranted]）で、例外は投げない（画面を止めない）。
  /// 付与判断はサーバー RPC `fn_ensure_first_egg` の責務（ウォームアップ窓・ローカル日付に
  /// 依存しない堅牢な保証 / ARCHITECTURE §2-3）。
  Future<EnsureFirstEggResult> ensureFirstEgg();

  /// アクティブ卵（加点対象 / S6: 1枠のみ）を [eggId] に切り替える。
  /// 成長ptは卵ごとに保持される（枠移動で失われない / S6）。
  Future<void> setActiveEgg(String eggId);

  /// 育成枠の卵を保管枠へ戻す（枠を空ける / S6）。
  Future<void> moveToStorage(String eggId);

  /// 保管枠の卵を空いている育成枠 [slotIndex]（1..3）へセットする（S6）。
  Future<void> moveToIncubator({required String eggId, required int slotIndex});

  /// 孵化を確定する（500pt到達時 / S5）。
  ///
  /// 信頼境界: 抽選（レア→個体→色違い）と図鑑登録・通貨はサーバーRPC
  /// `fn_hatch_egg`（security definer / 原子的・冪等）の責務。クライアントは
  /// 結果（[HatchResult]）を受け取って演出・図鑑表示に使うだけ（ARCHITECTURE §2-3）。
  /// オフライン中は孵化確定不可（呼び出し側でグレーアウト / S8）。
  Future<HatchResult> hatch(String eggId);
}

/// モック実装（第2aパス）。サーバーRPC未実装のため、ローカルのダミーデータで
/// 5状態・演出フローを動作させる。確定書き込みは行わず、表示用の状態のみ更新する。
class MockEggRepository implements EggRepository {
  MockEggRepository(this._ref);

  final Ref _ref;

  /// メモリ上のモック卵（プロセス内で枠操作を反映するため可変リストで保持）。
  /// TODO(第2b): Supabase `eggs` select + Drift キャッシュに置換（S8 オフラインは Drift）。
  // Keep mock mutations when a ProviderScope/repository is rebuilt in-process.
  // A hot restart still intentionally restores the deterministic demo seed.
  static final List<Egg> _sharedEggs = [
    // 育成2枠（1つ active）＝リング強調のズレ確認用。成長差でヒビ段階も見える。
    const Egg(
      id: 'egg_starter',
      rarity: EggRarity.normal,
      growthPoints: 350, // ヒビ②
      location: EggLocation.incubating,
      slotIndex: 1,
      isActive: true,
      acquiredSource: 'starter',
    ),
    const Egg(
      id: 'egg_rare_1',
      rarity: EggRarity.rare,
      growthPoints: 180, // ヒビ①
      location: EggLocation.incubating,
      slotIndex: 2,
      isActive: false,
      acquiredSource: 'quest',
    ),
    // 保管3つ（レア違い＋近孵化）＝セット/戻す・孵化ボタンの確認用。
    const Egg(
      id: 'egg_storage_ready',
      rarity: EggRarity.epic,
      growthPoints: 480, // 孵化間近（セット→孵化を試せる）
      location: EggLocation.storage,
      slotIndex: null,
      isActive: false,
      acquiredSource: 'premium',
    ),
    const Egg(
      id: 'egg_storage_legend',
      rarity: EggRarity.legend, // ssr金の卵を確認
      growthPoints: 0,
      location: EggLocation.storage,
      slotIndex: null,
      isActive: false,
      acquiredSource: 'premium',
    ),
    const Egg(
      id: 'egg_storage_2',
      rarity: EggRarity.normal,
      growthPoints: 60,
      location: EggLocation.storage,
      slotIndex: null,
      isActive: false,
      acquiredSource: 'standard',
    ),
  ];

  final List<Egg> _eggs = _sharedEggs;

  @override
  Future<EggsState> loadEggs(EconomyParams params) async {
    final isOnline = _ref.read(isOnlineProvider);

    // 育成枠（slotIndex 1..3）をスロット位置に整列。空きは null。
    final slots = List<Egg?>.filled(3, null);
    for (final e in _eggs) {
      if (e.location == EggLocation.incubating &&
          e.slotIndex != null &&
          e.slotIndex! >= 1 &&
          e.slotIndex! <= 3) {
        slots[e.slotIndex! - 1] = e;
      }
    }

    final storage = _eggs
        .where((e) => e.location == EggLocation.storage)
        .toList()
      ..sort((a, b) => b.growthPoints.compareTo(a.growthPoints));

    return EggsState(
      incubatorSlots: slots,
      storage: storage,
      pooledPoints: 0,
      isOffline: !isOnline,
      params: params,
    );
  }

  @override
  Future<EnsureFirstEggResult> ensureFirstEgg() async {
    // モック/プレビュー: 巣が完全に空（未孵化の卵ゼロ）のときだけ standard 卵を1つ足す
    // （本番 RPC fn_ensure_first_egg と同じ guard = 冪等）。既定シードは非空のため通常は no-op。
    final hasAny = _eggs.any((e) => e.location != EggLocation.hatched);
    if (hasAny) return EnsureFirstEggResult.notGranted;
    // 孵化卵も無ければ生涯初（first-ever）。孵化卵だけ残るなら復帰ユーザーの refill。
    final firstEver = _eggs.isEmpty;
    _eggs.add(
      const Egg(
        id: 'egg_starter_ensured',
        rarity: EggRarity.normal,
        growthPoints: 0,
        location: EggLocation.incubating,
        slotIndex: 1,
        isActive: true,
        acquiredSource: 'starter',
      ),
    );
    return EnsureFirstEggResult(
      granted: true,
      reason: 'granted',
      eggId: 'egg_starter_ensured',
      rarity: 'normal',
      isFirstEver: firstEver,
    );
  }

  @override
  Future<void> setActiveEgg(String eggId) async {
    final targetIndex = _eggs.indexWhere((e) => e.id == eggId);
    if (targetIndex < 0 ||
        _eggs[targetIndex].location != EggLocation.incubating) {
      throw StateError('Only an incubating egg can be active: $eggId');
    }
    // TODO(第2b): サーバーで uq_eggs_one_active を満たす形で is_active を更新（RPC/直接update）。
    for (var i = 0; i < _eggs.length; i++) {
      final e = _eggs[i];
      if (e.location == EggLocation.incubating) {
        _eggs[i] = e.copyWith(isActive: e.id == eggId);
      }
    }
  }

  @override
  Future<void> moveToStorage(String eggId) async {
    // TODO(第2b): eggs.location/slot_index/is_active を更新（成長ptは保持 / S6）。
    final i = _eggs.indexWhere((e) => e.id == eggId);
    if (i < 0) throw StateError('egg not found: $eggId');
    _eggs[i] = _eggs[i].copyWith(
      location: EggLocation.storage,
      isActive: false,
      clearSlot: true,
    );
  }

  @override
  Future<void> moveToIncubator({
    required String eggId,
    required int slotIndex,
  }) async {
    // TODO(第2b): 空きスロット検証 + eggs 更新（uq_eggs_slot 制約と整合）。
    if (slotIndex < 1 || slotIndex > 3) {
      throw RangeError.range(slotIndex, 1, 3, 'slotIndex');
    }
    final i = _eggs.indexWhere((e) => e.id == eggId);
    if (i < 0) throw StateError('egg not found: $eggId');
    if (_eggs[i].location != EggLocation.storage) {
      throw StateError('Only a stored egg can be moved: $eggId');
    }
    if (_eggs.any(
      (e) => e.location == EggLocation.incubating && e.slotIndex == slotIndex,
    )) {
      throw StateError('Incubator slot $slotIndex is occupied');
    }
    final hasActive = _eggs.any(
      (e) => e.location == EggLocation.incubating && e.isActive,
    );
    _eggs[i] = _eggs[i].copyWith(
      location: EggLocation.incubating,
      slotIndex: slotIndex,
      isActive: !hasActive,
    );
  }

  @override
  Future<HatchResult> hatch(String eggId) async {
    // TODO(第2b / 信頼境界): サーバーRPC fn_hatch_egg を呼び出す。
    //   * 抽選（drop_tables 参照 → レアリティ → 個体均等 → shiny独立2%）はサーバー。
    //   * 図鑑 upsert（mofi_collection）・卵の hatched 化もサーバーが原子的・冪等に実施。
    //   * オフライン中は呼ばない（S8: UIでグレーアウト）。
    //   現状はモック結果を返し、孵化演出・色違い演出・図鑑遷移のフローを成立させる。
    final egg = _eggs.firstWhere(
      (e) => e.id == eggId,
      orElse: () => throw StateError('egg not found: $eggId'),
    );

    // モックでは「レア卵→色違いSR」を返し、色違いキラリ演出も確認できるようにする。
    // （本番ではこの分岐はサーバーの抽選結果に置き換わる）
    final species = kMofiSpeciesSeed.firstWhere(
      (s) => s.rarity == MofiRarity.sr,
      orElse: () => kMofiSpeciesSeed.first,
    );
    final isShiny = egg.rarity == EggRarity.rare; // モック: レア卵は色違い演出を出す

    // 孵化済みに（モック上の状態反映）。
    final i = _eggs.indexWhere((e) => e.id == eggId);
    if (i >= 0) {
      _eggs[i] = _eggs[i].copyWith(
        location: EggLocation.hatched,
        isActive: false,
        clearSlot: true,
      );
    }

    return HatchResult(
      species: species,
      isShiny: isShiny,
      isNewDexEntry: true,
      fromEggId: eggId,
    );
  }
}

/// Supabase 本実装（信頼境界準拠）。
///
/// 読み取り（loadEggs）は `eggs` の本人select（RLSで本人限定）。
/// 枠移動（setActive/moveToStorage/moveToIncubator）は eggs の本人update（0001のRLSで許可）。
/// **孵化は必ずサーバーRPC `fn_hatch_egg`**（security definer / 抽選はサーバー）。
/// クライアントは図鑑・残高を一切加算しない（ARCHITECTURE §2-3）。
class SupabaseEggRepository implements EggRepository {
  SupabaseEggRepository(this._ref, this._client);

  final Ref _ref;
  final SupabaseClient _client;

  @override
  Future<EggsState> loadEggs(EconomyParams params) async {
    final isOnline = _ref.read(isOnlineProvider);
    try {
      // 育成枠 + 保管（hatched は除外）。
      final rows =
          await _client.from('eggs').select().neq('location', 'hatched');
      final eggs = (rows as List)
          .map((e) => Egg.fromJson((e as Map).cast<String, Object?>()))
          .toList();

      final slots = List<Egg?>.filled(3, null);
      for (final e in eggs) {
        if (e.location == EggLocation.incubating &&
            e.slotIndex != null &&
            e.slotIndex! >= 1 &&
            e.slotIndex! <= 3) {
          slots[e.slotIndex! - 1] = e;
        }
      }
      final storage = eggs
          .where((e) => e.location == EggLocation.storage)
          .toList()
        ..sort((a, b) => b.growthPoints.compareTo(a.growthPoints));

      // プールpt（profiles.pooled_points / S6）。
      final profile =
          await _client.from('profiles').select('pooled_points').maybeSingle();
      final pooled = (profile?['pooled_points'] as num?)?.toInt() ?? 0;

      return EggsState(
        incubatorSlots: slots,
        storage: storage,
        pooledPoints: pooled,
        isOffline: !isOnline,
        params: params,
      );
    } catch (e, st) {
      Log.e('loadEggs failed', error: e, stack: st);
      rethrow;
    }
  }

  @override
  Future<EnsureFirstEggResult> ensureFirstEgg() async {
    // 卵付与はサーバー書き込み。オフライン中は保証できない（次回接続時のロードで再試行 =
    // guard は「巣が空」という状態そのものなので取りこぼさない）。
    if (!_ref.read(isOnlineProvider)) return EnsureFirstEggResult.notGranted;
    try {
      final res = await _client.rpc('fn_ensure_first_egg');
      if (res is! Map) return EnsureFirstEggResult.notGranted;
      return EnsureFirstEggResult.fromJson(res.cast<String, Object?>());
    } catch (e, st) {
      // 保証に失敗しても画面は出す（冪等 RPC なので次回ロードで再試行可能）。
      Log.e('ensureFirstEgg failed', error: e, stack: st);
      return EnsureFirstEggResult.notGranted;
    }
  }

  @override
  Future<void> setActiveEgg(String eggId) async {
    final target = await _client
        .from('eggs')
        .select('id, location')
        .eq('id', eggId)
        .maybeSingle();
    if (target == null || target['location'] != 'incubating') {
      throw StateError('Only an incubating egg can be active: $eggId');
    }
    // uq_eggs_one_active を満たすため、まず育成中の全卵を非アクティブ化 → 対象のみ true。
    // RLS（本人update）で他人の卵は触れない。
    await _client
        .from('eggs')
        .update({'is_active': false}).eq('location', 'incubating');
    await _client.from('eggs').update({'is_active': true}).eq('id', eggId);
  }

  @override
  Future<void> moveToStorage(String eggId) async {
    await _client.from('eggs').update({
      'location': 'storage',
      'is_active': false,
      'slot_index': null,
    }).eq('id', eggId);
  }

  @override
  Future<void> moveToIncubator({
    required String eggId,
    required int slotIndex,
  }) async {
    if (slotIndex < 1 || slotIndex > 3) {
      throw RangeError.range(slotIndex, 1, 3, 'slotIndex');
    }
    final target = await _client
        .from('eggs')
        .select('id, location')
        .eq('id', eggId)
        .maybeSingle();
    if (target == null || target['location'] != 'storage') {
      throw StateError('Only a stored egg can be moved: $eggId');
    }
    final occupied = await _client
        .from('eggs')
        .select('id')
        .eq('location', 'incubating')
        .eq('slot_index', slotIndex)
        .maybeSingle();
    if (occupied != null) {
      throw StateError('Incubator slot $slotIndex is occupied');
    }
    final active = await _client
        .from('eggs')
        .select('id')
        .eq('location', 'incubating')
        .eq('is_active', true)
        .maybeSingle();
    await _client.from('eggs').update({
      'location': 'incubating',
      'slot_index': slotIndex,
      'is_active': active == null,
    }).eq('id', eggId);
  }

  @override
  Future<HatchResult> hatch(String eggId) async {
    // 信頼境界の核: 抽選・図鑑登録・卵のhatched化はすべてサーバーRPC。
    // オフライン中は呼び出し側でグレーアウト（S8）。ここでも二重防御で接続確認。
    if (!_ref.read(isOnlineProvider)) {
      throw const NetworkFailure('孵化には接続が必要です');
    }
    try {
      final res =
          await _client.rpc('fn_hatch_egg', params: {'p_egg_id': eggId});
      if (res is! Map) {
        throw const ServerFailure('孵化結果の形式が不正です');
      }
      return HatchResult.fromJson((res).cast<String, Object?>());
    } on PostgrestException catch (e, st) {
      Log.e('fn_hatch_egg failed: ${e.code}', error: e, stack: st);
      throw ServerFailure(_hatchMessage(e));
    }
  }

  String _hatchMessage(PostgrestException e) {
    // RPCの raise exception メッセージを責めない文言へ正規化。
    final m = e.message;
    if (m.contains('already_hatched')) return 'この卵はすでに孵化しています';
    if (m.contains('not_ready_to_hatch')) return 'まだ孵化できません';
    if (m.contains('egg_not_found')) return '卵が見つかりませんでした';
    return 'サーバーで孵化に失敗しました';
  }
}

/// 卵リポジトリの DI（ARCHITECTURE §1-3）。テストでは override 可能。
/// Supabase 設定済み（Env.hasSupabase）なら本実装、未設定/PoC時はモックにフォールバック。
final eggRepositoryProvider = Provider<EggRepository>((ref) {
  if (Env.useSupabase) {
    return SupabaseEggRepository(ref, ref.read(supabaseClientProvider));
  }
  return MockEggRepository(ref);
});

/// たまご画面の状態を供給する FutureProvider（経済パラメータ依存）。
final eggsStateProvider = FutureProvider<EggsState>((ref) async {
  final params = await ref.watch(economyParamsProvider.future);
  final repo = ref.read(eggRepositoryProvider);
  return repo.loadEggs(params);
});

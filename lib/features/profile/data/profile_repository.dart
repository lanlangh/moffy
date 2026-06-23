import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/remote_config.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../domain/profile_models.dart';

/// プロフィール feature のデータ層（ARCHITECTURE §1-2 data）。
///
/// 抽象 [ProfileRepository] を公開し、Supabase（profiles/ledger/collection/streaks 集計）
/// の詳細を隠蔽する。第2bパスは [MockProfileRepository] で 5状態を成立させる。
///
/// 信頼境界: 統計はサーバー集計値の読み取り。クライアントは集計・改ざんしない。
abstract interface class ProfileRepository {
  /// プロフィール画面のスナップショット（統計 + アカウント状態）を取得する。
  Future<ProfileState> loadProfile({required int dexTotalEntries});
}

class MockProfileRepository implements ProfileRepository {
  MockProfileRepository(this._ref);

  final Ref _ref;

  @override
  Future<ProfileState> loadProfile({required int dexTotalEntries}) async {
    final isOnline = _ref.read(isOnlineProvider);

    // TODO(本実装): Supabase から集計を取得。
    //   * 総削減時間: point_ledger / usage_daily の確定合計。
    //   * 総獲得Mofi / 図鑑達成率: mofi_collection の distinct(species,shiny)。
    //   * 最長ストリーク: streaks.longest_streak。
    //   * 累計ポイント: point_ledger の delta 合計。
    //   オフライン時は Drift キャッシュ → 無ければ 0 埋め（落とさない）。
    return ProfileState(
      stats: ProfileStats(
        totalReducedMinutes: 1280, // 21時間20分
        totalMofi: 11,
        dexDiscovered: 9,
        dexTotal: dexTotalEntries,
        longestStreak: 12,
        totalPoints: 3640,
      ),
      account: const AccountState(
        isAnonymous: true, // 匿名ファースト（S10）。連携導線を促す。
        linkedProviders: [],
      ),
      isOffline: !isOnline,
    );
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return MockProfileRepository(ref);
});

/// プロフィール画面の状態（経済パラメータの dex_total_entries に依存）。
final profileStateProvider = FutureProvider<ProfileState>((ref) async {
  final params = await ref.watch(economyParamsProvider.future);
  final repo = ref.read(profileRepositoryProvider);
  return repo.loadProfile(dexTotalEntries: params.dexTotalEntries);
});

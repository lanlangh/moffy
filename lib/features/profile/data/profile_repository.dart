import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/remote_config.dart';
import '../../../core/error/failure.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../domain/profile_models.dart';

/// プロフィール feature のデータ層（ARCHITECTURE §1-2 data）。
///
/// 抽象 [ProfileRepository] を公開し、Supabase（profiles/ledger/collection/streaks 集計）
/// の詳細を隠蔽する。
///
/// 信頼境界: 統計はサーバー集計値（RPC `fn_profile_stats` / 0014）の読み取り。
/// クライアントは集計・改ざんしない。
abstract interface class ProfileRepository {
  /// プロフィール画面のスナップショット（統計 + アカウント状態）を取得する。
  Future<ProfileState> loadProfile({required int dexTotalEntries});
}

/// モック実装（Supabase 未設定の開発時 / FORCE_MOCK Webプレビュー専用）。
///
/// ⚠️ 本番ビルドでは使われないこと（S1 の教訓: 2026-08-06 に本 Provider が無条件で
/// Mock を返しており、全ユーザーのメニュー統計が同一のダミー値で公開されていた。
/// 分岐は [profileRepositoryProvider] の Env.hasSupabase 判定が唯一の正）。
class MockProfileRepository implements ProfileRepository {
  MockProfileRepository(this._ref);

  final Ref _ref;

  @override
  Future<ProfileState> loadProfile({required int dexTotalEntries}) async {
    final isOnline = _ref.read(isOnlineProvider);

    // プレビュー用の見本値（実機の本番経路では SupabaseProfileRepository が使われる）。
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

/// Supabase 本実装（S1 / 信頼境界）。
///
/// 統計はサーバー集計 RPC `fn_profile_stats`（0014 / security invoker + RLS 本人行のみ）。
///   * 総削減時間: 確定日の greatest(baseline - total, 0) 総和（reduce_total と同一定義）。
///   * 総獲得Mofi / 図鑑発見: mofi_collection（obtained_count 総和 / 行数）。
///   * 最長ストリーク: streaks.longest_streak。
///   * 累計pt: point_ledger の正の記帳のみ（残高とは別概念）。
/// アカウント状態は Supabase auth の現在ユーザー（匿名判定 / 連携プロバイダ）。
class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._ref, this._client);

  final Ref _ref;
  final SupabaseClient _client;

  @override
  Future<ProfileState> loadProfile({required int dexTotalEntries}) async {
    final isOnline = _ref.read(isOnlineProvider);
    if (!isOnline) {
      // 統計はサーバー集計のみ（ローカルキャッシュ無し）。0 埋めで返すと isFresh 判定が
      // 「これから記録を集めましょう」を誤表示する（= 偽の空状態）ため、オフラインは
      // 正直にエラーにする（メニュー側に ErrorView + リトライ導線あり）。
      throw const NetworkFailure('統計の取得には接続が必要です');
    }
    try {
      final res = await _client.rpc('fn_profile_stats');
      final stats = ((res as Map?) ?? const {}).cast<String, Object?>();
      int n(String key) => (stats[key] as num?)?.toInt() ?? 0;

      // アカウント状態は auth の現在ユーザーから（S10 / 表示用）。
      // 匿名ユーザーの identities には provider='anonymous' が入るため除外する。
      final user = _client.auth.currentUser;
      final providers = <String>[
        for (final identity in user?.identities ?? const <UserIdentity>[])
          if (identity.provider != 'anonymous') identity.provider,
      ];

      return ProfileState(
        stats: ProfileStats(
          totalReducedMinutes: n('total_reduced_minutes'),
          totalMofi: n('total_mofi'),
          dexDiscovered: n('dex_discovered'),
          dexTotal: dexTotalEntries,
          longestStreak: n('longest_streak'),
          totalPoints: n('total_points'),
        ),
        account: AccountState(
          isAnonymous: user?.isAnonymous ?? true,
          linkedProviders: providers,
          displayIdentifier: user?.email,
        ),
        isOffline: false,
      );
    } on PostgrestException catch (e, st) {
      Log.e('fn_profile_stats failed: ${e.code}', error: e, stack: st);
      throw const ServerFailure('統計の取得に失敗しました。時間をおいて再度お試しください');
    }
  }
}

/// プロフィールリポジトリの DI（ARCHITECTURE §1-3）。テストでは override 可能。
/// Supabase 設定済みなら本実装、未設定/PoC時はモックにフォールバック
/// （quest_repository.dart / account_repository.dart と同一パターン）。
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  if (Env.hasSupabase) {
    return SupabaseProfileRepository(ref, ref.read(supabaseClientProvider));
  }
  return MockProfileRepository(ref);
});

/// プロフィール画面の状態（経済パラメータの dex_total_entries に依存）。
final profileStateProvider = FutureProvider<ProfileState>((ref) async {
  final params = await ref.watch(economyParamsProvider.future);
  final repo = ref.read(profileRepositoryProvider);
  return repo.loadProfile(dexTotalEntries: params.dexTotalEntries);
});

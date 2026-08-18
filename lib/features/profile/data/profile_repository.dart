import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/remote_config.dart';
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
/// 分岐は [profileRepositoryProvider] の `Env.useSupabase` 判定が唯一の正。
/// `hasSupabase` ではない: FORCE_MOCK のプレビュー配信は Supabase 設定を持つため
/// `hasSupabase` では倒れず、プレビューが本番DBを読んでしまう
/// / daily_submission.dart:129-131 の明文ルール）。
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
    // アカウント状態は auth のローカルセッションから読めるので、通信の成否に依らず
    // 常に確定する（退会導線の描画をこれ以上ブロックしない）。
    final account = _accountFromAuth();

    if (!isOnline) {
      // 統計はサーバー集計のみ（ローカルキャッシュ無し）。ここで throw すると
      // menu_screen の async.when(error:) が body 全体を ErrorView に差し替え、
      // アカウント削除（S12 / 審査必須）と法務リンクごと画面から消える。
      // 統計だけを欠落させ、画面は必ず描画する。
      return ProfileState(stats: null, account: account, isOffline: true);
    }
    try {
      final res = await _client.rpc('fn_profile_stats');
      // 0 埋めフォールバックは禁止（0 埋めは isFresh を真にして、実績のある
      // ユーザーに「これから記録を集めていきましょう」と嘘をつく）。
      // 姉妹実装 usage_sync_repository.dart の厳格パースに揃える。
      if (res is! Map) {
        Log.e('fn_profile_stats returned non-map: ${res.runtimeType}');
        return ProfileState(stats: null, account: account, isOffline: false);
      }
      final raw = res.cast<String, Object?>();
      int? n(String key) => (raw[key] as num?)?.toInt();

      final reduced = n('total_reduced_minutes');
      final mofi = n('total_mofi');
      final dex = n('dex_discovered');
      final streak = n('longest_streak');
      final points = n('total_points');
      if (reduced == null ||
          mofi == null ||
          dex == null ||
          streak == null ||
          points == null) {
        // 想定外の形（RPC の戻り値定義とズレた等）。欠けた指標を 0 と偽らない。
        Log.e('fn_profile_stats missing keys: ${raw.keys.toList()}');
        return ProfileState(stats: null, account: account, isOffline: false);
      }

      return ProfileState(
        stats: ProfileStats(
          totalReducedMinutes: reduced,
          totalMofi: mofi,
          dexDiscovered: dex,
          dexTotal: dexTotalEntries,
          longestStreak: streak,
          totalPoints: points,
        ),
        account: account,
        isOffline: false,
      );
    } on PostgrestException catch (e, st) {
      // 0014 未適用（42883 / PGRST202）や権限欠落（42501）もここに来る。
      // 統計カード1枚が出ないだけで、メニュー全体の失敗ではない。
      Log.e('fn_profile_stats failed: ${e.code}', error: e, stack: st);
      return ProfileState(stats: null, account: account, isOffline: false);
    } catch (e, st) {
      // 通信断・タイムアウト等。ここでも画面は落とさない。
      Log.e('fn_profile_stats unexpected failure', error: e, stack: st);
      return ProfileState(stats: null, account: account, isOffline: false);
    }
  }

  /// auth の現在ユーザーからアカウント状態を作る（S10 / 表示用）。
  ///
  /// 匿名ユーザーは identity 行を持たない想定だが、将来 provider='anonymous' が
  /// 入る実装に変わっても「連携済み」に見えないよう防御的に除外する
  /// （実際の挙動は未検証。除外は no-op で害が無い側に倒してある）。
  AccountState _accountFromAuth() {
    final user = _client.auth.currentUser;
    return AccountState(
      isAnonymous: user?.isAnonymous ?? true,
      linkedProviders: <String>[
        for (final identity in user?.identities ?? const <UserIdentity>[])
          if (identity.provider != 'anonymous') identity.provider,
      ],
      displayIdentifier: user?.email,
    );
  }
}

/// プロフィールリポジトリの DI（ARCHITECTURE §1-3）。テストでは override 可能。
/// Supabase 設定済みなら本実装、未設定/PoC時はモックにフォールバック
/// （quest_repository.dart / account_repository.dart と同一パターン）。
final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  if (Env.useSupabase) {
    return SupabaseProfileRepository(ref, ref.read(supabaseClientProvider));
  }
  return MockProfileRepository(ref);
});

/// プロフィール画面の状態（経済パラメータの dex_total_entries に依存）。
final profileStateProvider = FutureProvider<ProfileState>((ref) async {
  // 接続状態が変わったら取り直す（オフラインで欠落した統計を復帰時に埋め、
  // OfflineBar の表示も追従させる）。watch なので復帰エッジで再評価される。
  ref.watch(isOnlineProvider);
  final params = await ref.watch(economyParamsProvider.future);
  final repo = ref.read(profileRepositoryProvider);
  return repo.loadProfile(dexTotalEntries: params.dexTotalEntries);
});

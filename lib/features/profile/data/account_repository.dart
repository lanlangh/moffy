import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/error/failure.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../domain/profile_models.dart';

/// アカウント連携・退会のデータ層（ARCHITECTURE §1-2 / S10,S12 / 信頼境界）。
///
/// 抽象 [AccountRepository] を公開する。連携・退会は **オンライン必須**（S10/S12）で、
/// 実体は Supabase auth / サーバーRPC の責務。第2bパスは「口」だけを用意し、
/// 実連携・実削除は TODO とする（モックは成功/失敗のフローのみ成立させる）。
///
/// 信頼境界:
///   * 連携（匿名→Apple/Google/メール）は Supabase auth の linkIdentity 等。
///   * 退会は サーバーRPC `fn_delete_account`（auth user + 全ユーザーデータを原子的に削除）。
///     クライアントは要求を送るだけ。残高・図鑑・利用統計の削除はサーバーが行う。
///   * サブスク解約はストア管理（App Store/Google Play）。アプリから解約不可（案内のみ / S12）。
abstract interface class AccountRepository {
  /// 連携導線を起動する（匿名→[provider] のソーシャル/メール連携 / S10）。
  ///
  /// オンライン必須。失敗は [Failure] を throw。成功時は連携後の [AccountState] を返す。
  Future<AccountState> linkProvider(AuthProvider provider);

  /// アカウント削除を実行する（S12 / 審査必須）。
  ///
  /// オンライン必須。サーバー（fn_delete_account）+ 端末（Drift）データを消す。
  /// 失敗時はデータを消さず [Failure] を throw（中途半端な削除を防ぐ / §5-4）。
  Future<void> deleteAccount();
}

class MockAccountRepository implements AccountRepository {
  MockAccountRepository(this._ref);

  final Ref _ref;

  @override
  Future<AccountState> linkProvider(AuthProvider provider) async {
    final isOnline = _ref.read(isOnlineProvider);
    if (!isOnline) {
      throw const NetworkFailure('連携には接続が必要です');
    }
    // TODO(本実装 / 信頼境界): Supabase auth で連携を実行する。
    //   * apple : signInWithApple → linkIdentity（iOS必須 / 4.8,5.1）。
    //   * google: signInWithGoogle → linkIdentity。
    //   * email : signInWithOtp（マジックリンク）→ 連携。
    //   成功後 profiles.is_linked を true 化（サーバー側 or RPC）。
    //   現状はモックとして連携済み状態を返し、UI遷移のみ成立させる。
    return AccountState(
      isAnonymous: false,
      linkedProviders: [provider.wire],
      displayIdentifier: provider == AuthProvider.email
          ? 'you@example.com'
          : provider.label,
    );
  }

  @override
  Future<void> deleteAccount() async {
    final isOnline = _ref.read(isOnlineProvider);
    if (!isOnline) {
      throw const NetworkFailure('削除には接続が必要です');
    }
    // TODO(本実装 / 信頼境界): サーバーRPC fn_delete_account を呼ぶ。
    //   * auth user / profiles / point_ledger / eggs / mofi_collection / usage_daily /
    //     streaks / user_quests を原子的に削除（即時論理削除 → 30日以内に物理削除 / S12）。
    //   * 成功後に端末側: Drift クリア + 認証セッション破棄 + sync_queue.clear()。
    //   * サブスク契約はストア管理のため**ここでは解約しない**（案内は画面側 / S12）。
    //   現状はモックとして成功で返し、削除フローのUIを成立させる。
    return;
  }
}

/// Supabase 本実装（S10/S12 / 信頼境界）。
///
/// 退会は サーバーRPC `fn_delete_account`（論理削除: profiles.deleted_at を立てる / F-03）。
/// 物理削除は 30日後に fn_purge_deleted_accounts() が cascade で行う（pg_cron / S12）。
/// 連携（linkProvider）は Apple/Google ネイティブサインインの配線が前提のため、本パスでは
/// 「口」だけ用意し、実連携は後続（iOS追従時に Apple、Android で Google/メール）に委ねる。
class SupabaseAccountRepository implements AccountRepository {
  SupabaseAccountRepository(this._ref, this._client);

  final Ref _ref;
  final SupabaseClient _client;

  @override
  Future<AccountState> linkProvider(AuthProvider provider) async {
    if (!_ref.read(isOnlineProvider)) {
      throw const NetworkFailure('連携には接続が必要です');
    }
    // TODO(後続): Apple/Google ネイティブサインイン → client.auth.linkIdentity。
    //   現状は未配線のため、利用不可を明示（黙って成功扱いにしない＝信頼境界）。
    throw const UnsupportedFailure('アカウント連携は現在準備中です');
  }

  @override
  Future<void> deleteAccount() async {
    if (!_ref.read(isOnlineProvider)) {
      throw const NetworkFailure('削除には接続が必要です');
    }
    try {
      // サーバーは論理削除（profiles.deleted_at をセット / F-03）。物理削除は 30日後に
      // fn_purge_deleted_accounts() が cascade で行う（pg_cron / S12）。
      await _client.rpc('fn_delete_account');
      // 端末側: 認証セッション破棄（Drift クリアは呼び出し側の責務 / S12）。
      // 退会後は profiles SELECT RLS（deleted_at is null）で本人行も見えなくなる。
      await _client.auth.signOut();
    } on PostgrestException catch (e, st) {
      Log.e('fn_delete_account failed: ${e.code}', error: e, stack: st);
      throw const ServerFailure('削除に失敗しました。時間をおいて再度お試しください');
    }
  }
}

final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  if (Env.hasSupabase) {
    return SupabaseAccountRepository(ref, ref.read(supabaseClientProvider));
  }
  return MockAccountRepository(ref);
});

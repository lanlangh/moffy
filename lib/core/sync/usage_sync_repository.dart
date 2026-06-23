import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../error/failure.dart';
import '../observability/log.dart';
import '../providers/supabase_provider.dart';
import 'finalize_models.dart';

/// 利用生データの提出 → サーバー確定（fn_finalize_day）のデータ層（ARCHITECTURE §1-5 / S8）。
///
/// 信頼境界（§2-3）:
///   * 端末（Drift）が生データの SSOT。本リポジトリはそれを usage_daily へ提出するだけ。
///   * 確定（基準値算出・差分・倍率・480pt上限・台帳冪等加算）は **すべてサーバー RPC**
///     `fn_finalize_day` の責務。クライアントは確定計算しない。
abstract interface class UsageSyncRepository {
  /// [draft] を usage_daily へ提出（upsert）し、fn_finalize_day で当日を確定する。
  ///
  /// 戻り値はサーバーの確定結果。失敗（ネットワーク/サーバー）は [Failure] を throw し、
  /// 呼び出し側（[SyncService]）がキュー再送で扱う（冪等なので再送安全 / S8）。
  Future<FinalizeDayResult> submitAndFinalize(UsageDailyDraft draft);
}

/// Supabase 本実装（信頼境界準拠）。
///
/// 1. usage_daily へ upsert（本人 insert / 未確定 update のみ RLS 許可 / 0001）。
/// 2. `fn_finalize_day(p_date)` を呼び、確定結果を [FinalizeDayResult] にパースする。
class SupabaseUsageSyncRepository implements UsageSyncRepository {
  SupabaseUsageSyncRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<FinalizeDayResult> submitAndFinalize(UsageDailyDraft draft) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) {
      throw const AuthFailure('確定には認証セッションが必要です');
    }

    try {
      // 1. 生データ提出（本人分）。(user_id, usage_date) で upsert。
      //    確定済み行は RLS（usage_update_own_unfinalized）で更新不可だが、
      //    fn_finalize_day が冪等（already_finalized）なので二重確定は起きない。
      await _client.from('usage_daily').upsert(
        {'user_id': uid, ...draft.toUsageRow()},
        onConflict: 'user_id,usage_date',
      );

      // 2. サーバー確定（基準値・差分・倍率・上限・冪等加算はすべてサーバー）。
      final res = await _client.rpc(
        'fn_finalize_day',
        params: {'p_date': draft.dateKey},
      );
      if (res is! Map) {
        throw const ServerFailure('確定結果の形式が不正です');
      }
      return FinalizeDayResult.fromJson(res.cast<String, Object?>());
    } on PostgrestException catch (e, st) {
      Log.e('fn_finalize_day failed: ${e.code}', error: e, stack: st);
      throw ServerFailure(_finalizeMessage(e));
    }
  }

  String _finalizeMessage(PostgrestException e) {
    final m = e.message;
    if (m.contains('future_date_not_allowed')) return '未来日は確定できません';
    if (m.contains('unauthorized')) return '認証が切れています。再度サインインしてください';
    if (m.contains('profile_not_found')) return 'プロフィールが見つかりませんでした';
    return 'サーバーで確定に失敗しました';
  }
}

/// モック実装（Supabase 未設定 / PoC・UI確認用）。
///
/// 実DBが無い環境ではサーバー確定を行えないため、「未確定（reason=offline_or_mock）」を返す。
/// これにより S8 の競合解決は「ローカル暫定値を維持（減らさない）」側に倒れ、安全に動作する。
class MockUsageSyncRepository implements UsageSyncRepository {
  const MockUsageSyncRepository();

  @override
  Future<FinalizeDayResult> submitAndFinalize(UsageDailyDraft draft) async {
    Log.d('submitAndFinalize(mock): ${draft.dateKey} skipped (no live DB)');
    return const FinalizeDayResult(
      finalized: false,
      reason: 'offline_or_mock',
    );
  }
}

/// DI（ARCHITECTURE §1-3）。Supabase 設定済みなら本実装、未設定はモックへフォールバック。
final usageSyncRepositoryProvider = Provider<UsageSyncRepository>((ref) {
  if (Env.hasSupabase) {
    return SupabaseUsageSyncRepository(ref.read(supabaseClientProvider));
  }
  return const MockUsageSyncRepository();
});

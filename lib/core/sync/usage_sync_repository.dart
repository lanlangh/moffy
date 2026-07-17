import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../error/failure.dart';
import '../observability/log.dart';
import '../providers/supabase_provider.dart';
import 'finalize_models.dart';

/// 利用生データの提出 → サーバー確定のデータ層（ARCHITECTURE §1-5 / S8）。
///
/// 信頼境界（§2-3 / S4 / migration 0011）:
///   * 端末（Drift）が生データの SSOT。本リポジトリはそれをサーバーへ提出するだけ。
///   * 提出と確定は **1本の RPC** `fn_submit_and_finalize_day` に統合されている
///     （生データ書込・対象日検証・行ロック・確定を1トランザクションで行う）。
///     確定（基準値算出・差分・倍率・480pt上限・台帳冪等加算）は**すべてサーバー**の責務。
///   * **対象日もサーバーが決める**。端末時計は信用しない（1日進んでいると「端末の昨日」＝
///     「サーバーの今日」になり、朝の少ない利用時間で満額確定できてしまう / Codex #1）。
///   * usage_daily へのクライアント直接書込は 0011 で剥奪済み（書込経路は上記RPCのみ）。
abstract interface class UsageSyncRepository {
  /// 提出・確定すべき日をサーバーに問い合わせる（migration 0011 / S4: 日付境界の正）。
  ///
  /// これは「どの日の OS 利用データを集めるか」を知るための**照会**であり、権限境界では
  /// ない（境界は [submitAndFinalize] のサーバー側検証が持つ）。事前照会と本送信の間に
  /// 日付が変わっても、サーバーが 'wrong_finalize_date' で弾き次回に回る（Codex #5）。
  ///
  /// 実バックエンドが無い環境（モック）では null を返す。
  Future<PendingFinalizeDate?> pendingFinalizeDate();

  /// [draft] の生データを提出し、同一トランザクションでサーバー確定する。
  ///
  /// 戻り値はサーバーの確定結果。失敗（ネットワーク/サーバー）は [Failure] を throw し、
  /// 呼び出し側（[SyncService]）がキュー再送で扱う（冪等なので再送安全 / S8）。
  Future<FinalizeDayResult> submitAndFinalize(UsageDailyDraft draft);
}

/// Supabase 本実装（信頼境界準拠）。
///
/// `fn_submit_and_finalize_day`（0011）1本を呼ぶだけ。サーバーが1トランザクションで
///   1. 対象日を自分で計算し、申告と一致しなければ拒否（当日確定・遡及加点を封じる）、
///   2. 生データ行を definer 権限で書き（列GRANTの非対称を回避 / 42501 を起こさない）、
///   3. 行ロックを取って確定済みか判定し（並行要求を直列化）、
///   4. 未確定なら `fn_finalize_day` 本体へ委譲して確定する。
/// 本体 `fn_finalize_day` は 0011 で authenticated から revoke 済み。
class SupabaseUsageSyncRepository implements UsageSyncRepository {
  SupabaseUsageSyncRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<PendingFinalizeDate?> pendingFinalizeDate() async {
    try {
      final res = await _client.rpc('fn_pending_finalize_date');
      if (res is! Map) {
        throw const ServerFailure('対象日の取得結果の形式が不正です');
      }
      return PendingFinalizeDate.fromJson(res.cast<String, Object?>());
    } on PostgrestException catch (e, st) {
      Log.e('fn_pending_finalize_date failed: ${e.code}', error: e, stack: st);
      throw ServerFailure(_finalizeMessage(e));
    }
  }

  @override
  Future<FinalizeDayResult> submitAndFinalize(UsageDailyDraft draft) async {
    if (_client.auth.currentUser == null) {
      // サーバーも auth.uid() で弾くが、無駄な往復を避けるため手前で止める。
      throw const AuthFailure('確定には認証セッションが必要です');
    }

    try {
      // 提出＋確定を1トランザクションで実行（0011）。
      //   * 生データ書込はサーバー(definer)が行う＝クライアントは usage_daily に触らない。
      //   * 対象日の検証・行ロック・確定済み判定・確定計算はすべてサーバーの責務。
      //   * 引数は生データのみ（is_anomaly / is_finalized / user_id は渡さない）。
      final res = await _client.rpc(
        'fn_submit_and_finalize_day',
        params: draft.toRpcParams(),
      );
      if (res is! Map) {
        throw const ServerFailure('確定結果の形式が不正です');
      }
      return FinalizeDayResult.fromJson(res.cast<String, Object?>());
    } on PostgrestException catch (e, st) {
      Log.e('fn_submit_and_finalize_day failed: ${e.code}', error: e, stack: st);
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

  /// 実DBが無いので対象日を決められない。null＝提出しない（呼び出し側が諦める）。
  @override
  Future<PendingFinalizeDate?> pendingFinalizeDate() async => null;

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

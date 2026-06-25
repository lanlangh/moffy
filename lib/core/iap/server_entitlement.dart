/// サーバー権威のプレミアム判定（entitlements テーブル / 信頼境界の正）。
///
/// 位置づけ（IAP_SETUP §6 / PRICING §4-2）:
///   * プレミアム機能の**最終解放判定はサーバーの entitlements を正**とする。
///     クライアントの RevenueCat 状態（`premiumStatusProvider`）は即時UI反映の補助。
///   * 本ファイルは Supabase `entitlements` から「自分の行」を読み取り（RLS select-own）、
///     サーバー権威の premium 判定を返す。書き込みは一切しない（Webhook/service_role 専管）。
///
/// 信頼境界:
///   * クライアントは anon key のみ。service_role / sk_ キーは絶対に持たない（Edge Function 専用）。
///   * 行が無い/未認証/Supabase 未設定なら null（= 不明）。合成側でフォールバックを決める。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/env.dart';
import '../observability/log.dart';
import '../providers/supabase_provider.dart';

/// サーバー（entitlements）から見たプレミアム状態のスナップショット。
class ServerEntitlement {
  const ServerEntitlement({
    required this.isPremium,
    this.productId,
    this.expiresAt,
  });

  /// サーバー権威の premium 判定（is_premium かつ未失効）。
  final bool isPremium;

  /// 現在有効なサブスクの商品ID（監査・表示補助）。
  final String? productId;

  /// 失効予定日時（null=無期限 or 非課金）。
  final DateTime? expiresAt;

  /// 行が存在しない（=まだ課金履歴なし）デフォルト。
  static const ServerEntitlement none = ServerEntitlement(isPremium: false);
}

/// entitlements データ層の抽象（テストで override 可能）。
abstract interface class ServerEntitlementRepository {
  /// 自分の entitlements 行を読み、サーバー権威の判定を返す。
  /// 取得できない（行なし/未認証）場合は null を返す（= 不明・フォールバック判断は呼出側）。
  Future<ServerEntitlement?> fetch();
}

/// Supabase 実装。RLS `entitlements_select_own` により自分の行のみ読める。
class SupabaseServerEntitlementRepository
    implements ServerEntitlementRepository {
  SupabaseServerEntitlementRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<ServerEntitlement?> fetch() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null; // 未認証は不明扱い。
    try {
      final row = await _client
          .from('entitlements')
          .select('is_premium, product_id, expires_at')
          .eq('user_id', uid)
          .maybeSingle();
      if (row == null) return ServerEntitlement.none; // 行なし=未課金（確定値）。

      final expiresRaw = row['expires_at'] as String?;
      final expiresAt =
          expiresRaw == null ? null : DateTime.tryParse(expiresRaw);
      // サーバーで is_premium は判定済みだが、二重防御で未失効も確認する
      // （Webhook 反映遅延・期限到来の境界をクライアントでも弾く）。
      final notExpired =
          expiresAt == null || expiresAt.isAfter(DateTime.now());
      final isPremium = (row['is_premium'] == true) && notExpired;

      return ServerEntitlement(
        isPremium: isPremium,
        productId: row['product_id'] as String?,
        expiresAt: expiresAt,
      );
    } catch (e, st) {
      // 取得失敗は不明扱い（null）。機能ガードはフォールバックで保守的に倒す。
      Log.e('entitlements fetch failed', error: e, stack: st);
      return null;
    }
  }
}

/// entitlements リポジトリの DI。Supabase 設定済みなら本実装、未設定なら null。
final serverEntitlementRepositoryProvider =
    Provider<ServerEntitlementRepository?>((ref) {
  if (!Env.hasSupabase) return null;
  return SupabaseServerEntitlementRepository(
    ref.read(supabaseClientProvider),
  );
});

/// サーバー権威のプレミアム状態（FutureProvider / 手動 refresh で再取得）。
///
/// リアルタイム購読は過剰実装を避けて見送り（まずは Future）。購入直後の即時反映は
/// クライアント `premiumStatusProvider` が担い、本プロバイダは確定判定の正を供給する。
/// Supabase 未設定/取得不可時は null（合成側がクライアント値へフォールバック）。
final serverPremiumProvider = FutureProvider<ServerEntitlement?>((ref) async {
  final repo = ref.watch(serverEntitlementRepositoryProvider);
  if (repo == null) return null;
  return repo.fetch();
});

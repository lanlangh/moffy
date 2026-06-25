/// IAP（課金）の Riverpod プロバイダ群（ARCHITECTURE §1-3）。
///
/// 提供する依存:
///   * [iapServiceProvider]        … RevenueCat 実装 or no-op モック（Env で切替・override 可）。
///   * [offeringsProvider]         … offering `default` の提示プラン（FutureProvider）。
///   * [premiumStatusProvider]     … クライアント側のプレミアム状態（Stream / 即時UI反映）。
///   * [isPremiumProvider]         … 即時UI表示用（server || client）。
///   * [isPremiumConfirmedProvider]… 機能ガード（確定処理）用（server のみ）。
///
/// 信頼境界（PRICING §4-2 / ARCHITECTURE §0-2 / IAP_SETUP §6-3）— ここが本実装の肝:
///   * RevenueCat の [premiumStatusProvider] は**クライアントから見た補助情報**。
///     購入直後の即時UI反映（ボタンの状態・ペイウォールを閉じる等）に使う。
///   * 機能解放（保管枠200・限定Mofi抽選・プレミアム卵導線）の**最終判定はサーバーの
///     entitlements を正**とする（`serverPremiumProvider` / server_entitlement.dart）。
///   * 表示と確定で2つに分離する:
///       - [isPremiumProvider]          = server || client（即時表示）。
///       - [isPremiumConfirmedProvider] = server のみ（確定ガード・改ざん耐性）。
///     サーバーが不明（未設定/未認証/取得不可）なら、表示はクライアントへフォールバックし、
///     確定は false に倒す（未確認で特典を解放しない）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../observability/log.dart';
import '../providers/supabase_provider.dart';
import 'iap_models.dart';
import 'iap_service.dart';
import 'server_entitlement.dart';

/// IAP サービス本体。Env に公開SDKキーがあれば RevenueCat 実装、無ければ no-op モック。
///
/// テストや UI 確認では override してモックを注入できる（Supabase 方式と同じ）。
final iapServiceProvider = Provider<IapService>((ref) {
  final apple = isApplePlatform;
  if (!Env.hasRevenueCat(isApplePlatform: apple)) {
    // キー未設定 → no-op（プレミアム=false）。クラッシュさせず5状態を成立。
    return const NoopIapService(diagnosticCode: 'NO-KEY');
  }
  return RevenueCatIapService(
    publicSdkKey: Env.revenueCatKey(isApplePlatform: apple),
  );
});

/// IAP サービスを初期化し、初期化できたかを返す（main から1度呼ぶレール）。
///
/// 失敗しても false を返すだけ（例外を投げない）。UI は no-op と同じ挙動で動く。
final iapConfiguredProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(iapServiceProvider);

  // App User ID を Supabase の user_id に揃える（IAP_SETUP §6-2 / Webhook 突合）。
  // Supabase 設定済みかつ認証済みなら現在の user_id で初期化し、未認証/未設定なら
  // 従来通り匿名（null）で初期化する。
  String? appUserId;
  if (Env.hasSupabase) {
    // supabaseClientProvider は main() で override 済み（hasSupabase 時のみ参照する）。
    appUserId = ref.read(supabaseClientProvider).auth.currentUser?.id;
  }

  final ok = await service.configure(appUserId: appUserId);

  // configure 後に認証済み user_id があれば logIn で確実に揃える
  // （configure 時点で匿名だった/後から連携した場合の是正 / IAP_SETUP §6-2）。
  if (ok && appUserId != null && appUserId.isNotEmpty) {
    await service.logIn(appUserId);
    Log.d('IAP appUserId aligned with Supabase user');
  }
  return ok;
});

/// offering `default` の提示プラン（FutureProvider）。
/// 取得失敗/未設定は空（空状態）。ペイウォールが5状態に分岐する。
final offeringsProvider = FutureProvider<IapOfferings>((ref) async {
  // 先に初期化を待つ（未初期化での getOfferings 失敗を避ける）。
  await ref.watch(iapConfiguredProvider.future);
  final service = ref.watch(iapServiceProvider);
  return service.fetchOfferings();
});

/// クライアント側のプレミアム状態（Stream / 即時UI反映）。
///
/// CustomerInfo の更新（購入・更新・解約・フォアグラウンド復帰）を購読する。
/// 機能ガードには直接使わず、[isPremiumProvider] 経由で参照すること。
final premiumStatusProvider = StreamProvider<PremiumStatus>((ref) {
  final service = ref.watch(iapServiceProvider);
  return service.premiumStatusStream();
});

/// サーバー権威の premium 判定（不明=null）。合成プロバイダの共通参照点。
///
/// `serverPremiumProvider`（FutureProvider）の data を bool? に畳む。
///   * data かつ非null  … サーバー確定値（true/false）。
///   * data だが null   … Supabase 未設定/未認証/取得不可（= 不明）。
///   * loading/error    … 不明（null）。
/// 「不明」のときは合成側がクライアント値へフォールバックする。
bool? _serverPremiumOrNull(Ref ref) {
  return ref.watch(serverPremiumProvider).maybeWhen(
        data: (e) => e?.isPremium,
        orElse: () => null,
      );
}

/// クライアント補助値（即時反映 / RevenueCat CustomerInfo 由来）。
bool _clientPremium(Ref ref) {
  return ref.watch(premiumStatusProvider).maybeWhen(
        data: (s) => s.isPremium,
        orElse: () => false,
      );
}

/// 即時UI表示用のプレミアム判定（IAP_SETUP §6-3）。
///
/// 合成規則: `server.isPremium || client.isPremium`。購入直後の体験を滑らかにするため
/// クライアント値も OR する。**機能解放の確定判定には使わない**（表示専用）。
/// 用途例: メニューのプレミアムバッジ、ペイウォールの「加入済み」表示、保管枠アップセルの抑制。
///
/// サーバーが「不明」（未設定/未認証/取得失敗）なら、従来通りクライアント値にフォールバックする。
final isPremiumProvider = Provider<bool>((ref) {
  final server = _serverPremiumOrNull(ref);
  final client = _clientPremium(ref);
  // server が確定値ならそれを OR の左に。不明(null)なら client のみで判定（フォールバック）。
  return (server ?? false) || client;
});

/// 機能ガード（確定処理）用のプレミアム判定（IAP_SETUP §6-3）。
///
/// 合成規則: **server.isPremium のみ**。改ざん耐性が要る確定処理（保管枠200の解放等）は、
/// クライアントの主張を一切信用せずサーバー entitlements の値だけで判定する。
///   * サーバーが確定値を返すまで（loading/未設定/未認証/取得失敗 = 不明）は **false**
///     に倒す（保守的: 未確認で特典を解放しない）。
///   * 注意: Supabase 未設定のローカル/PoC 環境では常に false になる。確定ガードを
///     クライアントに置く場合はこのプロバイダを使うこと（表示は [isPremiumProvider]）。
final isPremiumConfirmedProvider = Provider<bool>((ref) {
  return _serverPremiumOrNull(ref) ?? false;
});

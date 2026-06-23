/// IAP（課金）の Riverpod プロバイダ群（ARCHITECTURE §1-3）。
///
/// 提供する依存:
///   * [iapServiceProvider]        … RevenueCat 実装 or no-op モック（Env で切替・override 可）。
///   * [offeringsProvider]         … offering `default` の提示プラン（FutureProvider）。
///   * [premiumStatusProvider]     … クライアント側のプレミアム状態（Stream / 即時UI反映）。
///   * [isPremiumProvider]         … 機能ガード用の最終判定（サーバー値を正とする合成）。
///
/// 信頼境界（PRICING §4-2 / ARCHITECTURE §0-2）— ここが本実装の肝:
///   * RevenueCat の [premiumStatusProvider] は**クライアントから見た補助情報**。
///     購入直後の即時UI反映（ボタンの状態・ペイウォールを閉じる等）に使う。
///   * 機能解放（保管枠200・限定Mofi抽選・プレミアム卵導線）の**最終判定はサーバーの
///     entitlements を正**とする。[isPremiumProvider] はサーバー値を優先し、未配線の
///     現状はクライアント値にフォールバックする（TODO で明示）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import 'iap_models.dart';
import 'iap_service.dart';

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
  // TODO(サーバー連携): appUserId に Supabase の user_id を渡し、RevenueCat App User ID と
  //   揃える（PRICING §4-2 / 機種変復元・Webhook 突合）。現状は匿名IDのまま。
  return service.configure();
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

/// 機能解放の最終判定（サーバー entitlements を正とする合成）。
///
/// 現状（サーバー未配線）はクライアント RC 状態にフォールバックする。
/// サーバー配線後は、サーバーの entitlement 値を優先して合成する（下記 TODO）。
///
/// TODO(サーバー検証・最重要 / PRICING §4-2):
///   * RevenueCat Webhook → Supabase Edge Function で `entitlements`（is_premium /
///     premium_until）を更新し、サーバー側 `serverPremiumProvider`（未実装）を真とする。
///   * レビュアーバイパス: サーバーで「レビュー用アカウント = premium」を返す口を用意する
///     （クライアントで tier 固定すると CustomerInfo listener に上書きされるため、
///     サーバー側 + setPlan レベルの reviewer-aware 防御で対応 / iap-setup 5番）。
///   * 合成規則（配線後）: server.isPremium || client.isPremium を即時表示に使いつつ、
///     保管枠ガード等の確定処理は server.isPremium のみで判定する。
final isPremiumProvider = Provider<bool>((ref) {
  // クライアント補助値（即時反映）。
  final clientPremium = ref.watch(premiumStatusProvider).maybeWhen(
        data: (s) => s.isPremium,
        orElse: () => false,
      );
  // TODO(サーバー): final serverPremium = ref.watch(serverPremiumProvider) ?? clientPremium;
  //   return serverPremium; // サーバー値が正。未配線の現状はクライアント値で代用。
  return clientPremium;
});

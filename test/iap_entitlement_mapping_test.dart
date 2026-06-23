import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/pricing.dart';
import 'package:moffy/core/iap/iap_models.dart';
import 'package:moffy/core/iap/iap_service.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

/// entitlement 状態マッピングの単体テスト。
///
/// 信頼境界（PRICING §4-2）: クライアントの [PremiumStatus] は entitlement `premium` の
/// 有効性で導出する。ここでは「商品IDで分岐せず entitlement で判定する」仕様を回帰固定する。
void main() {
  CustomerInfo customerInfo(Map<String, EntitlementInfo> active) {
    return CustomerInfo(
      EntitlementInfos(active, active),
      const {},
      const [],
      const [],
      const [],
      '2026-06-23T00:00:00Z',
      'user_1',
      const {},
      '2026-06-23T00:00:00Z',
    );
  }

  EntitlementInfo entitlement({
    required bool isActive,
    required bool willRenew,
    String productId = RevenueCatIds.productMonthly,
    String? expiration,
  }) {
    return EntitlementInfo(
      RevenueCatIds.entitlementPremium,
      isActive,
      willRenew,
      '2026-06-16T00:00:00Z', // latestPurchaseDate
      '2026-06-16T00:00:00Z', // originalPurchaseDate
      productId,
      true, // isSandbox
      expirationDate: expiration,
    );
  }

  test('entitlement "premium" がアクティブ → isPremium true', () {
    final info = customerInfo({
      RevenueCatIds.entitlementPremium: entitlement(
        isActive: true,
        willRenew: true,
        expiration: '2026-07-16T00:00:00Z',
      ),
    });
    final status = RevenueCatIapService.mapCustomerInfo(info);
    expect(status.isPremium, isTrue);
    expect(status.source, PremiumSource.revenueCat);
    expect(status.activeProductId, RevenueCatIds.productMonthly);
    expect(status.willRenew, isTrue);
    expect(status.expirationDate, isNotNull);
  });

  test('active に premium が無い → isPremium false', () {
    final info = customerInfo(const {});
    final status = RevenueCatIapService.mapCustomerInfo(info);
    expect(status.isPremium, isFalse);
    expect(status.source, PremiumSource.revenueCat);
  });

  test('年額商品でも entitlement で判定（商品IDで分岐しない）', () {
    final info = customerInfo({
      RevenueCatIds.entitlementPremium: entitlement(
        isActive: true,
        willRenew: false, // 解約済みだが期限内
        productId: RevenueCatIds.productYearly,
        expiration: '2026-12-31T00:00:00Z',
      ),
    });
    final status = RevenueCatIapService.mapCustomerInfo(info);
    expect(status.isPremium, isTrue);
    expect(status.activeProductId, RevenueCatIds.productYearly);
    expect(status.willRenew, isFalse); // 解約済み（期限まで有効）を表現
  });
}

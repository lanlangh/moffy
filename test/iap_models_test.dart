import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/pricing.dart';
import 'package:moffy/core/iap/iap_models.dart';
import 'package:moffy/core/iap/iap_service.dart';

/// IAP 純粋ロジックの単体テスト（QA引き継ぎ観点 / iap-setup の罠を回帰で固定）。
///
/// 検証対象:
///   * トライアル資格に基づく表示判定（誤表示はリジェクト要因）。
///   * 年額の割安訴求の算出（価格未取得時は訴求しない＝誤表示防止）。
///   * 列挙する特典が「実装済みフラグのものだけ」になっているか（誇大表示回避）。
///   * no-op サービスが常にプレミアム=false・商品なしを返すか（未設定フォールバック）。
void main() {
  PlanOffer offer({
    required BillingPeriod period,
    required double amount,
    required TrialEligibility eligibility,
    String? trialLabel,
  }) {
    return PlanOffer(
      productId: 'p',
      packageId: r'$rc_x',
      period: period,
      priceString: '¥${amount.toInt()}',
      priceAmount: amount,
      currencyCode: 'JPY',
      trialEligibility: eligibility,
      trialPeriodLabel: trialLabel,
    );
  }

  group('トライアル表示判定（資格 eligible のときだけ）', () {
    test('eligible のときだけ showTrialBadge が true', () {
      expect(
        offer(
          period: BillingPeriod.monthly,
          amount: 480,
          eligibility: TrialEligibility.eligible,
          trialLabel: '7日間',
        ).showTrialBadge,
        isTrue,
      );
    });

    test('ineligible（消費済み/地域外）は表示しない', () {
      expect(
        offer(
          period: BillingPeriod.monthly,
          amount: 480,
          eligibility: TrialEligibility.ineligible,
        ).showTrialBadge,
        isFalse,
      );
    });

    test('unknown（未判定）は安全側で表示しない', () {
      expect(
        offer(
          period: BillingPeriod.annual,
          amount: 4800,
          eligibility: TrialEligibility.unknown,
        ).showTrialBadge,
        isFalse,
      );
    });
  });

  group('AnnualSavings.compute（年額の割安訴求）', () {
    test('PRICING 基準（月480/年4800）で 約17%OFF・月割り400', () {
      final s = AnnualSavings.compute(monthlyAmount: 480, annualAmount: 4800);
      expect(s, isNotNull);
      expect(s!.perMonthAmount, 400);
      expect(s.discountPercent, 17); // (5760-4800)/5760 = 16.6.. -> 17
    });

    test('価格未取得（0）なら null（誤った割引%を出さない）', () {
      expect(AnnualSavings.compute(monthlyAmount: 0, annualAmount: 4800), isNull);
      expect(AnnualSavings.compute(monthlyAmount: 480, annualAmount: 0), isNull);
    });

    test('年額が割安でない（設定ミス）なら null', () {
      // 月480 × 12 = 5760。年額が 5760 以上なら訴求しない。
      expect(
        AnnualSavings.compute(monthlyAmount: 480, annualAmount: 6000),
        isNull,
      );
    });

    test('割引率は (月×12 − 年) / (月×12) で計算（任意の通貨額でも整合）', () {
      final s = AnnualSavings.compute(monthlyAmount: 10, annualAmount: 96);
      expect(s, isNotNull);
      expect(s!.discountPercent, 20); // (120-96)/120 = 0.2
      expect(s.perMonthAmount, 8);
    });
  });

  group('PremiumBenefits.active（実装済み特典のみ列挙）', () {
    final benefits = PremiumBenefits.active;

    test('保管枠特典を含み、説明に SSOT の値（20→200）が入る', () {
      final storage = benefits.firstWhere(
        (b) => b.kind == PremiumBenefitKind.storage,
      );
      expect(
        storage.description,
        contains('${StorageLimits.freeStorageSlots}'),
      );
      expect(
        storage.description,
        contains('${StorageLimits.premiumStorageSlots}'),
      );
    });

    test('限定Mofi/プレミアム卵は実装フラグ true のときだけ含まれる', () {
      final hasExclusive =
          benefits.any((b) => b.kind == PremiumBenefitKind.exclusiveMofi);
      final hasPremiumEgg =
          benefits.any((b) => b.kind == PremiumBenefitKind.premiumEgg);
      expect(hasExclusive, PremiumEntitlements.premiumUnlocksExclusiveMofi);
      expect(hasPremiumEgg, PremiumEntitlements.premiumUnlocksPremiumEgg);
    });

    test('詳細分析（v1.1送り）は宣伝しない＝特典に含めない', () {
      // detailedAnalytics は false（pricing.dart）。特典 kind に該当値が無いことを確認。
      // （PremiumBenefitKind に analytics を設けていない＝構造的に列挙不可）。
      expect(PremiumEntitlements.detailedAnalytics, isFalse);
    });

    test('広告削除は freeShowsAds のときだけ列挙する（実装＝広告あり と一致）', () {
      final hasAdFree =
          benefits.any((b) => b.kind == PremiumBenefitKind.adFree);
      expect(hasAdFree, PremiumEntitlements.freeShowsAds);
    });
  });

  group('PremiumStatus（既定値）', () {
    test('free は非プレミアム', () {
      expect(PremiumStatus.free.isPremium, isFalse);
      expect(PremiumStatus.free.source, PremiumSource.none);
    });

    test('mockFree は非プレミアム・由来 mock', () {
      expect(PremiumStatus.mockFree.isPremium, isFalse);
      expect(PremiumStatus.mockFree.source, PremiumSource.mock);
    });
  });

  group('NoopIapService（未設定フォールバック）', () {
    const service = NoopIapService(diagnosticCode: 'NO-KEY');

    test('configure は false（初期化されない）', () async {
      expect(await service.configure(), isFalse);
    });

    test('fetchOfferings は空（空状態）', () async {
      final o = await service.fetchOfferings();
      expect(o.isEmpty, isTrue);
      expect(o.monthly, isNull);
      expect(o.annual, isNull);
    });

    test('fetchPremiumStatus は常に非プレミアム', () async {
      final s = await service.fetchPremiumStatus();
      expect(s.isPremium, isFalse);
    });

    test('purchase は診断コード付きで failed', () async {
      final r = await service.purchase(
        offer(
          period: BillingPeriod.monthly,
          amount: 480,
          eligibility: TrialEligibility.ineligible,
        ),
      );
      expect(r.outcome, IapPurchaseOutcome.failed);
      expect(r.diagnosticCode, 'NO-KEY');
      expect(r.status.isPremium, isFalse);
    });

    test('restore は nothingToRestore', () async {
      final r = await service.restore();
      expect(r.outcome, IapPurchaseOutcome.nothingToRestore);
    });

    test('managementUrl は null（未購入/未設定）', () async {
      expect(await service.managementUrl(), isNull);
    });
  });
}

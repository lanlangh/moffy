import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/iap/iap_models.dart';

/// 無料トライアルの表示条件を守る。
///
/// 背景（2026-08-25・課金経路の監査で発覚）:
///   「商品に無料の導入オファーがあるか」だけを見て「7日間 無料ではじめる」を
///   出していた。それは**商品側の設定**であって「この人が使えるか」ではない。
///   Apple のトライアルは同一グループで生涯1回なので、2回目の人には資格が無い。
///   その人に無料と表示すると、支払いシートは初回から満額を請求し、
///   **表示と請求が食い違う**（Guideline 3.1.2 の典型的な指摘）。
///
///   [TrialEligibility] のコメントで「無条件表示するとリジェクト要因」と
///   自分たちで警告していたのに、資格を問い合わせる実装が無かった。
///
/// 判定できないとき（unknown / 例外 / Android）は**資格なしに倒す**のが正しい。
/// 出し損ねても損害は無いが、出し過ぎるとリジェクトになる。
void main() {
  PlanOffer offer(TrialEligibility e) => PlanOffer(
        productId: 'moffy_premium_yearly',
        packageId: r'$rc_annual',
        period: BillingPeriod.annual,
        priceString: '¥4,800',
        priceAmount: 4800,
        trialEligibility: e,
        trialLabel: e == TrialEligibility.eligible ? '7日' : null,
      );

  test('資格がある人にだけトライアルを表示する', () {
    expect(offer(TrialEligibility.eligible).showTrialBadge, isTrue);
  });

  test('資格が無い人には表示しない（消費済み・地域外）', () {
    expect(offer(TrialEligibility.ineligible).showTrialBadge, isFalse);
  });

  test('判定できないときは表示しない（誤解を招く表示を作らない）', () {
    // SDK も「unknown のときは通常価格を出せ」と明記している。
    expect(offer(TrialEligibility.unknown).showTrialBadge, isFalse);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/iap/iap_models.dart';

/// ペイウォールの「選べるプランが片方しか無い」ときの挙動を守る。
///
/// 背景（2026-08-21・2.1(b) リジェクト後の点検で発覚）:
///   選択の初期値が年額固定だったため、**年額が取れず月額だけ取れた場合に
///   選択が null になり、「購入する」ボタンが最初から押せない灰色**になっていた。
///   理由の表示も無いので、ユーザーからは行き止まりに見える。
///   ストアの一時的な不調や、片方だけ審査を通っている状況で現実に起こりうる。
///
/// 画面のロジックと同じ式をここで固定する（画面の中に埋めるとテストが書けないため）。
BillingPeriod effectiveSelection({
  required BillingPeriod selected,
  required bool hasAnnual,
  required bool hasMonthly,
}) =>
    (selected == BillingPeriod.annual && hasAnnual) || !hasMonthly
        ? BillingPeriod.annual
        : BillingPeriod.monthly;

void main() {
  group('両方そろっているときは、選んだとおりになる', () {
    test('年額を選べば年額', () {
      expect(
        effectiveSelection(
            selected: BillingPeriod.annual, hasAnnual: true, hasMonthly: true),
        BillingPeriod.annual,
      );
    });

    test('月額を選べば月額', () {
      expect(
        effectiveSelection(
            selected: BillingPeriod.monthly, hasAnnual: true, hasMonthly: true),
        BillingPeriod.monthly,
      );
    });
  });

  group('片方しか無いときは、ある側に倒れる（行き止まりを作らない）', () {
    test('年額が無く月額だけ → 月額が選ばれる', () {
      // 既定は年額。ここで年額のままだと購入ボタンが押せない灰色になる。
      expect(
        effectiveSelection(
            selected: BillingPeriod.annual, hasAnnual: false, hasMonthly: true),
        BillingPeriod.monthly,
      );
    });

    test('月額が無く年額だけ → 年額が選ばれる', () {
      expect(
        effectiveSelection(
            selected: BillingPeriod.monthly, hasAnnual: true, hasMonthly: false),
        BillingPeriod.annual,
      );
    });
  });

  test('どちらも無いときは年額に倒れる（呼び出し側が空状態を出す）', () {
    // この場合 selectedPlan は null になり、画面は「プランがありません」を出す。
    expect(
      effectiveSelection(
          selected: BillingPeriod.annual, hasAnnual: false, hasMonthly: false),
      BillingPeriod.annual,
    );
  });
}

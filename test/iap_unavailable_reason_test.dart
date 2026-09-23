import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/iap/iap_service.dart';

/// 購入画面の空状態で「再読み込み」を出すかどうかの判定（2026-09-23）。
///
/// 実ユーザー（iPhone）で `PurchaseNotAllowedError` が起きていた（Sentry MOFFY-1 の iOS 分）。
/// 端末が購入を許可していない状態なので、何度読み込み直しても変わらない。
/// 「押しても無駄なボタン」を出さないための判定を縛る。
void main() {
  test('購入が許可されていない（code 3）を見分ける', () {
    final e = PlatformException(
      code: '3',
      message: 'The device or user is not allowed to make the purchase.',
      details: {'readableErrorCode': 'PurchaseNotAllowedError'},
    );
    expect(iapUnavailableReasonOf(e), IapUnavailableReason.purchaseNotAllowed);
  });

  test('通信エラー（code 10）は「購入できない」ではない＝再読み込みを出す', () {
    expect(iapUnavailableReasonOf(PlatformException(code: '10')), isNull);
  });

  test('ストア側の問題（code 2）も別扱い', () {
    expect(iapUnavailableReasonOf(PlatformException(code: '2')), isNull);
  });

  test('数字でない code の PlatformException で落ちない（他プラグインの例外）', () {
    // PurchasesErrorHelper.getErrorCode は num.parse するので、ガードが無いと投げる。
    final e = PlatformException(code: 'sign_in_failed');
    expect(() => iapUnavailableReasonOf(e), returnsNormally);
    expect(iapUnavailableReasonOf(e), isNull);
  });

  test('RevenueCat 以外の例外は理由不明として扱う', () {
    expect(iapUnavailableReasonOf(Exception('boom')), isNull);
    expect(iapUnavailableReasonOf('文字列'), isNull);
  });

  test('IapOfferings は既定で理由を持たない（既存の呼び出しを壊さない）', () {
    const offerings = IapOfferings(plans: []);
    expect(offerings.isEmpty, isTrue);
    expect(offerings.unavailableReason, isNull);
  });
}

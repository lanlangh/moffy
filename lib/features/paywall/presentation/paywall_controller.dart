import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/iap/iap_models.dart';
import '../../../core/iap/iap_providers.dart';
import '../../../core/iap/iap_service.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/observability_providers.dart';

/// ペイウォールのアクション状態管理（購入/復元の進行と結果）。
///
/// 提示プランの取得は [offeringsProvider]（FutureProvider）が担い、本コントローラは
/// 「購入/復元という副作用アクション」の進行中フラグと直近結果のみを持つ
/// （AsyncNotifier の data に提示プランを混ぜず、責務を分離する）。
class PaywallController extends Notifier<PaywallActionState> {
  @override
  PaywallActionState build() => const PaywallActionState.idle();

  IapService get _service => ref.read(iapServiceProvider);

  /// 指定プランを購入する。進行中は二重押下を防ぐためボタンを無効化する想定。
  Future<IapResult> purchase(PlanOffer plan) async {
    state = const PaywallActionState.inProgress(PaywallAction.purchase);
    final result = await _service.purchase(plan);
    state = PaywallActionState.done(result);
    // 成功時はクライアント状態 Stream が更新を流す（即時UI反映）。
    if (result.outcome == IapPurchaseOutcome.success) {
      ref.invalidate(premiumStatusProvider);
      // ファネル: 購入完了（PRD §5-5）。最終確定はサーバー（RC Webhook）が正だが、
      // ここは即時の行動計測。金額は載せずプラン期間のカテゴリ値のみ（PII/生データ非送信）。
      ref.read(analyticsProvider).capture(
        AnalyticsEvents.purchaseCompleted,
        properties: {AnalyticsProps.planPeriod: plan.period.name},
      );
    }
    return result;
  }

  /// 購入を復元する。
  Future<IapResult> restore() async {
    state = const PaywallActionState.inProgress(PaywallAction.restore);
    final result = await _service.restore();
    state = PaywallActionState.done(result);
    if (result.outcome == IapPurchaseOutcome.success) {
      ref.invalidate(premiumStatusProvider);
    }
    return result;
  }

  /// 提示プランを再取得する（エラー/空状態のリトライ）。
  void retryOfferings() => ref.invalidate(offeringsProvider);

  /// ストアのサブスク管理URL（解約導線 / 取得できなければ null）。
  Future<Uri?> managementUrl() => _service.managementUrl();
}

final paywallControllerProvider =
    NotifierProvider<PaywallController, PaywallActionState>(
  PaywallController.new,
);

/// 進行中のアクション種別。
enum PaywallAction { purchase, restore }

/// ペイウォールのアクション状態（購入/復元の進行・直近結果）。
class PaywallActionState {
  const PaywallActionState._({this.runningAction, this.lastResult});

  const PaywallActionState.idle() : this._();

  const PaywallActionState.inProgress(PaywallAction action)
      : this._(runningAction: action);

  const PaywallActionState.done(IapResult result)
      : this._(lastResult: result);

  /// 進行中アクション（null=待機）。non-null の間はボタンを無効化する。
  final PaywallAction? runningAction;

  /// 直近の購入/復元結果（SnackBar 表示・成功時の画面クローズ判定に使う）。
  final IapResult? lastResult;

  bool get isBusy => runningAction != null;
}

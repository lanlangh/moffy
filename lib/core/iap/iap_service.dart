/// IAP（アプリ内課金）サービス（ARCHITECTURE §1-2 data 層に相当）。
///
/// 役割: RevenueCat SDK（purchases_flutter）の詳細を隠蔽し、上位（プロバイダ/UI）には
/// 抽象 [IapService] のみ公開する。SDK 型 → ドメイン型（[PlanOffer]/[PremiumStatus]）の
/// 変換（マッパ）もここに閉じ込める。
///
/// 信頼境界（PRICING §4-2）:
///   * 本サービスが返す [PremiumStatus] は**クライアントから見た補助情報**。機能解放の
///     最終判定はサーバー（entitlements / RevenueCat Webhook → Supabase）が正。
///   * 公開SDKキーは Env（dart-define）から受ける。未設定なら no-op モックにフォールバック。
///
/// 実装の罠（iap-setup）:
///   * 「価格が表示される」≠「課金が動く」。実購入はサンドボックス実機検証が必要
///     （ここでは検証不可 → docs/IAP_SETUP.md に手順化）。
///   * トライアル文言は資格（eligibility）が ELIGIBLE のときだけ表示する。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart';

import '../config/env.dart';
import '../constants/pricing.dart';
import '../observability/log.dart';
import 'iap_models.dart';

/// 購入/復元の結果（UIが分岐に使う）。
enum IapPurchaseOutcome {
  /// 購入/復元で entitlement `premium` が有効になった。
  success,

  /// ユーザーが購入ダイアログをキャンセルした（エラー表示しない）。
  cancelled,

  /// 復元したが有効なサブスクが無かった（履歴なし）。
  nothingToRestore,

  /// 課金保留（承認待ち / Pending）。
  pending,

  /// その他の失敗（ネットワーク/商品なし/レシート異常など）。
  failed,
}

/// 購入/復元の結果 + 失効後の最新状態 + 診断。
class IapResult {
  const IapResult({
    required this.outcome,
    required this.status,
    this.message,
    this.diagnosticCode,
  });

  final IapPurchaseOutcome outcome;
  final PremiumStatus status;

  /// ユーザー向け文言（失敗時）。
  final String? message;

  /// 診断コード（NO-KEY / INIT-FAIL / FETCH-FAIL / NO-OFFERING 等）。スクショ1枚で原因特定。
  final String? diagnosticCode;
}

/// 取得した提示プラン（offering `default` の月額/年額）。
class IapOfferings {
  const IapOfferings({required this.plans});

  /// 月額/年額の [PlanOffer]。空なら「商品なし」（空状態）。
  final List<PlanOffer> plans;

  bool get isEmpty => plans.isEmpty;

  PlanOffer? get monthly =>
      plans.where((p) => p.period == BillingPeriod.monthly).firstOrNull;
  PlanOffer? get annual =>
      plans.where((p) => p.period == BillingPeriod.annual).firstOrNull;
}

/// IAP サービスの抽象。テスト/未設定時は [NoopIapService] を注入する。
abstract interface class IapService {
  /// SDK を初期化する（未設定/失敗でも例外を投げず false を返す）。
  Future<bool> configure({String? appUserId});

  /// offering `default` の提示プランを取得する。
  /// 取得失敗時は診断コード付きで空の [IapOfferings] を返す（落とさない）。
  Future<IapOfferings> fetchOfferings();

  /// 現在のプレミアム状態（entitlement `premium`）を取得する。
  Future<PremiumStatus> fetchPremiumStatus();

  /// プレミアム状態の変化を購読する（CustomerInfo listener）。即時UI反映に使う。
  Stream<PremiumStatus> premiumStatusStream();

  /// 指定プランを購入する。
  Future<IapResult> purchase(PlanOffer plan);

  /// 購入を復元する（機種変・再インストール後）。
  Future<IapResult> restore();

  /// ストアの定期購読管理URL（解約はストアからのみ / PRICING §8）。
  /// 取得できない場合は null（UIはプラットフォーム別の固定リンクにフォールバック）。
  Future<Uri?> managementUrl();
}

/// no-op モック実装（RevenueCat 未設定 / オフライン / テスト）。
///
/// 常にプレミアム=false・商品なしを返し、購入はサンドボックス未設定として失敗させる。
/// UI の5状態（特に「未設定/空/オフライン」）をクラッシュさせず成立させる。
class NoopIapService implements IapService {
  const NoopIapService({this.diagnosticCode = 'NO-KEY'});

  /// なぜ no-op なのかの診断（NO-KEY=キー未設定 / INIT-FAIL=初期化失敗）。
  final String diagnosticCode;

  @override
  Future<bool> configure({String? appUserId}) async => false;

  @override
  Future<IapOfferings> fetchOfferings() async =>
      const IapOfferings(plans: []);

  @override
  Future<PremiumStatus> fetchPremiumStatus() async => PremiumStatus.mockFree;

  @override
  Stream<PremiumStatus> premiumStatusStream() =>
      Stream<PremiumStatus>.value(PremiumStatus.mockFree);

  @override
  Future<IapResult> purchase(PlanOffer plan) async => IapResult(
        outcome: IapPurchaseOutcome.failed,
        status: PremiumStatus.mockFree,
        message: '現在ご購入いただけません。アプリの設定が未完了です。',
        diagnosticCode: diagnosticCode,
      );

  @override
  Future<IapResult> restore() async => IapResult(
        outcome: IapPurchaseOutcome.nothingToRestore,
        status: PremiumStatus.mockFree,
        message: '復元できる購入が見つかりませんでした。',
        diagnosticCode: diagnosticCode,
      );

  @override
  Future<Uri?> managementUrl() async => null;
}

/// RevenueCat（purchases_flutter）実装。
class RevenueCatIapService implements IapService {
  RevenueCatIapService({required this.publicSdkKey});

  /// プラットフォーム別の公開SDKキー（appl_xxx / goog_xxx）。
  final String publicSdkKey;

  bool _configured = false;

  @override
  Future<bool> configure({String? appUserId}) async {
    if (_configured) return true;
    try {
      // 本番ログ抑止（組織ルール）。デバッグ時のみ verbose。
      await Purchases.setLogLevel(
        Env.isDev ? LogLevel.debug : LogLevel.error,
      );
      final config = PurchasesConfiguration(publicSdkKey)
        // App User ID を Supabase user_id に揃える（PRICING §4-2 / 機種変復元）。
        // null なら RevenueCat の匿名IDを使い、後で logIn で紐づける。
        ..appUserID = appUserId;
      await Purchases.configure(config);
      _configured = true;
      Log.d('RevenueCat configured');
      return true;
    } catch (e, st) {
      Log.e('RevenueCat configure failed', error: e, stack: st);
      return false;
    }
  }

  @override
  Future<IapOfferings> fetchOfferings() async {
    try {
      final offerings = await Purchases.getOfferings();
      // offering `default`（current が default 設定済みなら current でもよい）。
      final offering = offerings.all[RevenueCatIds.defaultOffering] ??
          offerings.current;
      if (offering == null) {
        Log.d('RevenueCat: offering "default" 未取得（NO-OFFERING）');
        return const IapOfferings(plans: []);
      }
      final plans = <PlanOffer>[];
      for (final pkg in offering.availablePackages) {
        final mapped = _mapPackage(pkg);
        if (mapped != null) plans.add(mapped);
      }
      return IapOfferings(plans: plans);
    } catch (e, st) {
      Log.e('RevenueCat getOfferings failed', error: e, stack: st);
      return const IapOfferings(plans: []);
    }
  }

  @override
  Future<PremiumStatus> fetchPremiumStatus() async {
    try {
      final info = await Purchases.getCustomerInfo();
      return mapCustomerInfo(info);
    } catch (e, st) {
      Log.e('RevenueCat getCustomerInfo failed', error: e, stack: st);
      return PremiumStatus.free;
    }
  }

  @override
  Stream<PremiumStatus> premiumStatusStream() {
    final controller = StreamController<PremiumStatus>();
    void listener(CustomerInfo info) {
      controller.add(mapCustomerInfo(info));
    }

    Purchases.addCustomerInfoUpdateListener(listener);
    controller.onCancel = () {
      Purchases.removeCustomerInfoUpdateListener(listener);
    };
    // 初期値も流す（フォアグラウンド復帰時の同期 / iap-setup）。
    unawaited(fetchPremiumStatus().then(controller.add).catchError((_) {}));
    return controller.stream;
  }

  @override
  Future<IapResult> purchase(PlanOffer plan) async {
    try {
      final offerings = await Purchases.getOfferings();
      final offering = offerings.all[RevenueCatIds.defaultOffering] ??
          offerings.current;
      final pkg = offering?.availablePackages
          .where((p) => p.identifier == plan.packageId)
          .firstOrNull;
      if (pkg == null) {
        return IapResult(
          outcome: IapPurchaseOutcome.failed,
          status: await fetchPremiumStatus(),
          message: '商品が見つかりませんでした。時間をおいて再度お試しください。',
          diagnosticCode: 'NO-OFFERING',
        );
      }
      final result = await Purchases.purchase(PurchaseParams.package(pkg));
      final status = mapCustomerInfo(result.customerInfo);
      return IapResult(
        outcome: status.isPremium
            ? IapPurchaseOutcome.success
            : IapPurchaseOutcome.pending,
        status: status,
      );
    } on PlatformException catch (e) {
      return _mapPurchaseError(e, await _safeStatus());
    } catch (e, st) {
      Log.e('RevenueCat purchase failed', error: e, stack: st);
      return IapResult(
        outcome: IapPurchaseOutcome.failed,
        status: await _safeStatus(),
        message: '購入処理でエラーが発生しました。もう一度お試しください。',
        diagnosticCode: 'PURCHASE-FAIL',
      );
    }
  }

  @override
  Future<IapResult> restore() async {
    try {
      final info = await Purchases.restorePurchases();
      final status = mapCustomerInfo(info);
      return IapResult(
        outcome: status.isPremium
            ? IapPurchaseOutcome.success
            : IapPurchaseOutcome.nothingToRestore,
        status: status,
        message: status.isPremium ? null : '復元できる購入が見つかりませんでした。',
      );
    } catch (e, st) {
      Log.e('RevenueCat restore failed', error: e, stack: st);
      return IapResult(
        outcome: IapPurchaseOutcome.failed,
        status: await _safeStatus(),
        message: '復元処理でエラーが発生しました。通信環境を確認してお試しください。',
        diagnosticCode: 'RESTORE-FAIL',
      );
    }
  }

  @override
  Future<Uri?> managementUrl() async {
    try {
      final info = await Purchases.getCustomerInfo();
      final url = info.managementURL;
      if (url == null || url.isEmpty) return null;
      return Uri.tryParse(url);
    } catch (_) {
      return null;
    }
  }

  Future<PremiumStatus> _safeStatus() async {
    try {
      return await fetchPremiumStatus();
    } catch (_) {
      return PremiumStatus.free;
    }
  }

  // --- マッパ（SDK 型 → ドメイン型）。テスト容易化のため static/可視に切り出す ---

  /// `CustomerInfo` → [PremiumStatus]。entitlement `premium` の有効性で判定する。
  ///
  /// 信頼境界: これはクライアント表示用。機能解放はサーバー検証が正（PRICING §4-2）。
  static PremiumStatus mapCustomerInfo(CustomerInfo info) {
    final ent = info.entitlements.active[RevenueCatIds.entitlementPremium];
    if (ent == null) {
      return const PremiumStatus(
        isPremium: false,
        source: PremiumSource.revenueCat,
      );
    }
    return PremiumStatus(
      isPremium: ent.isActive,
      source: PremiumSource.revenueCat,
      activeProductId: ent.productIdentifier,
      willRenew: ent.willRenew,
      expirationDate: ent.expirationDate == null
          ? null
          : DateTime.tryParse(ent.expirationDate!),
    );
  }

  /// `Package` → [PlanOffer]。価格はストア実額（priceString）、トライアル資格を判定。
  PlanOffer? _mapPackage(Package pkg) {
    final product = pkg.storeProduct;
    final period = _periodFor(pkg);
    if (period == null) return null; // 月額/年額以外は無視（MVPは2種のみ）。

    // トライアル資格: introductoryPrice が存在し、価格0（無料）なら導入オファー扱い。
    // RevenueCat は本来 checkTrialOrIntroductoryPriceEligibility で厳密判定するが、
    // SDK 経由の introductoryPrice 有無で一次判定し、表示は eligible のときのみ行う。
    final intro = product.introductoryPrice;
    final eligible = intro != null && intro.price == 0;
    String? trialLabel;
    if (eligible && intro.periodNumberOfUnits > 0) {
      trialLabel = '${intro.periodNumberOfUnits}${_unitLabel(intro.periodUnit)}';
    }
    return PlanOffer(
      productId: product.identifier,
      packageId: pkg.identifier,
      period: period,
      priceString: product.priceString,
      priceAmount: product.price,
      currencyCode: product.currencyCode,
      trialEligibility:
          eligible ? TrialEligibility.eligible : TrialEligibility.ineligible,
      trialPeriodLabel: trialLabel,
    );
  }

  BillingPeriod? _periodFor(Package pkg) {
    switch (pkg.packageType) {
      case PackageType.monthly:
        return BillingPeriod.monthly;
      case PackageType.annual:
        return BillingPeriod.annual;
      default:
        // 識別子フォールバック（custom パッケージのとき）。
        if (pkg.identifier == RevenueCatIds.packageMonthly) {
          return BillingPeriod.monthly;
        }
        if (pkg.identifier == RevenueCatIds.packageYearly) {
          return BillingPeriod.annual;
        }
        return null;
    }
  }

  String _unitLabel(PeriodUnit unit) {
    switch (unit) {
      case PeriodUnit.day:
        return '日間';
      case PeriodUnit.week:
        return '週間';
      case PeriodUnit.month:
        return 'ヶ月';
      case PeriodUnit.year:
        return '年間';
      case PeriodUnit.unknown:
        return '';
    }
  }

  IapResult _mapPurchaseError(PlatformException e, PremiumStatus status) {
    final code = PurchasesErrorHelper.getErrorCode(e);
    switch (code) {
      case PurchasesErrorCode.purchaseCancelledError:
        return IapResult(
          outcome: IapPurchaseOutcome.cancelled,
          status: status,
        );
      case PurchasesErrorCode.paymentPendingError:
        return IapResult(
          outcome: IapPurchaseOutcome.pending,
          status: status,
          message: 'お支払いの承認待ちです。完了すると自動で反映されます。',
        );
      case PurchasesErrorCode.productAlreadyPurchasedError:
        return IapResult(
          outcome: status.isPremium
              ? IapPurchaseOutcome.success
              : IapPurchaseOutcome.nothingToRestore,
          status: status,
          message: status.isPremium ? null : 'すでに購入済みです。「購入を復元」をお試しください。',
        );
      case PurchasesErrorCode.networkError:
        return IapResult(
          outcome: IapPurchaseOutcome.failed,
          status: status,
          message: 'ネットワークに接続できませんでした。通信環境を確認してお試しください。',
          diagnosticCode: 'NETWORK',
        );
      case PurchasesErrorCode.purchaseNotAllowedError:
        return IapResult(
          outcome: IapPurchaseOutcome.failed,
          status: status,
          message: 'この端末では購入が制限されています。端末の設定をご確認ください。',
          diagnosticCode: 'NOT-ALLOWED',
        );
      default:
        return IapResult(
          outcome: IapPurchaseOutcome.failed,
          status: status,
          message: '購入処理でエラーが発生しました。もう一度お試しください。',
          diagnosticCode: 'PURCHASE-FAIL',
        );
    }
  }
}

/// 現在プラットフォームが Apple（iOS/macOS）か。Env のキー選択に使う。
bool get isApplePlatform => Platform.isIOS || Platform.isMacOS;

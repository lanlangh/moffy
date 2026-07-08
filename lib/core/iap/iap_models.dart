/// IAP（アプリ内課金）のドメインモデルと純粋ロジック。
///
/// ここは Flutter / purchases_flutter（SDK）に**依存しない純粋ロジック**にする
/// （ARCHITECTURE §1-2: domain は Flutter 非依存が理想 / 単体テスト容易）。
/// SDK 型（StoreProduct / CustomerInfo / Package）からの変換は
/// `iap_service.dart` 側のマッパが担い、本ファイルはその結果のみを扱う。
///
/// 信頼境界（PRICING §4-2 / ARCHITECTURE §0-2）:
///   * プレミアム特典の**最終的な付与可否はサーバー（entitlements）が正**。
///     本ファイルの [PremiumStatus] は「クライアントが RevenueCat から見た状態」で、
///     即時UI反映・購入導線のための**補助情報**。機能解放の判定には使わない。
library;

import '../constants/pricing.dart';

/// プレミアム（entitlement `premium`）の有効性を表すクライアント側スナップショット。
///
/// 真のSSOTはサーバー。これは RevenueCat `CustomerInfo` から導出した表示用の状態。
class PremiumStatus {
  const PremiumStatus({
    required this.isPremium,
    required this.source,
    this.activeProductId,
    this.willRenew,
    this.expirationDate,
  });

  /// クライアントから見て entitlement `premium` が有効か。
  final bool isPremium;

  /// この状態の由来（モック/SDK/不明）。診断・ログ用。
  final PremiumSource source;

  /// 現在有効なサブスクの商品ID（`RevenueCatIds.productMonthly` 等）。null=なし。
  final String? activeProductId;

  /// 次回更新するか（解約済みなら false）。不明は null。
  final bool? willRenew;

  /// 失効予定日時（トライアル終了/期限）。不明は null。
  final DateTime? expirationDate;

  /// プレミアム未加入（無料）の既定状態。
  static const PremiumStatus free =
      PremiumStatus(isPremium: false, source: PremiumSource.none);

  /// no-op モック（キー未設定/オフライン）の既定状態。常に無料。
  static const PremiumStatus mockFree =
      PremiumStatus(isPremium: false, source: PremiumSource.mock);

  PremiumStatus copyWith({
    bool? isPremium,
    PremiumSource? source,
    String? activeProductId,
    bool? willRenew,
    DateTime? expirationDate,
  }) {
    return PremiumStatus(
      isPremium: isPremium ?? this.isPremium,
      source: source ?? this.source,
      activeProductId: activeProductId ?? this.activeProductId,
      willRenew: willRenew ?? this.willRenew,
      expirationDate: expirationDate ?? this.expirationDate,
    );
  }
}

/// プレミアム状態の由来（診断・ログ用）。
enum PremiumSource {
  /// まだ取得していない/該当なし。
  none,

  /// no-op モック（RevenueCat 未設定・オフラインフォールバック）。
  mock,

  /// RevenueCat SDK の `CustomerInfo` 由来。
  revenueCat,
}

/// 無料トライアル資格（introductory offer eligibility）。
///
/// 罠（iap-setup 5大致命傷の3番目）:
///   「○日間無料」を**無条件表示するとリジェクト要因**。対象外ユーザー（消費済み/地域外）
///   の支払いシートと矛盾するため。資格が [eligible] のときだけトライアル文言を出す。
enum TrialEligibility {
  /// トライアル資格あり（introductory offer が利用可能）。文言表示してよい。
  eligible,

  /// 資格なし（消費済み/地域外/対象外）。トライアル文言を出さない。
  ineligible,

  /// 未判定（SDK 取得前など）。安全側で「出さない」扱いにする。
  unknown,
}

/// 課金プラン1件分の表示用エンティティ（ストア値ミラー）。
///
/// 価格は必ず**ストアのローカライズ実額**（`StoreProduct.priceString`）を [priceString]
/// に入れる（PRICING §4-1 / ハードコード禁止）。`pricing.dart` の円価格は表示に使わない。
class PlanOffer {
  const PlanOffer({
    required this.productId,
    required this.packageId,
    required this.period,
    required this.priceString,
    required this.priceAmount,
    required this.currencyCode,
    required this.trialEligibility,
    this.trialPeriodLabel,
  });

  /// 商品ID（`RevenueCatIds.productMonthly` / `productYearly`）。
  final String productId;

  /// パッケージ識別子（`$rc_monthly` / `$rc_annual`）。
  final String packageId;

  /// 課金周期。
  final BillingPeriod period;

  /// ストアのローカライズ実額（例 "¥480" / "$3.99"）。**主役表示**。
  final String priceString;

  /// 数値としての価格（年額の月割り計算・割引算出用）。0 ならストア未取得。
  final double priceAmount;

  /// 通貨コード（"JPY" 等）。
  final String currencyCode;

  /// このパッケージのトライアル資格（資格ありのときだけUIで訴求）。
  final TrialEligibility trialEligibility;

  /// トライアル期間のラベル（例 "7日間"）。資格ありかつSDKから取れた場合のみ。
  final String? trialPeriodLabel;

  /// トライアル文言を表示してよいか（資格 eligible のときだけ true）。
  bool get showTrialBadge => trialEligibility == TrialEligibility.eligible;
}

/// 課金周期。RevenueCat の標準パッケージに対応。
enum BillingPeriod { monthly, annual }

/// 年額の月割り割安訴求テキストを組み立てる純粋関数（表示専用・テスト対象）。
///
/// 仕様（PRICING §1-1）:
///   * 実額（年額）を主役にし、月割りは**従属表示**（3.1.2c）。本関数は従属側の
///     「月あたり〜・約N%お得」を作る。実額そのものの強調は呼び出し側UIが担う。
///   * 月割り = 年額 ÷ 12（四捨五入）。割引率 = (月額×12 − 年額) / (月額×12)。
///   * いずれかの価格が 0（ストア未取得）なら null を返し、UIは訴求バッジを出さない
///     （誤った割引%を出さない＝景表法/3.1.2 リスク回避）。
///
/// 注意: ここでは通貨記号を持たない数値計算に徹し、表示記号は priceString 側に委ねる。
class AnnualSavings {
  const AnnualSavings({
    required this.perMonthAmount,
    required this.discountPercent,
  });

  /// 年額の月あたり換算額（四捨五入後の数値）。
  final double perMonthAmount;

  /// 割引率（整数パーセント。例 17）。
  final int discountPercent;

  /// 月額・年額のストア実額から割安情報を計算する。
  /// 価格が取得できていない（0以下）場合は null（UIは訴求しない）。
  static AnnualSavings? compute({
    required double monthlyAmount,
    required double annualAmount,
  }) {
    if (monthlyAmount <= 0 || annualAmount <= 0) return null;
    final baseline = monthlyAmount * 12;
    if (annualAmount >= baseline) {
      // 年額が割安でない（ストア設定ミス等）→ 訴求しない（誤表示防止）。
      return null;
    }
    final perMonth = (annualAmount / 12);
    final discount = ((baseline - annualAmount) / baseline) * 100;
    return AnnualSavings(
      perMonthAmount: _round(perMonth),
      discountPercent: discount.round(),
    );
  }

  static double _round(double v) => (v * 100).roundToDouble() / 100;
}

/// プレミアム特典（ペイウォールで列挙する項目）。
///
/// 一致原則（PRICING §2 / pricing.dart）: **実装済みのものだけ**列挙する。
/// 詳細分析（v1.1送り = `PremiumEntitlements.detailedAnalytics == false`）は宣伝しない
/// （景表法・App Store 3.1.2 の誇大表示リスク回避）。
class PremiumBenefits {
  PremiumBenefits._();

  /// 表示する特典リスト（実装フラグが true のものだけを含む）。
  /// 数値（保管枠 20→200）は `StorageLimits` を参照しハードコードしない（SSOT）。
  static List<PremiumBenefit> get active {
    final benefits = <PremiumBenefit>[
      // 保管枠の増加（freeStorageSlots → premiumStorageSlots）。
      const PremiumBenefit(
        kind: PremiumBenefitKind.storage,
        title: '保管枠が大幅アップ',
        description:
            '卵の保管枠が ${StorageLimits.freeStorageSlots} → ${StorageLimits.premiumStorageSlots} に。'
            'たっぷり集められます。',
      ),
    ];

    // 限定Mofi（実装フラグが true のときだけ）。
    if (PremiumEntitlements.premiumUnlocksExclusiveMofi) {
      benefits.add(
        const PremiumBenefit(
          kind: PremiumBenefitKind.exclusiveMofi,
          title: '限定Mofiに出会える',
          description: 'プレミアムでしか出会えない特別な個体が登場します。',
        ),
      );
    }

    // プレミアム卵（実装フラグが true のときだけ）。
    if (PremiumEntitlements.premiumUnlocksPremiumEgg) {
      benefits.add(
        const PremiumBenefit(
          kind: PremiumBenefitKind.premiumEgg,
          title: 'プレミアム卵を解放',
          description: '高レアリティの卵への導線が開きます。',
        ),
      );
    }

    // 広告削除: AdMob バナー広告を実装済（core/ads・無料プランのみ表示）。無料に広告が
    //   出る（freeShowsAds=true）間だけ、プレミアム特典として「広告削除」を列挙する
    //   （実装と一致・PRICING §2 / STORE_DATA_SAFETY §4-3）。
    if (PremiumEntitlements.freeShowsAds) {
      benefits.add(
        const PremiumBenefit(
          kind: PremiumBenefitKind.adFree,
          title: '広告を非表示に',
          description: '無料プランで表示されるバナー広告が消えて、すっきり遊べます。',
        ),
      );
    }

    // 詳細分析は detailedAnalytics=false（v1.1送り）のため**列挙しない**（誇大表示回避）。
    return benefits;
  }
}

/// 特典1件。
class PremiumBenefit {
  const PremiumBenefit({
    required this.kind,
    required this.title,
    required this.description,
  });

  final PremiumBenefitKind kind;
  final String title;
  final String description;
}

/// 特典の種別（UIのアイコン選択に使う。絵文字は使わない＝Material アイコンで表現）。
enum PremiumBenefitKind { storage, exclusiveMofi, premiumEgg, adFree }

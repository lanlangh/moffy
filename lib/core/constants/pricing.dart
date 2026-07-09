/// 価格・プラン上限のSSOT（=Single Source of Truth / 信頼できる唯一の情報源）。
///
/// 重要（economy.dart と同じ信頼境界の原則）:
///   * 「宣伝する値 ＝ 実装値（一致原則）」を守るための単一定義。
///     ストア掲載文・課金画面UI・保管枠ガード・サーバー検証は、すべて本ファイルの
///     定数を参照すること。UI / ストア説明 / サーバーにマジックナンバーを直書きしない。
///   * 価格（¥）は「ストアに登録する実額」のミラー（=参照値）。実際の請求は
///     App Store / Google Play のローカライズ価格が正であり、購入処理は RevenueCat の
///     `StoreProduct.priceString` を表示に使う。本ファイルの円価格は、特商法表記・
///     プラン比較UI・ユニットエコノミクス試算で参照する「設計上の基準値」。
///     価格を変えるときは App Store Connect / Play Console の商品価格も必ず合わせる。
///   * プレミアム判定の真のSSOTは RevenueCat entitlement `premium`（サーバー検証）。
///     本ファイルの上限値は「無料↔プレミアムで何がどう変わるか」の境界定義であり、
///     付与可否そのものの判定はサーバー（entitlements）が行う。
///
/// 参照: docs/PRICING.md（価格表・プラン境界・ユニットエコノミクス・前提と根拠）
library;

/// 課金プラン種別。
enum PricingPlan {
  /// 無料プラン（広告あり・保管枠制限・限定Mofi/プレミアム卵なし）。
  free,

  /// プレミアム（月額サブスク）。
  premiumMonthly,

  /// プレミアム（年額サブスク。実質割引）。
  premiumYearly,
}

/// RevenueCat の商品/エンタイトルメント/オファリングの識別子。
///
/// クライアント・サーバー（entitlements RPC / Webhook）・ストア商品登録で
/// 同一文字列を使うため、ここを唯一の定義とする（タイポによる不整合防止）。
class RevenueCatIds {
  RevenueCatIds._();

  /// エンタイトルメント識別子。これが有効なら「プレミアム」。
  /// サーバー検証（entitlements RPC / Webhook）もこのキーで判定する。
  static const String entitlementPremium = 'premium';

  /// オファリング識別子（既定の提示パッケージ群）。
  static const String defaultOffering = 'default';

  /// 商品ID（月額）。App Store Connect / Play Console の Product ID と一致必須。
  static const String productMonthly = 'moffy_premium_monthly';

  /// 商品ID（年額）。同上。
  static const String productYearly = 'moffy_premium_yearly';

  /// パッケージ識別子（RevenueCat Offering 内）。月額は標準 `$rc_monthly`。
  static const String packageMonthly = r'$rc_monthly';

  /// パッケージ識別子（年額）。標準 `$rc_annual`。
  static const String packageYearly = r'$rc_annual';
}

/// 価格の基準値（円・税込前提の表示額）。
///
/// 実請求はストアのローカライズ価格が正。ここは特商法表記・比較UI・採算試算の基準。
class PricingAmounts {
  PricingAmounts._();

  /// 月額プレミアムの月額（円）。CEO裁定の想定額。
  static const int monthlyYen = 480;

  /// 年額プレミアムの年額（円・実請求額）。
  /// 月額×12=5760円 に対し 約17%OFF（割引レンジ 15〜20% の中央寄り）。
  /// 端数を心理価格（末尾80）に丸めて 4800円 とする（月あたり 400円 換算）。
  static const int yearlyYen = 4800;

  /// 無料トライアル日数（全商品・全地域に付与）。
  static const int freeTrialDays = 7;

  /// 年額の「12ヶ月分相当」基準額（割引率の根拠表示・採算試算用）。
  static const int yearlyBaselineYen = monthlyYen * 12; // 5760

  /// 年額の割引率（0.0〜1.0）。表示は「実額最優先・割引は従属」の原則で扱う。
  /// (5760 - 4800) / 5760 = 0.166...（約17%OFF）。
  static double get yearlyDiscountRate =>
      (yearlyBaselineYen - yearlyYen) / yearlyBaselineYen;

  /// 年額の「月あたり換算」（円・従属表示専用）。
  /// 注意（3.1.2c）: この値は実請求額(yearlyYen)より目立たせてはならない。
  static int get yearlyPerMonthYen => (yearlyYen / 12).round(); // 400
}

/// 保管枠の上限（無料 / プレミアム）。
///
/// PRD S6: 育成枠は3枠固定（プラン非依存）。差別化するのは「保管枠（孵化前の卵の在庫）」。
/// 「宣伝する値＝実装値」の一致原則のため、ストア説明・課金画面・保管UIガードは
/// すべてこの定数を参照する。
class StorageLimits {
  StorageLimits._();

  /// 育成枠（アクティブに育てるスロット）。PRD S6 で3枠固定・プラン非依存。
  static const int incubationSlots = 3;

  /// 無料プランの保管枠上限（孵化前の卵を貯めておける数）。
  /// 体験は十分できるが「集め始めると足りなくなる」線（pricing-design の定石）。
  static const int freeStorageSlots = 20;

  /// プレミアムの保管枠上限。実質「ほぼ無制限」だが、DB肥大・不正対策のため上限値を持つ。
  /// 宣伝は「大幅増加 / たっぷり貯められる」と表現し、具体数を謳う場合はこの値に一致させる。
  static const int premiumStorageSlots = 200;

  /// 指定プランの保管枠上限を返す（UI/サーバーガードの単一参照点）。
  static int storageSlotsFor(PricingPlan plan) {
    switch (plan) {
      case PricingPlan.free:
        return freeStorageSlots;
      case PricingPlan.premiumMonthly:
      case PricingPlan.premiumYearly:
        return premiumStorageSlots;
    }
  }
}

/// プレミアム特典フラグ（MVPの境界）。
///
/// 一致原則（PRICING §2 / iap_models.dart PremiumBenefits）: ペイウォールは **v1.0 で
/// 実際に提供できている特典だけ** を列挙する（景表法 優良誤認・App Store 3.1.2 /
/// Google Play「未機能の有料機能」= リジェクト＋返金クレーム の回避）。フラグはこの
/// 「実装済みか」を表し、UI（PremiumBenefits.active）はフラグ true のものだけ出す。
///
/// v1.0 の実提供特典 = **広告削除**（実装済み）＋ 保管枠アップ（プラン差・下記注記）。
///   * 詳細分析（曜日/時間帯/SNS別/月次/予測）: v1.1 送り（detailedAnalytics=false）。
///   * プレミアム卵 / 限定Mofi: **v1.0 は未実装のため off**。理由:
///       - プレミアム卵の付与機構が無い（app_config.egg_drop_distribution の "premium"
///         配分はどの RPC からも参照されていない＝プレミアムでも高レア卵は配られない）。
///       - 限定Mofi は 0 体（2026-07-07 決定「ハード限定0体・図鑑40全て無料到達可」）。
///     → 到達"速度差"(約7.6倍速) はプレミアム卵付与（migration 0010系）が前提。付与実装が
///        入った時点で premiumUnlocksPremiumEgg を true に戻し、本物の特典として訴求する。
class PremiumEntitlements {
  PremiumEntitlements._();

  /// 無料プランに広告を表示するか（=プレミアムは広告削除）。
  /// AdMob バナー広告を実装済み（`core/ads`・無料のみ画面下部に表示／プレミアム非表示＝
  /// 「広告削除」の実体／Web・デスクトップは自動 no-op）。現在は Google 公式テスト広告ID
  /// （`core/ads/ad_config.dart`）で、本番収益化時に AdMob の実ユニット/アプリIDへ差し替える。
  static const bool freeShowsAds = true;
  static const bool premiumShowsAds = false;

  /// プレミアム限定Mofi（=プレミアムでのみ出会える個体）の解放。
  /// **v1.0=false**: 限定個体は 0 体（2026-07-07 決定）。実装するまで宣伝しない（誇大表示回避）。
  static const bool premiumUnlocksExclusiveMofi = false;

  /// プレミアム卵（高レアリティ配分の卵）への導線解放。
  /// **v1.0=false**: プレミアム卵の付与機構が未実装（egg_drop_distribution["premium"] 未参照）。
  /// 付与を実装（0010系）したら true に戻す。それまでは宣伝しない（未機能の有料機能=審査/返金リスク）。
  static const bool premiumUnlocksPremiumEgg = false;

  /// 詳細分析（曜日/時間帯/SNS別/月次/予測）。MVPは無効（v1.1送り）。
  /// 無料の「今日/今週」分析は本フラグの対象外で、全プランに提供される。
  static const bool detailedAnalytics = false;

  /// 指定プランで広告を表示するか。
  static bool showsAdsFor(PricingPlan plan) =>
      plan == PricingPlan.free ? freeShowsAds : premiumShowsAds;

  /// 指定プランがプレミアム特典を持つか（限定Mofi/プレミアム卵/広告削除）。
  static bool isPremium(PricingPlan plan) => plan != PricingPlan.free;
}

/// ジェム（=プレミアム通貨）の無料入手レート・付与量。
///
/// PRD S7: 無料入手は「ウィークリークエスト / 図鑑マイルストーン / ストリーク
/// マイルストーン」に限定（広告報酬・ログインボーナスでのジェム配布はしない）。
/// インフレ防止のため希少性を保つ。真のSSOTはサーバー（app_config/報酬テーブル）で、
/// ここは表示・整合確認用の参照値（economy.dart と同じ位置づけ）。
class GemEconomy {
  GemEconomy._();

  /// ウィークリークエスト達成での週あたり無料ジェム上限（PRD S7: 30〜50の中央値）。
  static const int weeklyQuestGemCap = 40;

  /// 図鑑マイルストーン1段ごとの付与ジェム（5/10/15/20/25/30体達成ごと）。
  static const int dexMilestoneGem = 30;

  /// 図鑑マイルストーンの段数（PRD: 30体まで5体刻み = 6段）。
  static const int dexMilestoneCount = 6;

  /// ストリークマイルストーン（7日/30日連続）の付与ジェム。
  static const int streak7DayGem = 20;
  static const int streak30DayGem = 50;

  /// プレミアム卵1個に必要なジェム（=ジェムの主用途。インフレ防止の基準価格）。
  /// 無料入手レート（週40＋マイルストーン）から「数週に1個」のペースになる線。
  static const int premiumEggGemCost = 120;
}

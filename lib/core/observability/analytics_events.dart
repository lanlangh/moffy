/// ファネルイベント名の単一情報源（SSOT / PRD §2 コアループ・§5 受け入れ条件）。
///
/// なぜ定数集中か（組織ルール / SSOT）:
///   * イベント名はダッシュボード（PostHog）のクエリ・ファネル定義と1:1で紐づく。
///     マジック文字列を散らすと、タイポ1つでファネルが欠損し「初日から計測」を満たせない。
///   * 命名規約: snake_case の過去形動詞（PostHog 慣例 / `app_opened` 等）。
///     プロパティキーも同ファイルに集約し、表記ゆれを防ぐ。
///
/// 主要ファネル（PRD §5-5 / §2）:
///   起動 → 利用時間権限 → 日次確定（pt獲得）→ 孵化 → 図鑑登録 → 課金
///   （app_opened → usage_permission_granted → day_finalized → egg_hatched
///    → dex_registered → purchase_completed）
///
/// PII 原則（OBSERVABILITY_SETUP.md / 厳守）:
///   * 個人情報・利用生データ（usage_daily の分数等）はプロパティに載せない。
///   * 載せてよいのは「種別・レアリティ・プラン期間」等のカテゴリ値と匿名IDのみ。
library;

/// ファネルイベント名（PostHog `capture(event)` に渡す値）。
abstract final class AnalyticsEvents {
  // --- 起動・導入（ファネル入口） ---

  /// アプリ起動（セッション開始の代表点）。初日計測の基点。
  static const appOpened = 'app_opened';

  /// オンボーディング完了（コアループへの到達）。
  static const onboardingCompleted = 'onboarding_completed';

  /// 「使用状況へのアクセス」権限が許可された（利用時間取得の前提 / S2）。
  static const usagePermissionGranted = 'usage_permission_granted';

  // --- コアループ（pt → 孵化 → 図鑑 / PRD §2） ---

  /// 日次の削減ポイントが確定した（pt獲得の代表点 / S1・S4）。
  /// 注: 確定 pt の「数値」は載せない（生データ非送信）。is_provisional 等の区分のみ可。
  static const dayFinalized = 'day_finalized';

  /// 卵が孵化した（コアループの山場 / S5）。
  static const eggHatched = 'egg_hatched';

  /// 色違いが孵化した（グロースの種 / S13。egg_hatched と二重に発火させて専用集計）。
  static const shinyHatched = 'shiny_hatched';

  /// 図鑑に新規登録された（コレクション進捗 / S5）。
  static const dexRegistered = 'dex_registered';

  // --- リテンション補助（クエスト / S12） ---

  /// クエスト報酬を受け取った（継続のフック / S12）。
  static const questClaimed = 'quest_claimed';

  // --- マネタイズ（課金ファネル / PRICING §4） ---

  /// ペイウォールが表示された（課金ファネルの入口）。
  static const paywallViewed = 'paywall_viewed';

  /// 購入が完了した（entitlement `premium` 有効化 / PRICING §4-2）。
  /// 注: 最終的な課金確定はサーバー（RevenueCat Webhook）が正。これは即時の行動計測。
  static const purchaseCompleted = 'purchase_completed';
}

/// イベントプロパティのキー（表記ゆれ防止のため集約）。
///
/// PII 厳守: ここに「分数・金額・ユーザー名・メール」等の生値キーは定義しない。
/// 載せてよいのはカテゴリ値（レアリティ・プラン期間・経路）のみ。
abstract final class AnalyticsProps {
  /// 卵レアリティ（normal/rare/epic/legend）。egg_hatched 等。
  static const eggRarity = 'egg_rarity';

  /// Mofi レアリティ（n/r/sr/ssr）。egg_hatched / dex_registered。
  static const mofiRarity = 'mofi_rarity';

  /// 色違いか（true/false）。egg_hatched に付与し色違い率を集計。
  static const isShiny = 'is_shiny';

  /// プラン期間（monthly/annual）。purchase_completed / paywall_viewed。
  static const planPeriod = 'plan_period';

  /// 流入経路（どの画面からペイウォールへ来たか）。paywall_viewed。
  /// 値はカテゴリ文字列のみ（例: 'eggs_storage_lock' / 'menu'）。
  static const source = 'source';
}

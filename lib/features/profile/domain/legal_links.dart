/// 法務文書・問い合わせ窓口のリンク定数（SCREEN_FLOWS §6 / S12）。
///
/// 信頼境界/SSOT:
///   * URL はプレースホルダ定数として1箇所に集約（コピペで散らさない）。
///     本番URLは法務部署成果物に差し替える。文書本体は以下に対応:
///       - privacyPolicy           → docs/legal/privacy_policy.md
///       - termsOfService          → docs/legal/terms_of_service.md
///       - commercialTransactions  → docs/legal/tokushoho.md（特商法表記）
///   * アプリ外（Web）からの削除リクエスト窓口（mailto）も S12 必須要件として持つ。
///
/// 差し替え方針（法務確認済み・2026-06-23）:
///   * 本番URL/宛先メールはホスティング先・独自ドメイン確定後に差し替える（現状はプレースホルダ維持）。
///     差し替え時はストアのプラポリURLフィールドと本定数を必ず一致させること
///     （プラポリ申告とストア掲載の乖離は審査リジェクト要因 / docs/legal/STORE_DATA_SAFETY.md §4-4）。
///   * supportEmail / accountDeletionEmail は審査時の到達性が必須のため、
///     独自ドメイン + 受信確認（転送）まで行ってから差し替える。
///   * 現状の定数構造（URL集約・一般窓口/削除窓口の分離・件名プリフィル）は妥当。
library;

abstract final class LegalLinks {
  LegalLinks._();

  /// プライバシーポリシー（TODO: 法務確定URLに差し替え）。
  static const String privacyPolicy = 'https://moffy.example.com/privacy';

  /// 利用規約（TODO: 法務確定URLに差し替え）。
  static const String termsOfService = 'https://moffy.example.com/terms';

  /// 特定商取引法に基づく表記（TODO: 法務確定URLに差し替え）。
  static const String commercialTransactions =
      'https://moffy.example.com/tokushoho';

  /// 問い合わせ・フィードバック窓口（mailto / 最低限の導線 / §5-6）。
  /// 合同会社Lan 公式（info@lan-corp.com / 受信は法人運用 Gmail へ転送・到達確認済み）。
  static const String supportEmail = 'info@lan-corp.com';

  /// アプリ外データ削除リクエスト窓口（S12 / Google要件: 再インストール不要の削除手段）。
  /// 一般窓口と同一メールボックス。件名プリフィルで削除依頼を識別する。
  static const String accountDeletionEmail = 'info@lan-corp.com';

  /// 削除リクエスト用 mailto（件名プリフィル）。
  static String get deletionMailto =>
      'mailto:$accountDeletionEmail?subject=${Uri.encodeComponent('アカウント削除のご依頼')}';

  /// フィードバック用 mailto。
  static String get supportMailto =>
      'mailto:$supportEmail?subject=${Uri.encodeComponent('Moffyへのお問い合わせ')}';
}

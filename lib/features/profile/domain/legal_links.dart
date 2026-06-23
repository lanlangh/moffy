/// 法務文書・問い合わせ窓口のリンク定数（SCREEN_FLOWS §6 / S12）。
///
/// 信頼境界/SSOT:
///   * URL はプレースホルダ定数として1箇所に集約（コピペで散らさない）。
///     本番URLは法務部署成果物（プライバシーポリシー/利用規約/特商法）に差し替える。
///   * アプリ外（Web）からの削除リクエスト窓口（mailto）も S12 必須要件として持つ。
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
  static const String supportEmail = 'support@moffy.example.com';

  /// アプリ外データ削除リクエスト窓口（S12 / Google要件: 再インストール不要の削除手段）。
  static const String accountDeletionEmail = 'delete@moffy.example.com';

  /// 削除リクエスト用 mailto（件名プリフィル）。
  static String get deletionMailto =>
      'mailto:$accountDeletionEmail?subject=${Uri.encodeComponent('アカウント削除のご依頼')}';

  /// フィードバック用 mailto。
  static String get supportMailto =>
      'mailto:$supportEmail?subject=${Uri.encodeComponent('Moffyへのお問い合わせ')}';
}

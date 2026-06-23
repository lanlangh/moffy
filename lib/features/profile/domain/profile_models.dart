/// プロフィール/メニューまわりのドメインモデル（ARCHITECTURE §1-2 / S9,S10,S12）。
///
/// 信頼境界（ARCHITECTURE §0-2）:
///   * 統計（[ProfileStats]）は `profiles` / `point_ledger` / `mofi_collection` / `streaks`
///     等のサーバー集計値。表示は取得値ベース（クライアントは集計しない）。
///   * アカウント連携・退会はサーバー（Supabase auth / RPC）の責務。本モデルは表示用。
library;

/// アカウント連携状態（S10）。匿名のままか、連携済みか。
class AccountState {
  /// 匿名認証のままか（連携導線を促す / S10）。
  final bool isAnonymous;

  /// 連携済みプロバイダ（'apple' / 'google' / 'email' / 空=未連携）。
  final List<String> linkedProviders;

  /// 表示用のアカウント識別（メール等 / 匿名は null）。
  final String? displayIdentifier;

  const AccountState({
    required this.isAnonymous,
    required this.linkedProviders,
    this.displayIdentifier,
  });

  bool get isLinked => !isAnonymous && linkedProviders.isNotEmpty;
}

/// 連携プロバイダ種別（S10）。Apple は iOS 必須（4.8/5.1）。
enum AuthProvider {
  apple,
  google,
  email;

  String get wire => name;

  String get label => switch (this) {
        AuthProvider.apple => 'Appleでサインイン',
        AuthProvider.google => 'Googleでサインイン',
        AuthProvider.email => 'メールでサインイン',
      };
}

/// プロフィール統計（SCREEN_FLOWS §6 / 要件定義）。数字はBalooで主役化。
class ProfileStats {
  /// 総削減時間（分）。累計の point_ledger 由来（または別集計）。
  final int totalReducedMinutes;

  /// 総獲得Mofi数（図鑑の発見実数 / 重複含む or distinct はサーバー定義）。
  final int totalMofi;

  /// 図鑑達成率の分子（発見済みエントリ数）。
  final int dexDiscovered;

  /// 図鑑総数（分母 / app_config.dex_total_entries = 30）。
  final int dexTotal;

  /// 最長ストリーク（streaks.longest_streak / S14）。
  final int longestStreak;

  /// 累計ポイント（point_ledger 合計）。
  final int totalPoints;

  const ProfileStats({
    required this.totalReducedMinutes,
    required this.totalMofi,
    required this.dexDiscovered,
    required this.dexTotal,
    required this.longestStreak,
    required this.totalPoints,
  });

  /// 図鑑達成率 0.0〜1.0。
  double get dexRatio =>
      dexTotal <= 0 ? 0 : (dexDiscovered / dexTotal).clamp(0.0, 1.0);

  /// 総削減時間の「時間」部分（表示用）。
  int get reducedHours => totalReducedMinutes ~/ 60;

  /// 総削減時間の「分」部分（表示用）。
  int get reducedMinutesPart => totalReducedMinutes % 60;

  /// まだ何も実績が無い（空状態は出さず「これから集めよう」表示 / SCREEN_FLOWS §6）。
  bool get isFresh =>
      totalReducedMinutes == 0 &&
      totalMofi == 0 &&
      dexDiscovered == 0 &&
      totalPoints == 0;
}

/// プロフィール画面のスナップショット（統計 + アカウント状態 + オフライン）。
class ProfileState {
  final ProfileStats stats;
  final AccountState account;

  /// オフライン中か（連携・退会導線をグレーアウト / S10,S12）。
  final bool isOffline;

  const ProfileState({
    required this.stats,
    required this.account,
    required this.isOffline,
  });
}

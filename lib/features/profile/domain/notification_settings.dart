/// 通知設定のドメインモデル（S9）。5種の個別ON/OFF。
///
/// S9:
///   * MVPはローカル通知中心。許可依頼はコアループを1回体験させた後（許可率向上）。
///   * すべて設定で個別ON/OFF可能。既定はすべてON。
///   * 保存はローカル（shared_preferences）。サーバーには持たない（端末ごとの設定）。
library;

/// 通知の種類（S9 表 / 5種）。
enum NotificationKind {
  /// 孵化準備完了（育成中の卵が孵化間近 / 残50pt以内）。
  hatchReady,

  /// デイリー未達（デイリーリマインド / 既定21:00）。
  dailyReminder,

  /// ストリーク危機（その日未達かつ就寝前 / 既定22:00）。
  streakRisk,

  /// ウィークリー（週次サマリー / 日曜夜）。
  weeklySummary,

  /// 復帰（しばらく開いていないユーザーへの復帰促し）。
  comeback;

  String get wire => name;

  /// 設定画面の表示ラベル（日本語）。
  String get label => switch (this) {
        NotificationKind.hatchReady => '孵化準備完了',
        NotificationKind.dailyReminder => 'デイリーリマインド',
        NotificationKind.streakRisk => 'ストリーク途切れ警告',
        NotificationKind.weeklySummary => '週次サマリー',
        NotificationKind.comeback => '復帰のお知らせ',
      };

  /// 補足説明。
  String get description => switch (this) {
        NotificationKind.hatchReady => '育てている卵がもうすぐ孵るとき',
        NotificationKind.dailyReminder => '毎日きまった時間にやさしくお知らせ',
        NotificationKind.streakRisk => '連続記録が途切れそうなとき',
        NotificationKind.weeklySummary => '今週の削減時間とMofi獲得をまとめて',
        NotificationKind.comeback => 'しばらくお休みしたあとに',
      };

  /// 保存キー（shared_preferences）。`notif_` プレフィックスで衝突回避。
  String get prefKey => 'notif_$name';
}

/// 通知設定一式（5種のON/OFF）。
class NotificationSettings {
  /// 種別→有効か。欠損は既定ON（[NotificationKind] 全種を網羅）。
  final Map<NotificationKind, bool> enabled;

  const NotificationSettings(this.enabled);

  /// 既定: すべてON（S9）。
  factory NotificationSettings.defaults() => NotificationSettings({
        for (final k in NotificationKind.values) k: true,
      });

  bool isEnabled(NotificationKind kind) => enabled[kind] ?? true;

  /// 1種だけ切り替えた新しい設定を返す（不変更新）。
  NotificationSettings toggle(NotificationKind kind, bool value) {
    final next = Map<NotificationKind, bool>.from(enabled);
    next[kind] = value;
    return NotificationSettings(next);
  }
}

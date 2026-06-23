/// 利用時間取得まわりのモデル（ARCHITECTURE §2-1）。
/// OS差（Android/iOS）は [UsageMode] で表現し、上位は本モデルのみ参照する。
library;

/// ポイント計算モード。OS差をここで表現する。
enum UsageMode {
  /// Android: 分単位の正確な利用時間が取れる。
  exactMinutes,

  /// iOS(v1.1): 分単位は取れず、段階しきい値の達成/未達のみ。
  thresholdAchievement;

  /// usage_daily.source_mode（DB）との相互変換。
  String get wire => switch (this) {
        UsageMode.exactMinutes => 'exact-minutes',
        UsageMode.thresholdAchievement => 'threshold-achievement',
      };

  static UsageMode fromWire(String s) => switch (s) {
        'threshold-achievement' => UsageMode.thresholdAchievement,
        _ => UsageMode.exactMinutes,
      };
}

/// 利用統計アクセス権限の状態。
enum UsagePermissionStatus {
  granted, // 許可済み
  denied, // 拒否（再要求可）
  permanentlyDenied, // 恒久拒否（OS設定誘導が必要）
  notApplicable; // この機能を持たないプラットフォーム

  bool get isGranted => this == UsagePermissionStatus.granted;
}

/// ある1日の対象アプリ利用実績（生データ / ARCHITECTURE §2-1）。
class DailyUsage {
  /// ユーザーTZの暦日（0:00基準）。
  final DateTime date;

  /// パッケージ名 -> 利用分。
  final Map<String, int> perAppMinutes;

  /// 対象アプリ合計（ポイント計算の入力 / S3）。
  final int totalMinutes;

  /// どのモードで取得したか。
  final UsageMode mode;

  /// S4: 物理的にありえない値（1440分超）なら true。
  final bool isAnomaly;

  const DailyUsage({
    required this.date,
    required this.perAppMinutes,
    required this.totalMinutes,
    required this.mode,
    this.isAnomaly = false,
  });

  /// 利用0分（対象アプリ未使用）。空状態だがエラーではない（受け入れ §5-1）。
  bool get isZero => totalMinutes == 0;

  /// perApp 合計から構築。1440分（24h）超は異常値としてフラグ（S4）。
  factory DailyUsage.fromPerApp({
    required DateTime date,
    required Map<String, int> perAppMinutes,
    required UsageMode mode,
  }) {
    final total = perAppMinutes.values.fold<int>(0, (a, b) => a + b);
    return DailyUsage(
      date: DateTime(date.year, date.month, date.day),
      perAppMinutes: Map.unmodifiable(perAppMinutes),
      totalMinutes: total,
      mode: mode,
      isAnomaly: total > 1440,
    );
  }
}

/// 取得失敗時の例外（権限なし/OS API失敗/Platform Channelエラー）。
class UsageException implements Exception {
  /// 'no_permission' | 'platform_error' | 'unsupported'
  final String code;
  final String message;
  const UsageException(this.code, this.message);

  @override
  String toString() => 'UsageException($code): $message';
}

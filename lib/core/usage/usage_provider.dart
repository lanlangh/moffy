import 'usage_models.dart';

/// 対象SNSアプリの利用時間取得を抽象化する（ARCHITECTURE §2-1）。
///
/// Android = `UsageStatsManager`（exact-minutes） /
/// iOS(v1.1) = `DeviceActivity`（threshold-achievement）で実装する。
/// features 層はプラットフォームを意識せず、本抽象のみに依存する。
abstract interface class UsageProvider {
  /// このプラットフォームの計算モード。PointCalculator の選択に使う。
  UsageMode get mode;

  /// 利用統計アクセス権限の現在状態を返す。
  /// Android: PACKAGE_USAGE_STATS / iOS: FamilyControls Authorization。
  Future<UsagePermissionStatus> checkPermission();

  /// 権限要求フローを起動する（OS設定画面への遷移を含む）。
  /// 戻り値は要求後の状態。未許可時は呼び出し側がフォールバックUIを出す。
  Future<UsagePermissionStatus> requestPermission();

  /// 指定日（ユーザーTZの暦日）における対象アプリ別の利用分数を取得する。
  /// [targetPackages] はホワイトリスト（S3: 対象4SNS）。
  /// 取得失敗は [UsageException] を throw する（権限なし/OS API失敗）。
  Future<DailyUsage> fetchDailyUsage({
    required DateTime date,
    required List<String> targetPackages,
  });

  /// 指定期間（基準値計算用の直近N日）の日別利用を一括取得する。
  /// 欠損日（取得不可日）はリストに含めない（= 分母から除外 / S11）。
  Future<List<DailyUsage>> fetchUsageRange({
    required DateTime startDate, // 含む
    required DateTime endDate, // 含む
    required List<String> targetPackages,
  });
}

/// 機能を提供しないプラットフォーム（テスト/未対応OS）向けの no-op 実装。
/// クラッシュさせず常に notApplicable を返す（ARCHITECTURE §4-5 フォールバック）。
class UnsupportedUsageProvider implements UsageProvider {
  const UnsupportedUsageProvider();

  @override
  UsageMode get mode => UsageMode.exactMinutes;

  @override
  Future<UsagePermissionStatus> checkPermission() async =>
      UsagePermissionStatus.notApplicable;

  @override
  Future<UsagePermissionStatus> requestPermission() async =>
      UsagePermissionStatus.notApplicable;

  @override
  Future<DailyUsage> fetchDailyUsage({
    required DateTime date,
    required List<String> targetPackages,
  }) =>
      throw const UsageException('unsupported', 'このプラットフォームは未対応です');

  @override
  Future<List<DailyUsage>> fetchUsageRange({
    required DateTime startDate,
    required DateTime endDate,
    required List<String> targetPackages,
  }) =>
      throw const UsageException('unsupported', 'このプラットフォームは未対応です');
}

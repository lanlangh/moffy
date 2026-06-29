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

/// iOS スクリーンタイム固有の操作（Android には無い / ORG_STATE 2026-06-26 iOSフル実装）。
///
/// 重要な仕様差（Android の移植ではない）: iOS は対象アプリを Moffy 側から自動指定
/// できない（不透明トークン・プライバシー設計）。ユーザーが OS の `FamilyActivityPicker`
/// で自分で対象 SNS を選ぶ必要がある。オンボーディングは
/// `usageProvider is ScreenTimeAppSelection` でこの分岐を出し分ける（型安全な capability 判定）。
abstract interface class ScreenTimeAppSelection {
  /// 対象アプリ選択（`FamilyActivityPicker`）を提示し、選択を端末に永続化したうえで
  /// `DeviceActivity` 監視を（再）開始する。戻り値は選択完了後の状態。
  Future<ScreenTimeSelectionResult> presentAppPicker();

  /// 対象アプリ選択が保存済みか（オンボーディングの「選択済み」表示判定に使う）。
  Future<bool> hasAppSelection();
}

/// [ScreenTimeAppSelection.presentAppPicker] の結果。
class ScreenTimeSelectionResult {
  /// 1つ以上のアプリ/カテゴリ/Webドメインが選択されているか。
  final bool selected;

  /// 選択要素数（アプリ＋カテゴリ＋Webドメインの合計の目安・表示用）。
  final int count;

  const ScreenTimeSelectionResult({required this.selected, required this.count});

  /// 何も選択されていない（= 監視対象なし）。
  static const ScreenTimeSelectionResult none =
      ScreenTimeSelectionResult(selected: false, count: 0);
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

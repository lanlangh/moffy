import 'package:flutter/services.dart';

import '../constants/economy.dart';
import 'usage_models.dart';
import 'usage_provider.dart';

/// iOS 実装（ORG_STATE 2026-06-26 / iOS フル実装方針）。
///
/// 重要: これは Android 実装の移植ではない。根本的な仕様差がある（PRD §6 / 意思決定ログ）:
///   * iOS は利用「分数」を取得できない。`DeviceActivity` の **しきい値到達のみ**。
///     ネイティブの監視拡張（`MoffyMonitor`）が「今日どの分しきい値まで到達したか」を
///     App Group に記録し、本プロバイダはその **到達しきい値（分）を近似利用分** として
///     読み出す（[UsageMode.thresholdAchievement]）。
///   * 監視対象アプリは **不透明トークン**で Moffy からは識別不可。ユーザーが OS の
///     `FamilyActivityPicker` で自分で選ぶ（[presentAppPicker]）。このため引数の
///     [targetPackages] は **iOS では無視**する（パッケージ名で対象を指定できない）。
///   * 計算モードは [UsageMode.thresholdAchievement]。近似分を既存の
///     `ThresholdAchievementPointCalculator` に流し、サーバー `fn_finalize_day` が確定する。
///
/// ネイティブ（Swift `ScreenTimeHandler`）とは [AppConstants.usageChannel] の
/// [MethodChannel] で通信する。メソッド名・引数キー・戻り値形状は Swift 側と厳密一致させる。
class IOSUsageProvider implements UsageProvider, ScreenTimeAppSelection {
  IOSUsageProvider({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(AppConstants.usageChannel);

  final MethodChannel _channel;

  /// iOS は per-app 内訳を取得できないため、合成バケット1つに近似分を入れる
  /// （UI は totalMinutes のみ参照・内訳は表示しない）。
  static const String _bucketKey = 'ios.screentime';

  @override
  UsageMode get mode => UsageMode.thresholdAchievement;

  @override
  Future<UsagePermissionStatus> checkPermission() async {
    try {
      final result = await _channel.invokeMethod<String>('checkPermission');
      return _statusFromString(result);
    } on PlatformException {
      return UsagePermissionStatus.denied;
    }
  }

  @override
  Future<UsagePermissionStatus> requestPermission() async {
    // iOS: FamilyControls authorization を要求（OS の許可シート）。
    // 対象アプリ選択（FamilyActivityPicker）は別ステップ（[presentAppPicker]）。
    try {
      final result = await _channel.invokeMethod<String>('requestPermission');
      return _statusFromString(result);
    } on PlatformException {
      // 要求自体が失敗しても、現在値を返す（呼び出し側が onResume で再確認）。
      return checkPermission();
    }
  }

  @override
  Future<bool> hasAppSelection() async {
    try {
      return await _channel.invokeMethod<bool>('hasSelection') ?? false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<ScreenTimeSelectionResult> presentAppPicker() async {
    try {
      final raw =
          await _channel.invokeMethod<Map<Object?, Object?>>('presentAppPicker');
      final map = raw?.cast<Object?, Object?>() ?? const <Object?, Object?>{};
      return ScreenTimeSelectionResult(
        selected: (map['selected'] as bool?) ?? false,
        count: (map['count'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException {
      // ピッカーがキャンセル/失敗しても落とさない（選択なし扱い）。
      return ScreenTimeSelectionResult.none;
    }
  }

  @override
  Future<DailyUsage> fetchDailyUsage({
    required DateTime date,
    required List<String> targetPackages, // iOS では無視（不透明トークン）。
  }) async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'queryDailyUsage',
        <String, Object?>{'dateMs': _dayStartMs(date)},
      );
      final minutes = (raw?['minutes'] as num?)?.toInt() ?? 0;
      return _dailyUsageFromMinutes(date, minutes);
    } on PlatformException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<List<DailyUsage>> fetchUsageRange({
    required DateTime startDate,
    required DateTime endDate,
    required List<String> targetPackages, // iOS では無視。
  }) async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'queryRangeUsage',
        <String, Object?>{
          'startMs': _dayStartMs(startDate),
          'endMs': _dayStartMs(endDate),
        },
      );
      if (raw == null) return const [];
      final out = <DailyUsage>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final m = entry.cast<Object?, Object?>();
        final dateMs = (m['dateMs'] as num?)?.toInt();
        if (dateMs == null) continue;
        final minutes = (m['minutes'] as num?)?.toInt() ?? 0;
        // ネイティブは「記録のある日」のみ返す（欠損日除外 / S11）。
        // 念のため minutes<=0 も除外し、baseline を 0 分で薄めない。
        if (minutes <= 0) continue;
        out.add(
          _dailyUsageFromMinutes(
            DateTime.fromMillisecondsSinceEpoch(dateMs),
            minutes,
          ),
        );
      }
      return out;
    } on PlatformException catch (e) {
      throw _mapException(e);
    }
  }

  // --- ヘルパ ---

  /// しきい値到達（分）から [DailyUsage] を構築。0分は空＝[DailyUsage.isZero]。
  DailyUsage _dailyUsageFromMinutes(DateTime date, int minutes) {
    final perApp =
        minutes > 0 ? <String, int>{_bucketKey: minutes} : const <String, int>{};
    return DailyUsage.fromPerApp(
      date: date,
      perAppMinutes: perApp,
      mode: mode,
    );
  }

  /// ユーザーTZの 0:00 をミリ秒で返す（ネイティブの日付キー（yyyy-MM-dd 端末ローカル）と一致 / S11）。
  int _dayStartMs(DateTime date) =>
      DateTime(date.year, date.month, date.day).millisecondsSinceEpoch;

  UsagePermissionStatus _statusFromString(String? s) => switch (s) {
        'granted' => UsagePermissionStatus.granted,
        'permanently_denied' => UsagePermissionStatus.permanentlyDenied,
        'not_applicable' => UsagePermissionStatus.notApplicable,
        _ => UsagePermissionStatus.denied,
      };

  UsageException _mapException(PlatformException e) => switch (e.code) {
        'no_permission' => const UsageException(
            'no_permission',
            'スクリーンタイムへのアクセスが許可されていません',
          ),
        'unsupported' => const UsageException(
            'unsupported',
            'この端末ではスクリーンタイムを利用できません',
          ),
        _ => UsageException(
            'platform_error',
            e.message ?? 'OS API 呼び出しに失敗しました',
          ),
      };
}

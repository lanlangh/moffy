import 'package:flutter/services.dart';

import '../constants/economy.dart';
import 'usage_models.dart';
import 'usage_provider.dart';

/// Android 実装（ARCHITECTURE §4-3）。
///
/// ネイティブ（Kotlin `UsageStatsHandler`）と [MethodChannel] で通信し、
/// `UsageStatsManager` から対象4SNSの利用分数を取得する。
/// チャネル名・メソッド名・引数キーは Kotlin 側と厳密に一致させること。
///
/// 取得モードは [UsageMode.exactMinutes]（分単位の正確な値）。
class AndroidUsageProvider implements UsageProvider {
  AndroidUsageProvider({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(AppConstants.usageChannel);

  final MethodChannel _channel;

  @override
  UsageMode get mode => UsageMode.exactMinutes;

  @override
  Future<UsagePermissionStatus> checkPermission() async {
    try {
      final result =
          await _channel.invokeMethod<String>('checkPermission');
      return _statusFromString(result);
    } on PlatformException {
      return UsagePermissionStatus.denied;
    }
  }

  @override
  Future<UsagePermissionStatus> requestPermission() async {
    // PACKAGE_USAGE_STATS は通常の権限要求では取れない（appop）。
    // OS設定「使用状況へのアクセス」画面を開き、復帰後に再チェックする（ARCHITECTURE §4-2）。
    try {
      await _channel.invokeMethod<void>('openUsageAccessSettings');
    } on PlatformException {
      // 設定画面が開けなくても、復帰時の checkPermission に委ねる。
    }
    // 設定画面遷移は非同期なので、ここでは現在値を返す（呼び出し側が onResume で再確認）。
    return checkPermission();
  }

  @override
  Future<DailyUsage> fetchDailyUsage({
    required DateTime date,
    required List<String> targetPackages,
  }) async {
    final (begin, end) = _dayBoundsMs(date);
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'queryDailyUsage',
        <String, Object?>{
          'beginMs': begin,
          'endMs': end,
          'packages': targetPackages,
        },
      );
      final perApp = _toPerAppMinutes(raw, targetPackages);
      return DailyUsage.fromPerApp(
        date: date,
        perAppMinutes: perApp,
        mode: mode,
      );
    } on PlatformException catch (e) {
      throw _mapException(e);
    }
  }

  @override
  Future<List<DailyUsage>> fetchUsageRange({
    required DateTime startDate,
    required DateTime endDate,
    required List<String> targetPackages,
  }) async {
    final (begin, _) = _dayBoundsMs(startDate);
    final (_, end) = _dayBoundsMs(endDate);
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'queryRangeUsage',
        <String, Object?>{
          'startMs': begin,
          'endMs': end,
          'packages': targetPackages,
        },
      );
      if (raw == null) return const [];
      final result = <DailyUsage>[];
      for (final dayEntry in raw) {
        if (dayEntry is! Map) continue;
        final dayMap = dayEntry.cast<Object?, Object?>();
        // ネイティブは {dateMs:.., usage:{pkg:minutes}} を日別に返す。
        final dateMs = (dayMap['dateMs'] as num?)?.toInt();
        if (dateMs == null) continue;
        final usage =
            (dayMap['usage'] as Map?)?.cast<Object?, Object?>() ?? const {};
        final perApp = _toPerAppMinutes(usage, targetPackages);
        // 欠損日（usage が空 = 取得できなかった日）は除外（S11: 分母から除く）。
        if (perApp.isEmpty) continue;
        result.add(
          DailyUsage.fromPerApp(
            date: DateTime.fromMillisecondsSinceEpoch(dateMs),
            perAppMinutes: perApp,
            mode: mode,
          ),
        );
      }
      return result;
    } on PlatformException catch (e) {
      throw _mapException(e);
    }
  }

  // --- ヘルパ ---

  /// ユーザーTZの 0:00〜23:59:59.999 をミリ秒で返す（S11と一致）。
  (int begin, int end) _dayBoundsMs(DateTime date) {
    final begin = DateTime(date.year, date.month, date.day);
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59, 999);
    return (begin.millisecondsSinceEpoch, end.millisecondsSinceEpoch);
  }

  /// ネイティブの {pkg: minutes} をホワイトリストで絞った Map<String,int> に変換。
  Map<String, int> _toPerAppMinutes(
    Map<Object?, Object?>? raw,
    List<String> targetPackages,
  ) {
    if (raw == null) return {};
    final whitelist = targetPackages.toSet();
    final out = <String, int>{};
    raw.forEach((k, v) {
      final pkg = k?.toString();
      if (pkg == null || !whitelist.contains(pkg)) return;
      final minutes = (v as num?)?.toInt() ?? 0;
      if (minutes > 0) out[pkg] = minutes;
    });
    return out;
  }

  UsagePermissionStatus _statusFromString(String? s) => switch (s) {
        'granted' => UsagePermissionStatus.granted,
        'permanently_denied' => UsagePermissionStatus.permanentlyDenied,
        _ => UsagePermissionStatus.denied,
      };

  UsageException _mapException(PlatformException e) => switch (e.code) {
        'no_permission' =>
          const UsageException('no_permission', '利用統計へのアクセス権限がありません'),
        'unsupported' =>
          const UsageException('unsupported', 'この端末では利用統計を取得できません'),
        _ => UsageException('platform_error', e.message ?? 'OS API 呼び出しに失敗しました'),
      };
}

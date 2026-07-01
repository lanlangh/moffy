import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'android_usage_provider.dart';
import 'ios_usage_provider.dart';
import 'point_calculator.dart';
import 'usage_models.dart';
import 'usage_provider.dart';

/// OS抽象（利用時間取得）の DI（ARCHITECTURE §1-3 usageProviderProvider）。
/// プラットフォームで実装を切り替える。テストでは override 可能。
final usageProviderProvider = Provider<UsageProvider>((ref) {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return AndroidUsageProvider(); // exact-minutes（UsageStatsManager）
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    // threshold-achievement（DeviceActivity）。Android の移植ではない（usage_provider.dart 参照）。
    return IOSUsageProvider();
  }
  // Web / その他は未対応（クラッシュさせない）。
  return const UnsupportedUsageProvider();
});

/// ポイント計算の DI（ARCHITECTURE §1-3 pointCalculatorProvider）。
/// usageProvider の mode に追従して exact / threshold を選ぶ。
final pointCalculatorProvider = Provider<PointCalculator>((ref) {
  final mode = ref.watch(usageProviderProvider).mode;
  return switch (mode) {
    UsageMode.exactMinutes => const ExactMinutesPointCalculator(),
    UsageMode.thresholdAchievement =>
      const ThresholdAchievementPointCalculator(),
  };
});

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

/// 対象アプリ（iOS の「見守るアプリ」）が選ばれているか。
///
/// 【2026-10-05 追加】iOS はスクリーンタイムの**許可だけでは計測できない**。
///   `FamilyActivityPicker` で対象アプリを選ばないと `DeviceActivity` が何も監視せず、
///   **永久に0分**になる。ところが権限はあるので、これまでホームは何の警告も出さず、
///   本人は「自分が使っていないから0なんだ」と誤解する状態だった。
///   実測（2026-10-05）: オーナー自身のアカウントも3か月ずっと
///   `total_minutes=0 / per_app_minutes={}` で、削減ptを得たのは全期間で6人だけ。
///
/// 選択という概念が無い実装（Android / 未対応 / テスト）は **true**（＝問題なし）を返す。
/// Android は権限さえあれば端末全体を見られるため。
final hasAppSelectionProvider = FutureProvider<bool>((ref) async {
  final usage = ref.watch(usageProviderProvider);
  if (usage is! ScreenTimeAppSelection) return true;
  // ScreenTimeAppSelection は UsageProvider のサブタイプではない（独立した capability
  // インターフェース）ため型プロモーションが効かない。is! ガード済みなので安全
  // （target_apps_screen.dart と同じ作法）。
  final selection = usage as ScreenTimeAppSelection;
  try {
    return await selection.hasAppSelection();
  } catch (_) {
    // 判定できないときは警告を出さない側に倒す（誤警告で混乱させない）。
    return true;
  }
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

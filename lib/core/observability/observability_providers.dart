/// 監視/分析の Riverpod プロバイダ群（ARCHITECTURE §1-3 / lib/core/iap と同形）。
///
/// 提供する依存:
///   * [analyticsProvider]      … PostHog 実装 or Noop（Env で切替・override 可）。
///   * [crashReporterProvider]  … Sentry 実装 or Noop（Env で切替・override 可）。
///
/// 設計（IapService の providers と同じ流儀）:
///   * Env にキー/DSN があれば実装、無ければ Noop にフォールバック（クラッシュさせない）。
///   * SDK の初期化（PostHog.setup / SentryFlutter.init）は main.dart が担う。ここでは
///     初期化済み前提の薄いラッパを配るだけ（init の有無と provider 選択は Env で一致する）。
///   * テスト/UI確認では override で Noop（または fake）を注入できる。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import 'analytics.dart';
import 'crash_reporter.dart';

/// 行動分析サービス。Env に PostHog キーがあれば実装、無ければ Noop。
final analyticsProvider = Provider<Analytics>((ref) {
  if (!Env.hasPostHog) return const NoopAnalytics();
  return PostHogAnalytics();
});

/// クラッシュ監視サービス。Env に Sentry DSN があれば実装、無ければ Noop。
final crashReporterProvider = Provider<CrashReporter>((ref) {
  if (!Env.hasSentry) return const NoopCrashReporter();
  return const SentryCrashReporter();
});

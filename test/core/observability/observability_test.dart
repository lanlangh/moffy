import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/config/env.dart';
import 'package:moffy/core/observability/analytics.dart';
import 'package:moffy/core/observability/analytics_events.dart';
import 'package:moffy/core/observability/crash_reporter.dart';

/// 監視/分析レールの純粋ユニットテスト（QA引き継ぎ観点）。
///
/// 検証対象（最小・回帰固定）:
///   * Env の has* 判定がキー未注入（テスト環境＝dart-define なし）で false になること
///     （未設定時に Noop へフォールバックする前提を固定 / クラッシュさせない）。
///   * Noop 実装が一切スローしないこと（未設定/オフライン/テストでの安全性）。
void main() {
  group('Env 監視/分析の has* 判定（キー未注入で false）', () {
    test('hasSentry はテスト環境（DSN未注入）で false', () {
      // テストは --dart-define なしで走るため SENTRY_DSN は空 → false が期待値。
      expect(Env.hasSentry, isFalse);
      expect(Env.sentryDsn, isEmpty);
    });

    test('hasPostHog はテスト環境（キー未注入）で false', () {
      expect(Env.hasPostHog, isFalse);
      expect(Env.postHogApiKey, isEmpty);
    });

    test('postHogHost は既定で US クラウド', () {
      expect(Env.postHogHost, 'https://us.i.posthog.com');
    });
  });

  group('Noop 実装はスローしない（未設定フォールバックの安全性）', () {
    test('NoopAnalytics の各メソッドが例外を投げない', () {
      const analytics = NoopAnalytics();
      expect(
        () {
          analytics.capture(AnalyticsEvents.appOpened);
          analytics.capture(
            AnalyticsEvents.eggHatched,
            properties: {AnalyticsProps.isShiny: true},
          );
          analytics.identifyAnonymous('anon-123');
          analytics.reset();
        },
        returnsNormally,
      );
    });

    test('NoopCrashReporter の各メソッドが例外を投げない', () async {
      const reporter = NoopCrashReporter();
      await expectLater(
        reporter.captureException(
          StateError('x'),
          stackTrace: StackTrace.current,
          hint: 'test',
        ),
        completes,
      );
      await expectLater(reporter.captureMessage('msg'), completes);
    });
  });
}

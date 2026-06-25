import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/observability/crash_reporter.dart';
import 'core/observability/log.dart';
import 'core/providers/supabase_provider.dart';

/// エントリポイント（ARCHITECTURE §1-1）。
/// 初期化順: Flutter binding -> Supabase（任意）-> 監視/分析（任意）-> ProviderScope(override) -> App。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // override リスト（初期化できたものだけ注入）。
  final overrides = <Override>[];

  if (Env.hasSupabase) {
    try {
      await Supabase.initialize(
        url: Env.supabaseUrl,
        publishableKey: Env.supabaseAnonKey,
        // 匿名認証ファースト（S10）。セッション永続化は supabase_flutter 既定。
      );
      overrides.add(
        supabaseClientProvider.overrideWithValue(Supabase.instance.client),
      );
      Log.d('Supabase initialized');
    } catch (e, st) {
      // 初期化失敗でもアプリは起動させる（オフライン専用 / クラッシュさせない）。
      Log.e('Supabase init failed', error: e, stack: st);
    }
  } else {
    Log.d('Supabase 未設定: オフライン専用モードで起動（SETUP.md 参照）');
  }

  // 行動分析（PostHog）の初期化（キーありの時のみ / OBSERVABILITY_SETUP.md）。
  // 未設定時は何もしない（providers 側で NoopAnalytics にフォールバック）。
  await _initPostHog();

  // クラッシュ監視（Sentry）の初期化 + runApp。
  // DSN ありは SentryFlutter.init の appRunner でラップ、未設定時は通常の runApp に
  // フォールバックする（分岐は _runWithSentry に集約 / クラッシュさせない）。
  await _runWithSentry(() => _runApp(overrides));
}

/// PostHog をキーがある時だけ初期化する（PII/生データは送らない設計 / capture 側で担保）。
Future<void> _initPostHog() async {
  if (!Env.hasPostHog) return;
  try {
    final config = PostHogConfig(Env.postHogApiKey)
      ..host = Env.postHogHost
      // 画面の自動キャプチャは行わない（明示イベントのみ＝ノイズと誤計測を避ける）。
      ..captureApplicationLifecycleEvents = false
      ..debug = Env.isDev;
    await Posthog().setup(config);
    Log.d('PostHog initialized');
  } catch (e, st) {
    // 計測の初期化失敗でアプリを止めない（本番ログは抑止）。
    Log.e('PostHog init failed', error: e, stack: st);
  }
}

/// Sentry の DSN がある時は init でラップ、無い時は素の runApp にフォールバック。
Future<void> _runWithSentry(Future<void> Function() appRunner) async {
  if (!Env.hasSentry) {
    await appRunner();
    return;
  }
  // 本番重大エラー（Log.e）を Sentry へ転送するフックを登録（log.dart の循環依存回避）。
  const reporter = SentryCrashReporter();
  Log.crashReporterSink = (error, stack) {
    // ベストエフォート（送信完了は待たない / アプリ挙動を阻害しない）。
    reporter.captureException(error, stackTrace: stack, hint: 'log_e');
  };
  await SentryFlutter.init(
    (options) {
      options.dsn = Env.sentryDsn;
      // PII を送らない（OBSERVABILITY_SETUP.md / 厳守）。
      options.sendDefaultPii = false;
      // 本番のみ送信。デバッグ時は送らずノイズと無駄送信を避ける。
      options.debug = false;
      options.environment = Env.isDev ? 'debug' : 'production';
      // トレースは最小限（パフォーマンス計測は MVP では未使用）。
      options.tracesSampleRate = 0.0;
    },
    appRunner: appRunner,
  );
}

Future<void> _runApp(List<Override> overrides) async {
  runApp(
    ProviderScope(
      overrides: overrides,
      child: const MoffyApp(),
    ),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/iap/iap_providers.dart';
import 'core/observability/analytics_events.dart';
import 'core/observability/observability_providers.dart';
import 'core/router/app_router.dart';
import 'core/sync/daily_submission.dart';
import 'core/sync/sync_service.dart';
import 'core/theme/app_theme.dart';

/// アプリのルート（ARCHITECTURE §1-1: MaterialApp.router + テーマ + Riverpod）。
class MoffyApp extends ConsumerStatefulWidget {
  const MoffyApp({super.key});

  @override
  ConsumerState<MoffyApp> createState() => _MoffyAppState();
}

class _MoffyAppState extends ConsumerState<MoffyApp> {
  @override
  void initState() {
    super.initState();
    // ファネル入口: アプリ起動（セッション開始の代表点 / PRD §5-5）。
    // initState で1度だけ発火（build の再実行で重複させない）。
    ref.read(analyticsProvider).capture(AnalyticsEvents.appOpened);
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    // オンライン復帰時の自動同期をアプリ生存中ずっと有効化（S8 / ARCHITECTURE §1-5）。
    ref.watch(syncOnReconnectProvider);
    // 前日分の利用生データ提出 → fn_finalize_day 確定を駆動（ARCHITECTURE §1-5 step1-3）。
    // syncOnReconnectProvider が「キューを流す」のに対し、こちらが「キューに積む」。
    // 両方揃って初めて削減ptが確定する（片方だけだとコアループが無言で死ぬ）。
    ref.watch(dailySubmissionProvider);
    // IAP（RevenueCat）初期化を起動時に1度キック（未設定/失敗でも no-op で続行）。
    // CustomerInfo listener と初期プレミアム状態の取得を有効化する。
    ref.watch(iapConfiguredProvider);
    return MaterialApp.router(
      title: 'Moffy',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      routerConfig: router,
    );
  }
}

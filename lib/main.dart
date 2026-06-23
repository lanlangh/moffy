import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/env.dart';
import 'core/observability/log.dart';
import 'core/providers/supabase_provider.dart';

/// エントリポイント（ARCHITECTURE §1-1）。
/// 初期化順: Flutter binding -> Supabase（任意）-> ProviderScope(override) -> App。
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

  // TODO(後続パス): Sentry / PostHog 初期化をここに追加（レール）。

  runApp(
    ProviderScope(
      overrides: overrides,
      child: const MoffyApp(),
    ),
  );
}

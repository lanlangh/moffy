import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/env.dart';
import '../observability/log.dart';
import '../providers/supabase_provider.dart';
import 'economy.dart';

/// 経済パラメータのクライアント側キャッシュ層（ARCHITECTURE §1-1 remote_config）。
///
/// 真のSSOTは Supabase の `app_config` / `drop_tables`。本プロバイダはそこから取得し
/// [EconomyParams] にして UI / 計算へ供給する。取得前・オフラインは
/// [EconomyParams.defaults]（migration seed と一致）にフォールバックする。
///
/// 第1パスは取得未配線のため defaults を返す。後続で Supabase select を配線:
///   select key,value from app_config  ->  EconomyParams.fromConfig(map)
final economyParamsProvider = FutureProvider<EconomyParams>((ref) async {
  // 真のSSOTは app_config（読み取り公開マスタ）。設定済みなら取得して fromConfig。
  // 取得失敗/未設定/オフライン初回は defaults（migration seed と一致）にフォールバック。
  if (!Env.hasSupabase) {
    return EconomyParams.defaults;
  }
  try {
    final client = ref.read(supabaseClientProvider);
    final rows = await client.from('app_config').select('key, value');
    final map = <String, Object?>{};
    for (final raw in (rows as List)) {
      final r = (raw as Map).cast<String, Object?>();
      map[r['key']! as String] = r['value'];
    }
    return EconomyParams.fromConfig(map);
  } catch (e, st) {
    // リモート不整合・通信失敗でアプリを落とさない（defaults で続行）。
    Log.e('app_config fetch failed; using defaults', error: e, stack: st);
    return EconomyParams.defaults;
  }
});

/// S3 対象アプリ（Android）。真のSSOTは app_config.target_packages_android。
/// 第1パスは AppConstants のデフォルト。後続でリモート/ユーザー設定に追従。
final targetPackagesProvider = Provider<List<String>>((ref) {
  return AppConstants.defaultAndroidTargets.map((e) => e.packageName).toList();
});

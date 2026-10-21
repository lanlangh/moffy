import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/observability/log.dart';

/// 卵ごとに「最後に見た段階」を端末に覚えておく（0018 / docs/design/EGG_PACING_DESIGN.md §4-3）。
///
/// なぜ要るか: 段階が進んだ瞬間の「変わった！」は、**前回見たときとの差**でしか作れない。
/// サーバーは成長ptしか持たず「ユーザーが何を見たか」は知らないので、端末が覚える。
/// 値は [EggLook.step]（0..5。S4 の「強まる」も1段として数える）。
///
/// 表示のための状態なので永続化の重要度は低い（消えても「演出が出ない」だけ）。
/// 退会・別アカウントでは消す（`pendingHatch` で踏んだ「前アカウントの子が居座る」と同じ教訓）。
abstract interface class EggStageMemory {
  /// 最後に見た段階。一度も見ていない卵は null。
  Future<int?> lastSeenStep(String eggId);

  /// 見た段階を記録する。
  Future<void> remember(String eggId, int step);

  /// 全ての記録を消す（退会時）。
  Future<void> clear();
}

class SharedPrefsEggStageMemory implements EggStageMemory {
  const SharedPrefsEggStageMemory();

  /// キーは `egg_stage_seen.<egg_id>`。退会時の初期化（local_reset.dart）がこの接頭辞で消す。
  static const String keyPrefix = 'egg_stage_seen.';

  @override
  Future<int?> lastSeenStep(String eggId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt('$keyPrefix$eggId');
    } catch (e, st) {
      // 読めなければ「初めて見る」扱い（演出を出さない側に倒す）。
      Log.e('egg stage memory read failed', error: e, stack: st);
      return null;
    }
  }

  @override
  Future<void> remember(String eggId, int step) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$keyPrefix$eggId', step);
    } catch (e, st) {
      Log.e('egg stage memory write failed', error: e, stack: st);
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys().where((k) => k.startsWith(keyPrefix))) {
        await prefs.remove(k);
      }
    } catch (e, st) {
      Log.e('egg stage memory clear failed', error: e, stack: st);
    }
  }
}

/// メモリ上の実装（テスト / プレビュー用）。
class InMemoryEggStageMemory implements EggStageMemory {
  InMemoryEggStageMemory([Map<String, int>? initial])
      : _seen = {...?initial};

  final Map<String, int> _seen;

  @override
  Future<int?> lastSeenStep(String eggId) async => _seen[eggId];

  @override
  Future<void> remember(String eggId, int step) async => _seen[eggId] = step;

  @override
  Future<void> clear() async => _seen.clear();
}

/// DI（ARCHITECTURE §1-3）。テストでは [InMemoryEggStageMemory] で override する。
final eggStageMemoryProvider =
    Provider<EggStageMemory>((ref) => const SharedPrefsEggStageMemory());

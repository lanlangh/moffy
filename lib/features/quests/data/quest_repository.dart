import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/env.dart';
import '../../../core/constants/economy.dart';
import '../../../core/constants/remote_config.dart';
import '../../../core/error/failure.dart';
import '../../../core/observability/log.dart';
import '../../../core/providers/supabase_provider.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../domain/quest_models.dart';
import '../domain/quest_progress_evaluator.dart';

/// クエスト feature のデータ層（ARCHITECTURE §1-2 data / §2-3 信頼境界）。
///
/// 抽象 [QuestRepository] を features 層に公開し、Supabase/Drift の詳細を隠蔽する。
/// 第2bパスはサーバーRPC未実装のため [MockQuestRepository] で 5状態・受取フローを動かす。
///
/// 信頼境界:
///   * クエスト定義は `quest_definitions`（読み取り公開マスタ / rule_json=condition）。
///   * 進捗はローカル判定（[QuestProgressEvaluator]）でUI表示するが、
///     **受取（報酬付与）はサーバーRPC `fn_grant_quest_reward` の責務**。本クラスは
///     「受取要求の口」だけを持ち、残高加算・卵生成・抽選は一切しない（TODO明示）。
abstract interface class QuestRepository {
  /// クエスト画面のスナップショット（デイリー/ウィークリー + ストリーク）を取得する。
  Future<QuestsState> loadQuests(EconomyParams params);

  /// 達成済みクエストの報酬を受け取る（オンライン必須 / 残高操作のため）。
  ///
  /// 信頼境界: 実体はサーバーRPC `fn_grant_quest_reward`（security definer / 冪等）。
  /// クライアントは「受取要求」を送るだけで、付与結果はサーバーが確定する。
  /// 戻り値は受取後のクエスト（rewardGranted=true）。失敗は [Failure] を throw。
  Future<Quest> claimReward(String questId);
}

/// モック実装（第2bパス）。サーバーRPC未実装のため、ローカルのダミー定義 + 進捗判定で
/// 5状態・受取フローを成立させる。残高への確定書き込みは行わない（表示状態のみ更新）。
class MockQuestRepository implements QuestRepository {
  MockQuestRepository(this._ref);

  final Ref _ref;

  /// メモリ上のモック・クエスト（受取の反映を見せるため可変リストで保持）。
  /// TODO(本実装): Supabase `quest_definitions` select + `user_quests` の当期インスタンス
  ///   取得に置換。進捗は実績（usage_daily / ledger / collection）から
  ///   [QuestProgressEvaluator] で算出、または fn_finalize_day が確定した値を読む。
  late final List<Quest> _quests = _seedQuests();

  /// モック・ストリーク（サーバー SSOT のスタブ）。
  /// TODO(本実装): `streaks` を select（current/longest）。表示は取得値ベース。
  final int _streakCurrent = 5; // ×1.2 段（3日以上7日未満）を見せる
  final int _streakLongest = 12;

  List<Quest> _seedQuests() {
    return const [
      Quest(
        id: 'daily_reduce_30',
        kind: QuestKind.daily,
        title: '30分減らそう',
        description: '対象SNSの合計を昨日より30分減らす',
        condition: QuestCondition(
          type: QuestConditionType.reduceTotal,
          target: 30,
        ),
        reward: QuestReward(points: 50),
        progress: 30, // 達成済み（受取可能を見せる）
        isCompleted: true,
        rewardGranted: false,
      ),
      Quest(
        id: 'daily_sns_under_60',
        kind: QuestKind.daily,
        // 特定アプリ名を名指ししない（iOS の FamilyControls はアプリを個別識別できず
        // 名指しは実装乖離＝docs/IOS_SCREENTIME.md）。package を持たない app_under＝
        // 対象SNS合計の"予算メーター"（quest_models: package null=合計）。
        title: 'SNSは合計60分まで',
        description: '対象SNSの合計利用を60分未満におさえる',
        condition: QuestCondition(
          type: QuestConditionType.appUnder,
          target: 60,
        ),
        reward: QuestReward(points: 30),
        progress: 12, // 進行中
        isCompleted: false,
        rewardGranted: false,
      ),
      Quest(
        id: 'daily_streak_keep',
        kind: QuestKind.daily,
        title: '今日もキープ',
        description: 'ストリークを今日も維持する',
        condition: QuestCondition(
          type: QuestConditionType.streakKeep,
          target: 1,
        ),
        reward: QuestReward(points: 20),
        progress: 0, // 未達
        isCompleted: false,
        rewardGranted: false,
      ),
      Quest(
        id: 'weekly_hatch_3',
        kind: QuestKind.weekly,
        title: '今週3個孵そう',
        description: '今週中に卵を3個孵化させる',
        condition: QuestCondition(
          type: QuestConditionType.hatchCount,
          target: 3,
        ),
        reward: QuestReward(points: 100, gems: 10),
        progress: 1, // 進行中
        isCompleted: false,
        rewardGranted: false,
      ),
      Quest(
        id: 'weekly_points_1000',
        kind: QuestKind.weekly,
        title: '今週1000pt',
        description: '今週の基礎ポイントを累計1000pt獲得',
        condition: QuestCondition(
          type: QuestConditionType.pointsEarn,
          target: 1000,
        ),
        reward: QuestReward(points: 0, gems: 20, eggRarity: 'rare'),
        progress: 640, // 進行中
        isCompleted: false,
        rewardGranted: false,
      ),
    ];
  }

  @override
  Future<QuestsState> loadQuests(EconomyParams params) async {
    final isOnline = _ref.read(isOnlineProvider);

    final daily = _quests.where((q) => q.kind == QuestKind.daily).toList();
    final weekly = _quests.where((q) => q.kind == QuestKind.weekly).toList();

    return QuestsState(
      daily: daily,
      weekly: weekly,
      streak: StreakState(
        current: _streakCurrent,
        longest: _streakLongest,
        tiers: params.streakMultipliers,
      ),
      isOffline: !isOnline,
    );
  }

  @override
  Future<Quest> claimReward(String questId) async {
    // 信頼境界（S受け入れ §5-3「二重付与せずリトライ」）:
    //   オフライン中は残高操作不可（呼び出し側でグレーアウトするが、二重防御でここでも弾く）。
    final isOnline = _ref.read(isOnlineProvider);
    if (!isOnline) {
      throw const NetworkFailure('受け取りには接続が必要です');
    }

    final i = _quests.indexWhere((q) => q.id == questId);
    if (i < 0) {
      throw const ServerFailure('クエストが見つかりませんでした');
    }
    final q = _quests[i];
    if (!q.isCompleted) {
      throw const ServerFailure('まだ達成していません');
    }
    if (q.rewardGranted) {
      // 既に付与済み（冪等）。サーバーRPCも idempotency で二重付与しない。
      return q;
    }

    // TODO(本実装 / 信頼境界): サーバーRPC fn_grant_quest_reward(questId, period_start) を呼ぶ。
    //   * user_quests.reward_granted を原子的に true 化し、point_ledger / profiles.gem_balance /
    //     eggs（報酬卵）へ冪等加算するのは**サーバーの責務**。
    //   * クライアントはここで残高を一切書き換えない（表示状態の更新のみ）。
    //   * 失敗時はサーバーが付与せず、クライアントはリトライ可能（二重付与しない）。
    final granted = q.copyWith(rewardGranted: true);
    _quests[i] = granted;
    return granted;
  }
}

/// `user_quests` 1行ぶんの素材（期間つき）。[keepLatestPeriodPerKind] の入出力。
typedef QuestRow = ({
  String defId,
  String userQuestId,
  String period,
  Quest quest,
});

/// 期間が混ざった行から、**種別ごとに一番新しい期間の行だけ**を残す。
///
/// なぜ要るか（2026-09-10）:
///   `user_quests` は `unique(user_id, quest_id, period_start)` で、サーバーの
///   `fn_sync_quests` が毎日1行ずつ増やしていく。以前クライアントは期間で絞らずに
///   全期間分を select していたため、**使った日数だけ同じクエストが画面に並んでいた**
///   （本番実測: 1ユーザーで「30分減らそう」が15行、「今週1000pt」が7行）。
///
/// 通常はサーバー側の `or()` で当期だけに絞れているのでここは素通りする。効くのは
///   * オフラインで `fn_sync_quests` を呼べず、当期が分からないとき
///     → 手元にある中で最新の期間を出す（何も出さないより良い）
///   * 将来サーバー側の絞りが壊れたとき → 画面に重複を出さない
///
/// [period] は 'YYYY-MM-DD' 固定なので、文字列比較がそのまま日付比較になる。
/// 並び順は入力のまま保つ（表示順はサーバーの並びに従う）。
List<QuestRow> keepLatestPeriodPerKind(List<QuestRow> rows) {
  final latest = <QuestKind, String>{};
  for (final r in rows) {
    final cur = latest[r.quest.kind];
    if (cur == null || r.period.compareTo(cur) > 0) {
      latest[r.quest.kind] = r.period;
    }
  }
  return rows.where((r) => r.period == latest[r.quest.kind]).toList();
}

/// Supabase 本実装（信頼境界準拠）。
///
/// 生成（loadQuests 冒頭）は**サーバーRPC `fn_sync_quests`**（当日/当週インスタンスの
/// 冪等生成 / C-2: クライアントは user_quests へ直接 INSERT できない）。
/// 読み取り（loadQuests）は `user_quests`（本人select）×`quest_definitions`（公開select）
/// ×`streaks`（本人select）。進捗は user_quests.progress / is_completed をそのまま表示。
/// **受取はサーバーRPC `fn_grant_quest_reward`**（残高加算はサーバー）。
/// 抽象の [claimReward] は quest_definitions.id を受けるため、内部で user_quests.id に解決する。
class SupabaseQuestRepository implements QuestRepository {
  SupabaseQuestRepository(this._ref, this._client);

  final Ref _ref;
  final SupabaseClient _client;

  /// quest_definitions.id -> user_quests.id（当期インスタンス）のマップ。
  /// loadQuests で構築し、claimReward の RPC 引数解決に使う。
  final Map<String, String> _questDefToUserQuestId = {};

  @override
  Future<QuestsState> loadQuests(EconomyParams params) async {
    final isOnline = _ref.read(isOnlineProvider);
    try {
      // 信頼境界 (C-2): クエストインスタンスの生成はサーバー専管。クライアントは
      //   user_quests へ INSERT できない (列GRANT で剥奪)。当日/当週のインスタンスは
      //   サーバーRPC fn_sync_quests が quest_definitions(is_active) から冪等生成する
      //   (period はサーバー now()+登録TZ 基準)。読み取り前に同期しておく。
      //   オフライン時は同期せず、ローカルに既にある (前回同期済みの) 行だけを表示する。
      // 【2026-09-10 修正】以前はここで**全期間分**の user_quests を読んでいた。
      //   user_quests は unique(user_id, quest_id, period_start) で **1日1行ずつ増える**
      //   設計なので、使った日数だけ同じクエストが画面に並んでいた（本番実測: 1ユーザーで
      //   「30分減らそう」が15行）。当期（今日 / 今週）だけに絞る。
      //
      //   期間の正はサーバー。fn_sync_quests が {daily_period, weekly_period} を返すので
      //   それを使う。**クライアントの時計から日付を作らない**（0005 が意図的に避けている。
      //   端末の日付を変えれば別期間のクエストを引けてしまうため）。
      String? dailyPeriod;
      String? weeklyPeriod;
      if (isOnline) {
        final synced = await _client.rpc('fn_sync_quests');
        final m = (synced as Map?)?.cast<String, Object?>();
        dailyPeriod = m?['daily_period'] as String?;
        weeklyPeriod = m?['weekly_period'] as String?;
      }

      // user_quests に quest_definitions を join（PostgREST のリレーション展開）。
      // period_start は絞り込みとフォールバック判定に使うので必ず取る。
      var query = _client.from('user_quests').select(
            'id, quest_id, kind, period_start, is_completed, reward_granted, progress, '
            'quest_definitions(id, title, description, condition, reward)',
          );
      if (dailyPeriod != null && weeklyPeriod != null) {
        // 当日の daily と当週の weekly だけ。サーバー側で絞るので転送量も増えない。
        query = query.or(
          'and(kind.eq.daily,period_start.eq.$dailyPeriod),'
          'and(kind.eq.weekly,period_start.eq.$weeklyPeriod)',
        );
      }
      final rows = await query;

      // 行を素材にほどく（この時点ではまだ期間が混ざりうる）。
      final parsed = <QuestRow>[];
      for (final raw in (rows as List)) {
        final r = (raw as Map).cast<String, Object?>();
        final def = (r['quest_definitions'] as Map?)?.cast<String, Object?>();
        if (def == null) continue;
        final defId = def['id']! as String;

        final condition = QuestCondition.fromJson(
          ((def['condition'] as Map?) ?? const {}).cast<String, Object?>(),
        );
        final reward = QuestReward.fromJson(
          ((def['reward'] as Map?) ?? const {}).cast<String, Object?>(),
        );
        // 進捗は user_quests.progress（jsonb）の 'value' を採用（評価器 QuestProgressEvaluator と
        // 同一規約）。規約: app_under は **使用分**（予算メーター）、他タイプは達成量。未書込は 0
        // （app_under なら「使用0=バー空=まだ余裕」に描画される / カードが type 別に解釈）。
        final progressMap =
            ((r['progress'] as Map?) ?? const {}).cast<String, Object?>();
        final progress = (progressMap['value'] as num?)?.toInt() ?? 0;

        final QuestRow parsedRow = (
          defId: defId,
          userQuestId: r['id']! as String,
          period: (r['period_start'] as String?) ?? '',
          quest: Quest(
            id: defId,
            kind: QuestKind.fromWire((r['kind'] as String?) ?? 'daily'),
            title: def['title']! as String,
            description: def['description'] as String?,
            condition: condition,
            reward: reward,
            progress: progress,
            isCompleted: r['is_completed'] == true,
            rewardGranted: r['reward_granted'] == true,
          ),
        );
        parsed.add(parsedRow);
      }

      // 二重の安全策（詳細は keepLatestPeriodPerKind のドキュメント）。
      final currentRows = keepLatestPeriodPerKind(parsed);

      _questDefToUserQuestId.clear();
      final quests = <Quest>[];
      for (final p in currentRows) {
        // claimReward は defId から user_quests.id を引く。**当期の行**を入れること
        // （絞る前は最後に来た行＝任意の過去期間が入り、古い行を受け取ろうとしていた）。
        _questDefToUserQuestId[p.defId] = p.userQuestId;
        quests.add(p.quest);
      }

      final streakRow =
          await _client.from('streaks').select().maybeSingle();
      final current = (streakRow?['current_streak'] as num?)?.toInt() ?? 0;
      final longest = (streakRow?['longest_streak'] as num?)?.toInt() ?? 0;

      return QuestsState(
        daily: quests.where((q) => q.kind == QuestKind.daily).toList(),
        weekly: quests.where((q) => q.kind == QuestKind.weekly).toList(),
        streak: StreakState(
          current: current,
          longest: longest,
          tiers: params.streakMultipliers,
        ),
        isOffline: !isOnline,
      );
    } catch (e, st) {
      Log.e('loadQuests failed', error: e, stack: st);
      rethrow;
    }
  }

  @override
  Future<Quest> claimReward(String questId) async {
    if (!_ref.read(isOnlineProvider)) {
      throw const NetworkFailure('受け取りには接続が必要です');
    }
    final userQuestId = _questDefToUserQuestId[questId];
    if (userQuestId == null) {
      throw const ServerFailure('クエストが見つかりませんでした');
    }
    try {
      // 信頼境界 (C-1): 達成判定はサーバー権威。クライアントの is_completed は信用されない。
      //   付与前に fn_evaluate_quest でサーバーが quest_definitions.condition と
      //   サーバー権威データ (usage_daily/eggs/streaks/ledger) から達成を確定する。
      //   未達なら is_completed は立たず、続く fn_grant_quest_reward が再判定で拒否する。
      await _client
          .rpc('fn_evaluate_quest', params: {'p_user_quest_id': userQuestId});
      // 残高加算・卵生成・冪等・達成の最終再判定はすべてサーバー。クライアントは要求のみ。
      await _client
          .rpc('fn_grant_quest_reward', params: {'p_user_quest_id': userQuestId});
      // 受取後の状態を再取得して返す（信頼境界: サーバー確定値を採用）。
      final updated = await loadQuests(
        await _ref.read(economyParamsProvider.future),
      );
      return updated.all.firstWhere(
        (q) => q.id == questId,
        orElse: () => throw const ServerFailure('受け取り後の状態取得に失敗しました'),
      );
    } on PostgrestException catch (e, st) {
      Log.e('fn_grant_quest_reward failed: ${e.code}', error: e, stack: st);
      if (e.message.contains('quest_not_completed')) {
        throw const ServerFailure('まだ達成していません');
      }
      throw const ServerFailure('受け取りに失敗しました');
    }
  }
}

/// クエストリポジトリの DI（ARCHITECTURE §1-3）。テストでは override 可能。
/// 実バックエンドを使う設定なら本実装、未設定/PoC/FORCE_MOCK時はモックにフォールバック
/// （`hasSupabase` ではなく `useSupabase`: プレビューの受取要求が本番の報酬付与
/// RPC を叩かないようにする / daily_submission.dart:129-131）。
final questRepositoryProvider = Provider<QuestRepository>((ref) {
  if (Env.useSupabase) {
    return SupabaseQuestRepository(ref, ref.read(supabaseClientProvider));
  }
  return MockQuestRepository(ref);
});

/// クエスト画面の状態を供給する FutureProvider（経済パラメータ依存）。
final questsStateProvider = FutureProvider<QuestsState>((ref) async {
  final params = await ref.watch(economyParamsProvider.future);
  final repo = ref.read(questRepositoryProvider);
  return repo.loadQuests(params);
});

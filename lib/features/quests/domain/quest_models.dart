/// クエスト・ストリークまわりのドメインモデル（ARCHITECTURE §1-2 domain / S7,S14）。
///
/// 信頼境界（ARCHITECTURE §0-2 / §2-3）:
///   * クエストの自動生成元は `quest_definitions`（読み取り公開マスタ / rule_json=condition）。
///   * 進捗（[QuestProgress]）はローカルでも判定できる純粋ロジックとして持つが、
///     **報酬付与（pt/卵/ジェムの残高反映）はサーバーRPC `fn_grant_quest_reward`
///     （security definer / 原子的・冪等）の責務**。クライアントは「受取要求の口」
///     だけを持ち、抽選・残高加算は一切行わない。
///   * ストリーク（[StreakState]）は `streaks` テーブルがサーバーSSOT。表示は取得値ベース。
library;

import '../../../core/constants/economy.dart';

/// クエスト種別（migration: quest_kind enum）。
enum QuestKind {
  daily,
  weekly;

  String get wire => name;

  static QuestKind fromWire(String s) =>
      s == 'weekly' ? QuestKind.weekly : QuestKind.daily;

  String get label => switch (this) {
        QuestKind.daily => 'デイリー',
        QuestKind.weekly => 'ウィークリー',
      };
}

/// 報酬の種類（SCREEN_FLOWS §5: pt / 卵 / ジェム）。
/// 固定報酬であり、ストリーク倍率は掛けない（S14: 倍率は基礎ptのみ）。
class QuestReward {
  /// 付与ポイント（固定 / 倍率非適用 / S14）。
  final int points;

  /// 付与ジェム（S7 主たる無料入手源はウィークリー）。
  final int gems;

  /// 付与する卵のレアリティ（'normal' 等 / null=卵なし）。
  /// 抽選・実体生成はサーバーRPCの責務（クライアントは表示のみ）。
  final String? eggRarity;

  const QuestReward({this.points = 0, this.gems = 0, this.eggRarity});

  /// 何も報酬が無い（防御的デフォルト）。
  bool get isEmpty => points == 0 && gems == 0 && eggRarity == null;

  factory QuestReward.fromJson(Map<String, Object?> j) => QuestReward(
        points: (j['points'] as num?)?.toInt() ?? 0,
        gems: (j['gems'] as num?)?.toInt() ?? 0,
        eggRarity: j['egg_rarity'] as String?,
      );
}

/// クエスト達成条件の型（quest_definitions.condition の rule_json）。
///
/// MVPで扱う代表条件:
///   * `app_under`   … 対象アプリの利用が [target] 分未満（削減チャレンジ）。
///   * `reduce_total`… 対象SNS合計の削減が [target] 分以上。
///   * `streak_keep` … その日のストリークを維持（達成 or 削減プラス / S14）。
///   * `hatch_count` … 期間内に [target] 個孵化。
///   * `points_earn` … 期間内に基礎ptを累計 [target] 獲得。
/// 未知typeは安全に「進捗判定不能=未達」に倒す（落とさない）。
enum QuestConditionType {
  appUnder,
  reduceTotal,
  streakKeep,
  hatchCount,
  pointsEarn,
  unknown;

  static QuestConditionType fromWire(String s) => switch (s) {
        'app_under' => QuestConditionType.appUnder,
        'reduce_total' => QuestConditionType.reduceTotal,
        'streak_keep' => QuestConditionType.streakKeep,
        'hatch_count' => QuestConditionType.hatchCount,
        'points_earn' => QuestConditionType.pointsEarn,
        _ => QuestConditionType.unknown,
      };
}

/// 達成条件（rule_json をパースした表現）。
class QuestCondition {
  final QuestConditionType type;

  /// 目標値（分 / 回数 / pt）。type により意味が変わる。
  final int target;

  /// 対象パッケージ（app_under のみ。null=合計）。
  final String? package;

  const QuestCondition({
    required this.type,
    required this.target,
    this.package,
  });

  factory QuestCondition.fromJson(Map<String, Object?> j) => QuestCondition(
        type: QuestConditionType.fromWire((j['type'] as String?) ?? 'unknown'),
        target: (j['target'] as num?)?.toInt() ??
            (j['minutes'] as num?)?.toInt() ??
            0,
        package: j['package'] as String?,
      );
}

/// クエスト1件（定義 + そのユーザーの当期インスタンス進捗をまとめた表示用）。
///
/// progress/target は「進捗バー」と「達成判定」に使う。達成しても**受取（claim）は
/// 別操作**で、受取の確定はサーバーRPC（残高反映）。二重受取を防ぐため
/// [rewardGranted] を持つ（migration: user_quests.reward_granted）。
class Quest {
  /// quest_definitions.id（'daily_reduce_30' 等）。
  final String id;
  final QuestKind kind;
  final String title;
  final String? description;
  final QuestCondition condition;
  final QuestReward reward;

  /// 現在の進捗量（condition.type の単位）。
  final int progress;

  /// 達成条件を満たしたか（progress >= target）。
  final bool isCompleted;

  /// 報酬を受取済みか（サーバーで付与済み / 二重受取防止）。
  final bool rewardGranted;

  const Quest({
    required this.id,
    required this.kind,
    required this.title,
    this.description,
    required this.condition,
    required this.reward,
    required this.progress,
    required this.isCompleted,
    required this.rewardGranted,
  });

  /// 進捗率 0.0〜1.0（バー表示）。target<=0 は完了扱い。
  double get progressRatio {
    final t = condition.target;
    if (t <= 0) return isCompleted ? 1.0 : 0.0;
    return (progress / t).clamp(0.0, 1.0);
  }

  /// 「受け取る」CTAを出せる状態（達成済み・未受取）。
  bool get isClaimable => isCompleted && !rewardGranted;

  Quest copyWith({
    int? progress,
    bool? isCompleted,
    bool? rewardGranted,
  }) =>
      Quest(
        id: id,
        kind: kind,
        title: title,
        description: description,
        condition: condition,
        reward: reward,
        progress: progress ?? this.progress,
        isCompleted: isCompleted ?? this.isCompleted,
        rewardGranted: rewardGranted ?? this.rewardGranted,
      );
}

/// ストリーク状態（migration: streaks / S14）。サーバーSSOT・表示は取得値ベース。
class StreakState {
  /// 現在の連続達成日数。
  final int current;

  /// 最長記録（プロフィール統計にも表示）。
  final int longest;

  /// 倍率テーブル（SSOT / EconomyParams 経由）。表示の倍率はここから算出する。
  final List<StreakTier> tiers;

  const StreakState({
    required this.current,
    required this.longest,
    required this.tiers,
  });

  /// 現在の倍率（×1.0〜×2.0 / S14: 間の日数は直下段）。
  double get multiplier => StreakTier.multiplierFor(current, tiers);

  /// 次のマイルストーン段（7日/30日等）。最高段に達していれば null。
  StreakTier? get nextTier {
    for (final t in tiers) {
      if (current < t.days) return t;
    }
    return null;
  }

  /// 次マイルストーンまでの残り日数（無ければ null）。
  int? get daysToNextTier {
    final n = nextTier;
    return n == null ? null : (n.days - current).clamp(0, n.days);
  }
}

/// クエスト画面のスナップショット（SCREEN_FLOWS §5）。
class QuestsState {
  /// デイリークエスト一覧。
  final List<Quest> daily;

  /// ウィークリークエスト一覧。
  final List<Quest> weekly;

  /// ストリーク状態（ヘッダ表示）。
  final StreakState streak;

  /// オフライン中か（受取ボタンをグレーアウト / S8）。
  final bool isOffline;

  const QuestsState({
    required this.daily,
    required this.weekly,
    required this.streak,
    required this.isOffline,
  });

  /// 全クエスト（デイリー+ウィークリー）。
  List<Quest> get all => [...daily, ...weekly];

  /// クエストが1件も無い（生成前 / 空状態 / SCREEN_FLOWS §5）。
  bool get isEmpty => daily.isEmpty && weekly.isEmpty;

  /// すべて達成済み（全クリア祝福の空状態 / SCREEN_FLOWS §5）。
  bool get isAllCompleted => !isEmpty && all.every((q) => q.isCompleted);

  /// 受取可能なクエスト数（バッジ表示等）。
  int get claimableCount => all.where((q) => q.isClaimable).length;
}

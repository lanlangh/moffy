/// クエスト進捗判定の純粋ロジック（ARCHITECTURE §1-2 domain / 単体テスト対象）。
///
/// 信頼境界（ARCHITECTURE §2-3）:
///   * ここで判定するのは「進捗バー表示」と「受取可能かのUI判定」のための**暫定値**。
///   * 達成しても残高は動かさない。報酬付与の確定はサーバーRPC
///     `fn_grant_quest_reward`（冪等）の責務。本ロジックは台帳に一切書かない。
///   * 生成ルール（rule_json=condition）準拠の抽象であり、マジックナンバーを持たない
///     （目標値は [QuestCondition.target]、しきい値は EconomyParams 経由）。
library;

import 'quest_models.dart';

/// 進捗判定に必要な「その期間の実績」入力（純粋データ）。
///
/// 値はリポジトリ（利用統計/サーバー/Driftキャッシュ）が集めてここへ渡す。
/// 本クラスは I/O を持たず、テスト可能な純粋関数に閉じる。
class QuestMetrics {
  /// 対象アプリ別の利用分（app_under 判定用）。
  final Map<String, int> perAppMinutes;

  /// 対象SNS合計の削減分（reduce_total 判定用 / 基準値-今日, 下限0）。
  final int reducedMinutes;

  /// その日のストリークが維持されたか（streak_keep 判定用 / S14条件）。
  final bool streakKept;

  /// 期間内の孵化回数（hatch_count 判定用）。
  final int hatchCount;

  /// 期間内に獲得した基礎pt累計（points_earn 判定用）。
  final int earnedPoints;

  const QuestMetrics({
    this.perAppMinutes = const {},
    this.reducedMinutes = 0,
    this.streakKept = false,
    this.hatchCount = 0,
    this.earnedPoints = 0,
  });
}

/// クエスト進捗を判定する純粋関数群。
abstract final class QuestProgressEvaluator {
  /// [definition]（progress/isCompleted は未確定でも可）に [metrics] を当てて
  /// 進捗量と達成フラグを再計算した新しい [Quest] を返す。
  ///
  /// rewardGranted は変更しない（受取はサーバー確定。ここでは判定のみ）。
  static Quest evaluate(Quest definition, QuestMetrics metrics) {
    final c = definition.condition;
    final progress = _progressFor(c, metrics);
    // target<=0 の防御: 0目標は「常に達成」とみなさず未達に倒す（不正定義で誤付与しない）。
    final completed = c.target > 0 && progress >= c.target;
    return definition.copyWith(progress: progress, isCompleted: completed);
  }

  /// condition.type ごとの現在進捗量を返す（単位は type 依存）。
  static int _progressFor(QuestCondition c, QuestMetrics m) {
    switch (c.type) {
      case QuestConditionType.appUnder:
        // 「対象アプリの利用が target 分未満」= 削減チャレンジ。
        // 進捗バーは「target に対してどれだけ下回れたか」を 0..target で表す。
        // 例: 目標30分未満 / 実利用10分 → 進捗20（=達成方向に20分の余裕）。
        final used = c.package == null ? 0 : (m.perAppMinutes[c.package] ?? 0);
        final headroom = c.target - used;
        return headroom < 0 ? 0 : headroom.clamp(0, c.target);
      case QuestConditionType.reduceTotal:
        return m.reducedMinutes < 0 ? 0 : m.reducedMinutes;
      case QuestConditionType.streakKeep:
        // 維持できていれば target 到達（=1日キープで達成）。
        return m.streakKept ? c.target : 0;
      case QuestConditionType.hatchCount:
        return m.hatchCount < 0 ? 0 : m.hatchCount;
      case QuestConditionType.pointsEarn:
        return m.earnedPoints < 0 ? 0 : m.earnedPoints;
      case QuestConditionType.unknown:
        // 未知条件は進捗0（未達）に倒す。誤って達成→受取要求が走らないように。
        return 0;
    }
  }
}

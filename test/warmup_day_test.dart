import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/home/data/warmup_tracker.dart';

/// ウォームアップ Day 決定（F-01 / S1）の純粋ロジックテスト。
///
/// 付与の正はサーバー（冪等キーは生涯1回）だが、「いつ Day1/Day2 を呼ぶか」の
/// トリガー判断はクライアントのローカル初回起動日から決める。
///
/// 0018 で Day2 の条件を「翌日」から「初回起動日より後に最初に開いた日」へ広げた
/// （docs/design/EGG_PACING_DESIGN.md §3-3）。以前は翌日に開かないと 2日目のボーナスが
/// 永久に来ず、初日の 200pt で止まった卵が 83 個あった。
void main() {
  group('warmupDayFor', () {
    test('初回起動当日は Day1', () {
      final first = DateTime(2026, 6, 23, 9, 0);
      expect(warmupDayFor(first, DateTime(2026, 6, 23, 23, 59)), 1);
    });

    test('翌日は Day2', () {
      final first = DateTime(2026, 6, 23, 9, 0);
      expect(warmupDayFor(first, DateTime(2026, 6, 24, 0, 1)), 2);
    });

    test('0018: 3日後でも1か月後でも、まだ受け取っていなければ Day2', () {
      final first = DateTime(2026, 6, 23);
      expect(warmupDayFor(first, DateTime(2026, 6, 25)), 2);
      expect(warmupDayFor(first, DateTime(2026, 7, 23)), 2);
    });

    test('Day2 を受け取り済みならウォームアップ対象外（null）', () {
      final first = DateTime(2026, 6, 23);
      expect(
        warmupDayFor(first, DateTime(2026, 6, 24), day2Claimed: true),
        isNull,
      );
      expect(
        warmupDayFor(first, DateTime(2026, 7, 1), day2Claimed: true),
        isNull,
      );
    });

    test('受取済みフラグがあっても初回起動当日は Day1（当日は Day1 の再試行を妨げない）', () {
      final first = DateTime(2026, 6, 23);
      expect(
        warmupDayFor(first, DateTime(2026, 6, 23, 12), day2Claimed: true),
        1,
      );
    });

    test('時刻成分が違っても暦日の差で判定する（同日深夜→朝でも Day1）', () {
      final first = DateTime(2026, 6, 23, 23, 30);
      expect(warmupDayFor(first, DateTime(2026, 6, 23, 0, 10)), 1);
    });

    test('端末時刻が初回起動より巻き戻っても安全側で Day1（負の経過日）', () {
      final first = DateTime(2026, 6, 23);
      expect(warmupDayFor(first, DateTime(2026, 6, 22)), 1);
    });

    test('月またぎでも暦日差で正しく判定する', () {
      final first = DateTime(2026, 6, 30);
      expect(warmupDayFor(first, DateTime(2026, 6, 30)), 1);
      expect(warmupDayFor(first, DateTime(2026, 7, 1)), 2);
      expect(warmupDayFor(first, DateTime(2026, 7, 2)), 2);
    });
  });
}

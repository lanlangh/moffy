import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/features/home/data/warmup_tracker.dart';

/// ウォームアップ Day 決定（F-01 / S1）の純粋ロジックテスト。
///
/// 付与の正はサーバー（冪等キーは生涯1回）だが、「いつ Day1/Day2 を呼ぶか」の
/// トリガー判断はクライアントのローカル初回起動日から決める。その境界（当日=Day1 /
/// 翌日=Day2 / 2日以降=対象外）と、時刻成分・端末時刻巻き戻りの安全側挙動を担保する。
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

    test('2日目以降はウォームアップ対象外（null）', () {
      final first = DateTime(2026, 6, 23);
      expect(warmupDayFor(first, DateTime(2026, 6, 25)), isNull);
      expect(warmupDayFor(first, DateTime(2026, 7, 1)), isNull);
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
      expect(warmupDayFor(first, DateTime(2026, 7, 2)), isNull);
    });
  });
}

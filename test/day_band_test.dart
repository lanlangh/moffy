import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/usage/day_band.dart';

/// 1日の評価（◎/○/△/計測なし）の純粋ロジック（0018 / docs/design/EGG_PACING_DESIGN.md §2）。
///
/// サーバー `fn_finalize_day` と同じ式であることが要点（端末は「きょうのペース」の暫定表示にだけ
/// 使うが、式が食い違うと「◎ペースと出ていたのに ○ で確定した」が起きる）。
/// §2-2 の判定式と §2-4 の iOS しきい値表を総当たりで固定する。
void main() {
  const bands = DailyBands.defaults; // ◎: max(30, R/2) / ○: max(60, R*3/4)

  DayBand band(int minutes, int usual) => DayBandCalculator.evaluate(
        minutes: minutes,
        usualMinutes: usual,
        bands: bands,
      );

  group('判定式（§2-2）', () {
    test('R=120: 60分以内は ◎、90分以内は ○、それ以上は △', () {
      expect(band(0, 120), DayBand.great);
      expect(band(60, 120), DayBand.great);
      expect(band(61, 120), DayBand.good);
      expect(band(90, 120), DayBand.good);
      expect(band(91, 120), DayBand.poor);
      expect(band(120, 120), DayBand.poor);
    });

    test('絶対ライン: ふだんから少ない人（R=30/60）でも 30分以内なら ◎、60分以内なら ○', () {
      expect(band(30, 30), DayBand.great); // 半分=15 より 30分以内が効く
      expect(band(31, 30), DayBand.good);
      expect(band(60, 30), DayBand.good); // 3/4=22 より 60分以内が効く
      expect(band(61, 30), DayBand.poor);
      expect(band(30, 60), DayBand.great);
      expect(band(45, 60), DayBand.good); // 3/4=45
      expect(band(46, 60), DayBand.good); // 絶対ライン 60
      expect(band(61, 60), DayBand.poor);
    });

    test('計測なしは無条件に unmeasured', () {
      expect(
        DayBandCalculator.evaluate(
          minutes: 0,
          usualMinutes: 120,
          bands: bands,
          measured: false,
        ),
        DayBand.unmeasured,
      );
    });

    test('上限（◎/○ になる分）は R から引ける（「あと N 分の余裕」用）', () {
      expect(DayBandCalculator.greatLimit(120, bands), 60);
      expect(DayBandCalculator.goodLimit(120, bands), 90);
      expect(DayBandCalculator.greatLimit(30, bands), 30);
      expect(DayBandCalculator.goodLimit(30, bands), 60);
      expect(DayBandCalculator.greatLimit(300, bands), 150);
      expect(DayBandCalculator.goodLimit(300, bands), 225);
    });
  });

  group('iOS のしきい値との対応（§2-4 の表を総当たり）', () {
    // 記録される値は「最大到達しきい値」（0 = 15分未満）。
    const thresholds = [0, 15, 30, 45, 60, 90, 120, 150, 180, 240, 300];
    const table = <int, Map<int, DayBand>>{
      30: {
        0: DayBand.great, 15: DayBand.great, 30: DayBand.great, //
        45: DayBand.good, 60: DayBand.good, //
        90: DayBand.poor, 120: DayBand.poor, 150: DayBand.poor,
        180: DayBand.poor, 240: DayBand.poor, 300: DayBand.poor,
      },
      60: {
        0: DayBand.great, 15: DayBand.great, 30: DayBand.great, //
        45: DayBand.good, 60: DayBand.good, //
        90: DayBand.poor, 120: DayBand.poor, 150: DayBand.poor,
        180: DayBand.poor, 240: DayBand.poor, 300: DayBand.poor,
      },
      120: {
        0: DayBand.great, 15: DayBand.great, 30: DayBand.great,
        45: DayBand.great, 60: DayBand.great, //
        90: DayBand.good, //
        120: DayBand.poor, 150: DayBand.poor, 180: DayBand.poor,
        240: DayBand.poor, 300: DayBand.poor,
      },
      180: {
        0: DayBand.great, 15: DayBand.great, 30: DayBand.great,
        45: DayBand.great, 60: DayBand.great, 90: DayBand.great, //
        120: DayBand.good, //
        150: DayBand.poor, 180: DayBand.poor, 240: DayBand.poor,
        300: DayBand.poor,
      },
      300: {
        0: DayBand.great, 15: DayBand.great, 30: DayBand.great,
        45: DayBand.great, 60: DayBand.great, 90: DayBand.great,
        120: DayBand.great, 150: DayBand.great, //
        180: DayBand.good, //
        240: DayBand.poor, 300: DayBand.poor,
      },
    };

    for (final entry in table.entries) {
      test('R=${entry.key}', () {
        for (final m in thresholds) {
          expect(
            band(m, entry.key),
            entry.value[m],
            reason: 'R=${entry.key} 記録値=$m',
          );
        }
      });
    }
  });

  group('pt（§3-1）', () {
    test('◎100 / ○70 / △15 / 計測なし0', () {
      expect(DayBandCalculator.pointsFor(DayBand.great, bands), 100);
      expect(DayBandCalculator.pointsFor(DayBand.good, bands), 70);
      expect(DayBandCalculator.pointsFor(DayBand.poor, bands), 15);
      expect(DayBandCalculator.pointsFor(DayBand.unmeasured, bands), 0);
    });

    test('1日上限でクランプ（値だけで調整できる）', () {
      expect(DayBandCalculator.pointsFor(DayBand.great, bands, cap: 80), 80);
      expect(DayBandCalculator.pointsFor(DayBand.poor, bands, cap: 80), 15);
    });

    test('app_config の値で差し替えられる（△を 0 にする案 / §8）', () {
      final custom = DailyBands.fromJson({
        'great': {'abs_min': 30, 'ratio': 0.5, 'points': 100},
        'good': {'abs_min': 60, 'ratio': 0.75, 'points': 70},
        'poor': {'points': 0},
      });
      expect(DayBandCalculator.pointsFor(DayBand.poor, custom), 0);
      // 欠けたキーは既定へ倒す。
      final partial = DailyBands.fromJson({'poor': {'points': 5}});
      expect(partial.great.points, 100);
      expect(partial.poorPoints, 5);
    });

    test('wire との相互変換（サーバーの band 文字列）', () {
      for (final b in DayBand.values) {
        expect(DayBand.fromWire(b.wire), b);
      }
      expect(DayBand.fromWire('nope'), DayBand.unmeasured);
      expect(DayBand.fromWire(null), DayBand.unmeasured);
    });
  });

  group('EconomyParams.fromConfig（0018 のキー）', () {
    test('daily_bands / usual_minutes_* / egg_thresholds.stages を読む', () {
      final p = EconomyParams.fromConfig({
        'daily_bands': {
          'great': {'abs_min': 20, 'ratio': 0.4, 'points': 90},
          'good': {'abs_min': 50, 'ratio': 0.7, 'points': 60},
          'poor': {'points': 10},
        },
        'usual_minutes_default': 90,
        'usual_minutes_choices': [300, 30, 60],
        'egg_thresholds': {
          'crack1': 100,
          'crack2': 250,
          'stages': [0, 100, 200, 300, 500],
          'hatch': 500,
        },
        'daily_point_cap': 100,
        'warmup_grants': {'day1': 300, 'day2': 200},
        'streak_multipliers': [
          {'days': 1, 'mult': 1.0},
        ],
      });
      expect(p.dailyBands.great.points, 90);
      expect(p.dailyBands.poorPoints, 10);
      expect(p.usualMinutesDefault, 90);
      expect(p.usualMinutesChoices, [30, 60, 300]); // 昇順に整える
      expect(p.eggThresholds.stages, [0, 100, 200, 300, 500]);
      expect(p.dailyPointCap, 100);
      expect(p.warmupGrants.day1, 300);
      expect(StreakTier.multiplierFor(30, p.streakMultipliers), 1.0);
    });

    test('キーが無ければ既定（migration seed と同じ値）', () {
      final p = EconomyParams.fromConfig(const {});
      expect(p.dailyBands.great.points, 100);
      expect(p.usualMinutesDefault, 120);
      expect(p.usualMinutesChoices, [30, 60, 120, 180, 300]);
      expect(p.dailyPointCap, 100);
      expect(p.warmupGrants.day1, 300);
      expect(p.warmupGrants.day2, 200);
      expect(p.streakMultipliers, StreakTier.flat);
    });

    test('不正な選択肢（0 以下・数値でない）は既定へ倒す', () {
      expect(
        EconomyParams.fromConfig({
          'usual_minutes_choices': [30, 0, 60],
        }).usualMinutesChoices,
        [30, 60, 120, 180, 300],
      );
      expect(
        EconomyParams.fromConfig({'usual_minutes_choices': 'x'}).usualMinutesChoices,
        [30, 60, 120, 180, 300],
      );
    });
  });
}

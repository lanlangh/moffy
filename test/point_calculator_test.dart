import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/usage/point_calculator.dart';
import 'package:moffy/core/usage/usage_models.dart';

/// PointCalculator / Baseline の単体テスト。
/// 受け入れ §5-1（S1/S2/S4）と §4-5 の数値を検証する（QA引き継ぎ観点）。
void main() {
  const params = EconomyParams.defaults;
  const calc = ExactMinutesPointCalculator();

  DailyUsage usage(int minutes) => DailyUsage(
        date: DateTime(2026, 6, 19),
        perAppMinutes: {'com.x': minutes},
        totalMinutes: minutes,
        mode: UsageMode.exactMinutes,
      );

  Baseline baseline(int applied) => Baseline(
        date: DateTime(2026, 6, 19),
        rawAverageMinutes: applied.toDouble(),
        appliedMinutes: applied,
        sampleDays: 7,
        stage: BaselineStage.confirmed,
      );

  group('calculateBasePoints', () {
    test('削減プラスは 1分=1pt（§4-5）', () {
      final pt = calc.calculateBasePoints(
        today: usage(60),
        baseline: baseline(120),
        params: params,
      );
      expect(pt, 60); // 120 - 60 = 60分削減
    });

    test('S2: 利用が基準超過でもマイナスにならず 0pt', () {
      final pt = calc.calculateBasePoints(
        today: usage(200),
        baseline: baseline(120),
        params: params,
      );
      expect(pt, 0);
    });

    test('S4: 異常値（24h超）は加点しない', () {
      final anomaly = DailyUsage(
        date: DateTime(2026, 6, 19),
        perAppMinutes: const {'com.x': 1500},
        totalMinutes: 1500,
        mode: UsageMode.exactMinutes,
        isAnomaly: true,
      );
      final pt = calc.calculateBasePoints(
        today: anomaly,
        baseline: baseline(120),
        params: params,
      );
      expect(pt, 0);
    });
  });

  group('applyStreakAndCap', () {
    test('S14: 7日連続は ×1.5', () {
      final pt = calc.applyStreakAndCap(
        basePoints: 100,
        currentStreakDays: 7,
        params: params,
      );
      expect(pt, 150);
    });

    test('S14: 間の日数は直下段（5日目=×1.2）', () {
      final pt = calc.applyStreakAndCap(
        basePoints: 100,
        currentStreakDays: 5,
        params: params,
      );
      expect(pt, 120);
    });

    // F-02 補強: 「今日を含めた到達段」で倍率を引く解釈をクライアント側でも固定する。
    //   サーバー fn_finalize_day は v_reduced>0 のとき streak_multiplier(v_streak_cur + 1)
    //   を使う（off-by-one 修正）。クライアントは currentStreakDays に「今日を含めた日数」
    //   を渡す前提で、3日=×1.2 / 7日=×1.5 の段がサーバーと一致する。
    test('S14/F-02: 到達3日目ちょうどは ×1.2（今日含む解釈・サーバーと一致）', () {
      final pt = calc.applyStreakAndCap(
        basePoints: 100,
        currentStreakDays: 3, // 継続3日目（今日を含む）= 到達段 days:3
        params: params,
      );
      expect(pt, 120);
    });

    test('S14/F-02: 到達2日目は ×1.0（まだ days:3 段に未達）', () {
      final pt = calc.applyStreakAndCap(
        basePoints: 100,
        currentStreakDays: 2, // 継続2日目（今日を含む）= 直下段 days:1
        params: params,
      );
      expect(pt, 100);
    });

    test('S14/F-02: 到達7日目ちょうどは ×1.5', () {
      final pt = calc.applyStreakAndCap(
        basePoints: 100,
        currentStreakDays: 7,
        params: params,
      );
      expect(pt, 150);
    });

    test('S4: 倍率適用後でも 1日上限480ptでクランプ', () {
      final pt = calc.applyStreakAndCap(
        basePoints: 400,
        currentStreakDays: 30, // ×2.0 -> 800 だが 480 上限
        params: params,
      );
      expect(pt, 480);
    });
  });

  group('Baseline.compute', () {
    test('S1: データ0〜1日は warmup', () {
      final b = Baseline.compute(
        forDate: DateTime(2026, 6, 19),
        history: const [],
        params: params,
      );
      expect(b.stage, BaselineStage.warmup);
      expect(b.appliedMinutes, params.baselineFloorMinutes); // 安全側 floor
    });

    test('S1: データ2〜6日は provisional（取得日平均）', () {
      final hist = [usage(100), usage(140)]; // 平均120
      final b = Baseline.compute(
        forDate: DateTime(2026, 6, 19),
        history: hist,
        params: params,
      );
      expect(b.stage, BaselineStage.provisional);
      expect(b.appliedMinutes, 120);
    });

    test('§4-5: 基準値の下限30分クランプ（低利用ユーザーの0pt詰み防止）', () {
      final hist = [usage(5), usage(5)]; // 平均5分 -> floor 30
      final b = Baseline.compute(
        forDate: DateTime(2026, 6, 19),
        history: hist,
        params: params,
      );
      expect(b.appliedMinutes, 30);
    });

    test('S11: 7日以上は confirmed（直近7日のみ）', () {
      final hist = List.generate(10, (_) => usage(120));
      final b = Baseline.compute(
        forDate: DateTime(2026, 6, 19),
        history: hist,
        params: params,
      );
      expect(b.stage, BaselineStage.confirmed);
      expect(b.sampleDays, 7); // window=7 に絞られる
      expect(b.appliedMinutes, 120);
    });
  });
}

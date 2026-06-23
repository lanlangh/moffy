import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';

/// 卵の成長段階（§4-5: 0/100/250/500pt）と進捗計算の単体テスト。
/// しきい値は EconomyParams（SSOT）経由で参照することを担保する。
void main() {
  const params = EconomyParams.defaults; // crack1=100 / crack2=250 / hatch=500

  Egg eggWith(int pts) => Egg(
        id: 'e',
        rarity: EggRarity.normal,
        growthPoints: pts,
        location: EggLocation.incubating,
        slotIndex: 1,
        isActive: true,
        acquiredSource: 'standard',
      );

  group('EggGrowthStage.of（§4-5 ヒビ段階）', () {
    test('0〜99pt は intact', () {
      expect(EggGrowthStage.of(0, params), EggGrowthStage.intact);
      expect(EggGrowthStage.of(99, params), EggGrowthStage.intact);
    });

    test('100〜249pt は crack1（ヒビ①）', () {
      expect(EggGrowthStage.of(100, params), EggGrowthStage.crack1);
      expect(EggGrowthStage.of(249, params), EggGrowthStage.crack1);
    });

    test('250〜499pt は crack2（ヒビ②）', () {
      expect(EggGrowthStage.of(250, params), EggGrowthStage.crack2);
      expect(EggGrowthStage.of(499, params), EggGrowthStage.crack2);
    });

    test('500pt 以上は ready（孵化可能）', () {
      expect(EggGrowthStage.of(500, params), EggGrowthStage.ready);
      expect(EggGrowthStage.of(700, params), EggGrowthStage.ready);
    });
  });

  group('Egg 進捗・孵化判定', () {
    test('progress は 0.0〜1.0 にクランプ', () {
      expect(eggWith(0).progress(params), 0.0);
      expect(eggWith(250).progress(params), 0.5);
      expect(eggWith(500).progress(params), 1.0);
      expect(eggWith(800).progress(params), 1.0); // 超過もクランプ
    });

    test('remaining は孵化まで残りpt（下限0）', () {
      expect(eggWith(320).remaining(params), 180);
      expect(eggWith(500).remaining(params), 0);
      expect(eggWith(600).remaining(params), 0);
    });

    test('canHatch は 500pt 到達で true', () {
      expect(eggWith(499).canHatch(params), isFalse);
      expect(eggWith(500).canHatch(params), isTrue);
    });

    test('isNearHatch は残50pt以内かつ未到達（孵化間近の微発光トリガ）', () {
      expect(eggWith(450).isNearHatch(params), isTrue); // 残50
      expect(eggWith(470).isNearHatch(params), isTrue); // 残30
      expect(eggWith(449).isNearHatch(params), isFalse); // 残51
      expect(eggWith(500).isNearHatch(params), isFalse); // 既に到達
    });
  });

  group('EggsState（S6 アクティブ卵は1枠のみ）', () {
    EggsState state(List<Egg?> slots, List<Egg> storage) => EggsState(
          incubatorSlots: slots,
          storage: storage,
          pooledPoints: 0,
          isOffline: false,
          params: params,
        );

    test('activeEgg は is_active な育成枠の卵', () {
      final active = eggWith(100);
      final s = state([active, null, null], const []);
      expect(s.activeEgg?.id, active.id);
    });

    test('育成枠が全て空なら hasNoIncubating', () {
      final s = state([null, null, null], [eggWith(0)]);
      expect(s.hasNoIncubating, isTrue);
      expect(s.isCompletelyEmpty, isFalse); // 保管にはある
    });

    test('育成・保管とも空なら isCompletelyEmpty', () {
      final s = state([null, null, null], const []);
      expect(s.isCompletelyEmpty, isTrue);
    });
  });
}

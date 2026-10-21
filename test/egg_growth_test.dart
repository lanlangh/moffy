import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/widgets/egg_art.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';

/// 卵の成長段階（0018: 5段階 0/100/200/300/500pt ＋ S4「強まる」400pt）と進捗計算の単体テスト。
/// しきい値は EconomyParams（SSOT）経由で参照することを担保する。
void main() {
  const params = EconomyParams.defaults; // stages=[0,100,200,300,500] / hatch=500
  const t = EggThresholds.defaults;

  Egg eggWith(int pts) => Egg(
        id: 'e',
        rarity: EggRarity.normal,
        growthPoints: pts,
        location: EggLocation.incubating,
        slotIndex: 1,
        isActive: true,
        acquiredSource: 'standard',
      );

  group('EggGrowthStage.of（0018 5段階）', () {
    test('0〜99pt は blank（しろいたまご）', () {
      expect(EggGrowthStage.of(0, params), EggGrowthStage.blank);
      expect(EggGrowthStage.of(99, params), EggGrowthStage.blank);
    });

    test('100〜199pt は pattern（もよう）', () {
      expect(EggGrowthStage.of(100, params), EggGrowthStage.pattern);
      expect(EggGrowthStage.of(199, params), EggGrowthStage.pattern);
    });

    test('200〜299pt は crack（ヒビ）', () {
      expect(EggGrowthStage.of(200, params), EggGrowthStage.crack);
      expect(EggGrowthStage.of(299, params), EggGrowthStage.crack);
    });

    test('300〜499pt は glow（ひかり）、400pt から「強まる」', () {
      expect(EggGrowthStage.of(300, params), EggGrowthStage.glow);
      expect(EggGrowthStage.of(499, params), EggGrowthStage.glow);
      expect(EggGrowthStage.isStrongGlow(399, t), isFalse);
      expect(EggGrowthStage.isStrongGlow(400, t), isTrue);
      expect(EggGrowthStage.isStrongGlow(499, t), isTrue);
      expect(EggGrowthStage.isStrongGlow(500, t), isFalse); // ready は別段階
    });

    test('500pt 以上は ready（うまれる）', () {
      expect(EggGrowthStage.of(500, params), EggGrowthStage.ready);
      expect(EggGrowthStage.of(700, params), EggGrowthStage.ready);
    });

    test('S1 だけレア度を隠す', () {
      expect(EggGrowthStage.blank.hidesRarity, isTrue);
      for (final s in EggGrowthStage.values.where((s) => s != EggGrowthStage.blank)) {
        expect(s.hidesRarity, isFalse, reason: '$s');
      }
    });

    test('見た目（EggLook）への対応: S4 は strong で切り替わる', () {
      expect(EggGrowthStage.glow.look(), EggLook.glow);
      expect(EggGrowthStage.glow.look(strong: true), EggLook.glowStrong);
      expect(EggGrowthStage.blank.look(strong: true), EggLook.blank);
      expect(EggGrowthStage.ready.look(), EggLook.ready);
    });

    test('「最後に見た段階」の値は 0..5（強まるを1段として数える）', () {
      expect(EggGrowthStage.visualStep(0, t), 0);
      expect(EggGrowthStage.visualStep(100, t), 1);
      expect(EggGrowthStage.visualStep(200, t), 2);
      expect(EggGrowthStage.visualStep(300, t), 3);
      expect(EggGrowthStage.visualStep(400, t), 4);
      expect(EggGrowthStage.visualStep(500, t), 5);
    });
  });

  group('EggThresholds（区切りの SSOT）', () {
    test('既定の区切りと「強まる」点', () {
      expect(t.stages, [0, 100, 200, 300, 500]);
      expect(t.glowStrongAt, 400); // 最後の区間の中間
    });

    test('段階内の進捗とつぎの変化までの残り', () {
      expect(t.stageProgressOf(0), 0.0);
      expect(t.stageProgressOf(50), 0.5);
      expect(t.stageProgressOf(350), closeTo(0.25, 0.001)); // (350-300)/200
      expect(t.stageProgressOf(500), 1.0);
      expect(t.remainingToNextStage(0), 100);
      expect(t.remainingToNextStage(460), 40);
      expect(t.remainingToNextStage(500), 0);
      expect(t.remainingToNextStage(800), 0);
    });

    test('不正な stages は既定へ倒す（降順 / 先頭が0でない / 末尾が hatch でない）', () {
      expect(
        EggThresholds.fromJson({'hatch': 500, 'stages': [0, 300, 200, 500]}).stages,
        [0, 100, 200, 300, 500],
      );
      expect(
        EggThresholds.fromJson({'hatch': 500, 'stages': [10, 100, 500]}).stages,
        [0, 100, 200, 300, 500],
      );
      expect(
        EggThresholds.fromJson({'hatch': 500, 'stages': [0, 100, 400]}).stages,
        [0, 100, 200, 300, 500],
      );
      expect(
        EggThresholds.fromJson({'hatch': 500, 'stages': 'oops'}).stages,
        [0, 100, 200, 300, 500],
      );
    });

    test('stages 無し（古い app_config）でも hatch から導く', () {
      expect(EggThresholds.fromJson({'hatch': 500}).stages, [0, 100, 200, 300, 500]);
      expect(EggThresholds.fromJson({'hatch': 1000}).stages, [0, 200, 400, 600, 1000]);
    });

    test('リモートの正しい stages はそのまま使う', () {
      final x = EggThresholds.fromJson({
        'hatch': 500,
        'stages': [0, 50, 150, 300, 500],
      });
      expect(x.stages, [0, 50, 150, 300, 500]);
      expect(EggGrowthStage.fromThresholds(60, x), EggGrowthStage.pattern);
      expect(x.glowStrongAt, 400);
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

    test('isNearHatch は S4「強まる」（400pt〜）かつ未到達', () {
      expect(eggWith(399).isNearHatch(params), isFalse);
      expect(eggWith(400).isNearHatch(params), isTrue);
      expect(eggWith(470).isNearHatch(params), isTrue);
      expect(eggWith(500).isNearHatch(params), isFalse); // 既に到達
    });

    test('look / stageProgress / remainingToNextStage は SSOT 経由', () {
      expect(eggWith(0).look(params), EggLook.blank);
      expect(eggWith(450).look(params), EggLook.glowStrong);
      expect(eggWith(250).stageProgress(params), 0.5);
      expect(eggWith(250).remainingToNextStage(params), 50);
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/observability/analytics.dart';
import 'package:moffy/core/observability/analytics_events.dart';
import 'package:moffy/core/observability/observability_providers.dart';
import 'package:moffy/features/home/data/egg_stage_memory.dart';
import 'package:moffy/features/home/domain/home_state.dart';
import 'package:moffy/features/home/presentation/widgets/egg_stage_reveal.dart';

/// ホームの段階アップ演出（0018 / docs/design/EGG_PACING_DESIGN.md §4-3）。
///
/// 「変わった！」は端末に覚えた**最後に見た段階**との差でしか作れない。ここで固定するのは
///   * 初めて見る卵は演出なし（一気に流さない）。S5 だけは孵化ボタン付きの演出
///   * 1段 / 複数段（1段ずつ順に）/ S1→S2 のレア度公開 / S4→S5 の孵化ボタン
///   * 「視差効果を減らす」では絵の差し替えとチップだけ
///   * 演出の最後に段階を記憶し、egg_stage_up を 1 回だけ送る
/// 卵の呼吸は無限ループなので pumpAndSettle は使わず、時間を進めて確かめる。
void main() {
  group('EggRevealPlan.of（どこから、どこまで出すか）', () {
    test('初めて見る卵は、いまの段階をそのまま出す（演出なし）', () {
      final p = EggRevealPlan.of(lastSeen: null, current: 2);
      expect(p.displayStep, 2);
      expect(p.hasReveal, isFalse);
      expect(p.finalStep, 2);
    });

    test('初めて見る卵でも S5（孵化できる）だけは S4強→S5 の演出', () {
      final p = EggRevealPlan.of(lastSeen: null, current: 5);
      expect(p.displayStep, 4);
      expect(p.steps, [5]);
    });

    test('1段進んだら、その1段', () {
      final p = EggRevealPlan.of(lastSeen: 1, current: 2);
      expect(p.displayStep, 1);
      expect(p.steps, [2]);
    });

    test('複数段進んだら 1段ずつ順に（飛ばさない）', () {
      final p = EggRevealPlan.of(lastSeen: 0, current: 3);
      expect(p.displayStep, 0);
      expect(p.steps, [1, 2, 3]);
      expect(p.finalStep, 3);
    });

    test('進んでいない・別の卵で戻ったときは演出なし', () {
      expect(EggRevealPlan.of(lastSeen: 3, current: 3).hasReveal, isFalse);
      final back = EggRevealPlan.of(lastSeen: 4, current: 2);
      expect(back.hasReveal, isFalse);
      expect(back.displayStep, 2);
    });
  });

  group('EggStageReveal（ホームの巣パネル）', () {
    late InMemoryEggStageMemory memory;
    late _RecordingAnalytics analytics;

    Widget harness({
      required int growth,
      int? lastSeen,
      String rarity = 'normal',
      VoidCallback? onHatch,
      bool reduceMotion = false,
    }) {
      memory = InMemoryEggStageMemory(
        lastSeen == null ? null : {'e1': lastSeen},
      );
      analytics = _RecordingAnalytics();
      return ProviderScope(
        overrides: [
          eggStageMemoryProvider.overrideWithValue(memory),
          analyticsProvider.overrideWithValue(analytics),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(disableAnimations: reduceMotion),
                  child: EggStageReveal(
                    egg: _egg(growth, rarity: rarity),
                    onHatch: onHatch,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    /// 記憶の読み込み（非同期）を終えて最初の絵を出す。
    Future<void> settleStart(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> advance(WidgetTester tester, int ms) async {
      await tester.pump(Duration(milliseconds: ms));
    }

    testWidgets('1段: 前の絵 → フラッシュ → 段階名のチップ → 定常。記憶と計測は最後に1回',
        (tester) async {
      // もよう(1) → ヒビ(2)。いまの pt は 200。
      await tester.pumpWidget(harness(growth: 200, lastSeen: 1));
      await settleStart(tester);

      // 0.5秒の「前の絵」: 前の段階名の見出し（残り pt は実際の値）。
      expect(find.text('もよう・つぎの変化まで あと 100pt'), findsOneWidget);
      expect(find.text('ピキッ！'), findsNothing);

      // 0.5秒ホールド + 0.6秒フラッシュ → チップ（段階名 + ひとこと）。
      await advance(tester, 1200);
      expect(find.text('ヒビ'), findsOneWidget);
      expect(find.text('ピキッ！'), findsOneWidget);
      // チップの間は記録しない（演出を見終わるまで「見た」にしない）。
      expect(await memory.lastSeenStep('e1'), 1);

      // 1.5秒のチップ → 定常（新しい段階名の見出し）。
      await advance(tester, 1600);
      expect(find.text('ピキッ！'), findsNothing);
      expect(find.text('ヒビ・つぎの変化まで あと 100pt'), findsOneWidget);
      expect(await memory.lastSeenStep('e1'), 2);

      final e = analytics.single(AnalyticsEvents.eggStageUp);
      expect(e.props?[AnalyticsProps.fromStep], 1);
      expect(e.props?[AnalyticsProps.toStep], 2);
      expect(e.props?[AnalyticsProps.steps], 1);
      expect(e.props?[AnalyticsProps.eggRarity], 'normal');
    });

    testWidgets('複数段: 2段以上進んでいたら 0.8秒あけて 1段ずつ順に出す',
        (tester) async {
      // もよう(1) → ヒビ(2) → ひかり(3)。いまの pt は 300。
      await tester.pumpWidget(harness(growth: 300, lastSeen: 1));
      await settleStart(tester);
      // 見出しの段階名は「前の絵」、残り pt は実際の卵（300 → 次は 500）。
      expect(find.text('もよう・つぎの変化まで あと 200pt'), findsOneWidget);

      // 1段目のチップ（0.5 + 0.6 秒後）。
      await advance(tester, 1200);
      expect(find.text('ピキッ！'), findsOneWidget);

      // 1段目のチップ 1.5秒 → 間 0.8秒 → 2段目のフラッシュ 0.6秒 → 2段目のチップ。
      await advance(tester, 1500 + 800 + 600 + 100);
      expect(find.text('ピキッ！'), findsNothing);
      expect(find.text('ヒビから ひかりが…もうすぐ うまれそう'), findsOneWidget);
      expect(await memory.lastSeenStep('e1'), 1); // まだ見終わっていない

      await advance(tester, 1600);
      expect(find.text('ひかり・つぎの変化まで あと 200pt'), findsOneWidget);
      expect(await memory.lastSeenStep('e1'), 3);
      final e = analytics.single(AnalyticsEvents.eggStageUp);
      expect(e.props?[AnalyticsProps.fromStep], 1);
      expect(e.props?[AnalyticsProps.toStep], 3);
      expect(e.props?[AnalyticsProps.steps], 2);
    });

    testWidgets('S1→S2: レア度が分かる瞬間は「レアのたまご！」', (tester) async {
      await tester.pumpWidget(
        harness(growth: 100, lastSeen: 0, rarity: 'rare'),
      );
      await settleStart(tester);
      expect(find.text('しろいたまご・つぎの変化まで あと 100pt'), findsOneWidget);

      // 0.5秒ホールド → 浮かび上がり開始（アニメーションの 0 秒目は次のフレーム）。
      await advance(tester, 600);
      expect(find.text('もようが うかんできた！'), findsNothing);
      // 1.2秒かけて浮かび上がる → 完了の合図（チップ）は、その次のフレームで出る。
      await advance(tester, 1200);
      await tester.pump();
      expect(find.text('もようが うかんできた！'), findsOneWidget);
      expect(find.text('レアのたまご！'), findsOneWidget);

      await advance(tester, 1600);
      expect(find.text('レアのたまご！'), findsNothing);
      expect(find.text('もよう・つぎの変化まで あと 100pt'), findsOneWidget);
      expect(await memory.lastSeenStep('e1'), 1);
      final e = analytics.single(AnalyticsEvents.eggStageUp);
      expect(e.props?[AnalyticsProps.eggRarity], 'rare');
    });

    testWidgets('S4→S5: 演出が終わってから「孵化する」が出て、押すと onHatch',
        (tester) async {
      var hatched = 0;
      await tester.pumpWidget(
        harness(growth: 500, lastSeen: 4, onHatch: () => hatched++),
      );
      await settleStart(tester);

      // 演出中はボタンを出さない（タップの取り合いを避ける）。
      await advance(tester, 1200);
      expect(find.text('うまれる！'), findsWidgets);
      expect(find.text('孵化する'), findsNothing);

      await advance(tester, 1600);
      expect(find.text('孵化できます！'), findsOneWidget);
      await tester.tap(find.text('孵化する'));
      expect(hatched, 1);
      expect(await memory.lastSeenStep('e1'), 5);
    });

    testWidgets('初めて見る卵は演出なし（記憶だけ更新・計測しない）', (tester) async {
      await tester.pumpWidget(harness(growth: 200));
      await settleStart(tester);

      expect(find.text('ヒビ・つぎの変化まで あと 100pt'), findsOneWidget);
      expect(await memory.lastSeenStep('e1'), 2);
      await advance(tester, 3000);
      expect(find.text('ピキッ！'), findsNothing);
      expect(analytics.names, isNot(contains(AnalyticsEvents.eggStageUp)));
    });

    testWidgets('初めて見る卵でも S5 なら孵化ボタン付きの演出（放置された卵を孵す）',
        (tester) async {
      await tester.pumpWidget(harness(growth: 780, onHatch: () {}));
      await settleStart(tester);
      expect(find.text('孵化する'), findsNothing); // 演出中
      await advance(tester, 3000);
      expect(find.text('孵化できます！'), findsOneWidget);
      expect(find.text('孵化する'), findsOneWidget);
      // 出発点が分からない（初めて）ので段階アップとしては数えない。
      expect(analytics.names, isNot(contains(AnalyticsEvents.eggStageUp)));
    });

    testWidgets('「視差効果を減らす」: フラッシュを待たず、絵の差し替えとチップだけ',
        (tester) async {
      await tester.pumpWidget(
        harness(growth: 200, lastSeen: 1, reduceMotion: true),
      );
      await settleStart(tester);
      expect(find.text('もよう・つぎの変化まで あと 100pt'), findsOneWidget);

      // 通常は 1.1秒後にチップが出るが、動きなしでは 0.5秒のホールド直後に出る。
      await advance(tester, 600);
      expect(find.text('ピキッ！'), findsOneWidget);

      await advance(tester, 1600);
      expect(find.text('ヒビ・つぎの変化まで あと 100pt'), findsOneWidget);
      expect(await memory.lastSeenStep('e1'), 2);
      final e = analytics.single(AnalyticsEvents.eggStageUp);
      expect(e.props?[AnalyticsProps.steps], 1);
    });

    testWidgets('タップでスキップ: 途中で触ると最後の段階へ飛び、記録と計測は1回',
        (tester) async {
      await tester.pumpWidget(harness(growth: 300, lastSeen: 0));
      await settleStart(tester);

      await advance(tester, 700); // 1段目（S1→S2）の途中
      await tester.tap(find.byType(EggStageReveal));
      await tester.pump();

      expect(find.text('ひかり・つぎの変化まで あと 200pt'), findsOneWidget);
      expect(await memory.lastSeenStep('e1'), 3);
      final e = analytics.single(AnalyticsEvents.eggStageUp);
      expect(e.props?[AnalyticsProps.fromStep], 0);
      expect(e.props?[AnalyticsProps.toStep], 3);
      // スキップ後に残った演出が流れてこない。
      await advance(tester, 5000);
      expect(find.text('ピキッ！'), findsNothing);
      expect(
        analytics.names.where((n) => n == AnalyticsEvents.eggStageUp),
        hasLength(1),
      );
    });

    testWidgets('表示中に pt が入って段階が進んだら、続きの演出を積む', (tester) async {
      final growth = ValueNotifier<int>(100);
      addTearDown(growth.dispose);
      memory = InMemoryEggStageMemory({'e1': 1});
      analytics = _RecordingAnalytics();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            eggStageMemoryProvider.overrideWithValue(memory),
            analyticsProvider.overrideWithValue(analytics),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: ValueListenableBuilder<int>(
                  valueListenable: growth,
                  builder: (context, g, _) => EggStageReveal(egg: _egg(g)),
                ),
              ),
            ),
          ),
        ),
      );
      await settleStart(tester);
      expect(find.text('もよう・つぎの変化まで あと 100pt'), findsOneWidget);

      growth.value = 200; // 前日分の確定が入った
      await tester.pump();
      await advance(tester, 700);
      expect(find.text('ピキッ！'), findsOneWidget);
      await advance(tester, 1600);
      expect(find.text('ヒビ・つぎの変化まで あと 100pt'), findsOneWidget);
      final e = analytics.single(AnalyticsEvents.eggStageUp);
      expect(e.props?[AnalyticsProps.fromStep], 1);
      expect(e.props?[AnalyticsProps.toStep], 2);
    });
  });
}

ActiveEggSummary _egg(int growth, {String rarity = 'normal'}) =>
    ActiveEggSummary(
      eggId: 'e1',
      growthPoints: growth,
      thresholds: EconomyParams.defaults.eggThresholds,
      rarityLabel: rarity,
    );

/// capture された内容を覚えておくだけの Analytics。
class _RecordingAnalytics implements Analytics {
  final List<_Captured> captured = [];

  List<String> get names => captured.map((e) => e.event).toList();

  /// 指定イベントが**1回だけ**記録されていることを確かめ、その中身を返す。
  _Captured single(String event) {
    final hits = captured.where((e) => e.event == event).toList();
    expect(hits, hasLength(1), reason: '$event は1回だけ送られるべき');
    return hits.first;
  }

  @override
  void capture(String event, {Map<String, Object>? properties}) {
    captured.add(_Captured(event, properties));
  }

  @override
  void identifyAnonymous(String anonymousUserId) {}

  @override
  void reset() {}
}

class _Captured {
  const _Captured(this.event, this.props);
  final String event;
  final Map<String, Object>? props;
}

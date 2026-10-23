import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/observability/analytics_events.dart';
import '../../../../core/observability/observability_providers.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/egg_art.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../../eggs/domain/egg_models.dart';
import '../../../eggs/presentation/egg_visuals.dart';
import '../../data/egg_stage_memory.dart';
import '../../domain/home_state.dart';

/// 「どこから、どこまで」段階アップ演出を出すかの純粋ロジック（テスト対象）。
///
/// 端末に覚えた「最後に見た段階」（[lastSeen] / 0..5）と、いまの段階（[current]）を比べる。
///   * 初めて見る卵（lastSeen=null）… いまの段階をそのまま出す（一気に演出を流さない / §5-1）。
///     例外として S5（孵化できる）だけは、孵化ボタン付きの演出を出す（放置されていた卵を孵す）。
///   * 進んでいる … 1段ずつ順に演出（2段以上なら 0.8 秒間隔で連続）。
///   * 進んでいない … 演出なし。
class EggRevealPlan {
  const EggRevealPlan({required this.displayStep, required this.steps});

  /// 最初に見せる段階（演出の出発点）。
  final int displayStep;

  /// 順に進める段階。空なら演出なし。
  final List<int> steps;

  bool get hasReveal => steps.isNotEmpty;

  /// 演出の着地点（演出が無ければ [displayStep]）。
  int get finalStep => steps.isEmpty ? displayStep : steps.last;

  static EggRevealPlan of({required int? lastSeen, required int current}) {
    if (lastSeen == null) {
      if (current == EggLook.ready.step) {
        return EggRevealPlan(
          displayStep: EggLook.glowStrong.step,
          steps: [current],
        );
      }
      return EggRevealPlan(displayStep: current, steps: const []);
    }
    if (current <= lastSeen) {
      return EggRevealPlan(displayStep: current, steps: const []);
    }
    return EggRevealPlan(
      displayStep: lastSeen,
      steps: [for (var s = lastSeen + 1; s <= current; s++) s],
    );
  }
}

/// ホームの主役: 育成中の卵を 5段階の見た目で出し、段階が進んでいたら「変わった！」の演出を出す
/// （0018 / docs/design/EGG_PACING_DESIGN.md §4-3）。
///
/// 流れ（ふつうの段階アップ・約2.5秒）:
///   前の絵（0.5秒）→ 白いフラッシュ＋ぽんと拡大 → 新しい絵＋段階名のチップとひとこと（1.5秒）→ 定常の動き。
/// S1→S2（レア度が分かる瞬間）だけ特別: 白い卵の上にレア度の画像が 1.2 秒かけて浮かび上がり、
/// 途中でフラッシュ。最後に「レアのたまご！」。
/// S4→S5: 演出の最後に大きな「孵化する」ボタン（押すとたまご画面の孵化へ）。
/// タップでスキップ。「視差効果を減らす」では絵の差し替えとチップだけ。
class EggStageReveal extends ConsumerStatefulWidget {
  const EggStageReveal({
    super.key,
    required this.egg,
    this.onHatch,
    this.diameter = 180,
  });

  final ActiveEggSummary egg;

  /// 孵化できる状態のときに出すボタンの行き先（たまご画面）。null ならボタンを出さない。
  final VoidCallback? onHatch;

  final double diameter;

  @override
  ConsumerState<EggStageReveal> createState() => _EggStageRevealState();
}

enum _Phase { idle, flash, fadeIn, chip }

class _EggStageRevealState extends ConsumerState<EggStageReveal>
    with TickerProviderStateMixin {
  static const _holdBefore = Duration(milliseconds: 500);
  static const _flashDuration = Duration(milliseconds: 600);
  static const _fadeDuration = Duration(milliseconds: 1200);
  static const _chipHold = Duration(milliseconds: 1500);
  static const _gapBetween = Duration(milliseconds: 800);

  late final AnimationController _flash =
      AnimationController(vsync: this, duration: _flashDuration);
  late final AnimationController _fade =
      AnimationController(vsync: this, duration: _fadeDuration);

  /// いま画面に出している段階（0..5）。null = 記憶の読み込み中。
  int? _displayStep;

  /// 演出の出発点（分析用）。
  int? _fromStep;

  /// 残りの演出キュー。
  final List<int> _queue = [];
  _Phase _phase = _Phase.idle;
  String? _chipText;
  String? _chipSub;
  Timer? _timer;
  bool _playing = false;

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void didUpdateWidget(covariant EggStageReveal old) {
    super.didUpdateWidget(old);
    if (old.egg.eggId != widget.egg.eggId) {
      // 別の卵になった（枠移動・孵化後の新しい卵）。記憶を読み直す。
      _cancel();
      _displayStep = null;
      unawaited(_start());
      return;
    }
    final target = widget.egg.visualStep;
    final known = _queue.isNotEmpty ? _queue.last : _displayStep;
    if (known != null && target > known) {
      // 表示中にポイントが入って段階が進んだ（前日分の確定など）。続きを積む。
      for (var s = known + 1; s <= target; s++) {
        _queue.add(s);
      }
      _fromStep ??= _displayStep;
      if (!_playing) _playNext();
    }
  }

  Future<void> _start() async {
    final memory = ref.read(eggStageMemoryProvider);
    final eggId = widget.egg.eggId;
    final lastSeen = await memory.lastSeenStep(eggId);
    if (!mounted || widget.egg.eggId != eggId) return;
    final plan = EggRevealPlan.of(
      lastSeen: lastSeen,
      current: widget.egg.visualStep,
    );
    setState(() {
      _displayStep = plan.displayStep;
      _queue
        ..clear()
        ..addAll(plan.steps);
      _fromStep = lastSeen;
    });
    if (plan.hasReveal) {
      _timer = Timer(_holdBefore, _playNext);
    } else {
      await memory.remember(eggId, plan.finalStep);
    }
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _flash.stop();
    _fade.stop();
    _queue.clear();
    _playing = false;
    _phase = _Phase.idle;
    _chipText = null;
    _chipSub = null;
  }

  /// 次の段階へ。キューが空なら演出終了。
  void _playNext() {
    if (!mounted) return;
    if (_queue.isEmpty) {
      unawaited(_finish());
      return;
    }
    _playing = true;
    final next = _queue.removeAt(0);
    final from = _displayStep ?? next;
    final special = from == EggLook.blank.step && next == EggLook.pattern.step;

    if (_reduceMotion) {
      // 動きなし: 絵の差し替えとチップだけ（§4-3）。
      setState(() {
        _displayStep = next;
        _phase = _Phase.chip;
        _setChip(next, special: special);
      });
      _timer = Timer(_chipHold, _afterChip);
      return;
    }

    if (special) {
      // S1→S2: 白い卵の上にレア度の画像がじわっと浮かび上がる（1.2秒）。
      setState(() => _phase = _Phase.fadeIn);
      _fade
        ..reset()
        ..forward().whenComplete(() {
          if (!mounted) return;
          setState(() {
            _displayStep = next;
            _phase = _Phase.chip;
            _setChip(next, special: true);
          });
          _timer = Timer(_chipHold, _afterChip);
        });
      // 浮かび終わりにフラッシュ（ずれを見せない / レア度の光が一度広がる）。
      _timer = Timer(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        _flash
          ..reset()
          ..forward();
      });
      return;
    }

    // ふつう: 白いフラッシュ＋ぽんと拡大（0.6秒）の山で絵を差し替える。
    setState(() => _phase = _Phase.flash);
    _flash
      ..reset()
      ..forward();
    _timer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _displayStep = next);
      _timer = Timer(_flashDuration - const Duration(milliseconds: 250), () {
        if (!mounted || _phase != _Phase.flash) return;
        setState(() {
          _phase = _Phase.chip;
          _setChip(next, special: false);
        });
        _timer = Timer(_chipHold, _afterChip);
      });
    });
  }

  void _afterChip() {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.idle;
      _chipText = null;
      _chipSub = null;
    });
    if (_queue.isEmpty) {
      unawaited(_finish());
    } else {
      _timer = Timer(_gapBetween, _playNext);
    }
  }

  void _setChip(int step, {required bool special}) {
    final look = EggLook.fromStep(step);
    final stage = widget.egg.stage;
    if (special) {
      final rarity = EggRarity.fromWire(widget.egg.rarityLabel);
      _chipText = 'もようが うかんできた！';
      _chipSub = '${rarity.label}のたまご！';
      return;
    }
    if (look == EggLook.glowStrong) {
      _chipText = 'ひかり';
      _chipSub = 'あと少しで うまれる！';
      return;
    }
    _chipText = look.label;
    _chipSub = look == EggLook.ready
        ? EggGrowthStage.ready.stageUpLine
        : EggGrowthStage.values
            .firstWhere(
              (s) => s.look() == look || s.look(strong: true) == look,
              orElse: () => stage,
            )
            .stageUpLine;
  }

  /// 演出を終える: 段階を記録し、計測する。
  Future<void> _finish() async {
    final to = widget.egg.visualStep;
    final from = _fromStep;
    _playing = false;
    _fromStep = null;
    await ref.read(eggStageMemoryProvider).remember(widget.egg.eggId, to);
    if (from != null && to > from) {
      ref.read(analyticsProvider).capture(
        AnalyticsEvents.eggStageUp,
        properties: {
          AnalyticsProps.fromStep: from,
          AnalyticsProps.toStep: to,
          AnalyticsProps.steps: to - from,
          AnalyticsProps.eggRarity: widget.egg.rarityLabel,
        },
      );
    }
  }

  /// タップでスキップ（孵化演出と同じ作法）。
  void _skip() {
    if (_phase == _Phase.idle && _queue.isEmpty) return;
    _cancel();
    setState(() => _displayStep = widget.egg.visualStep);
    unawaited(_finish());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _flash.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final egg = widget.egg;
    final step = _displayStep ?? egg.visualStep;
    final look = EggLook.fromStep(step);
    final rarity = RarityVisuals.ofEgg(EggRarity.fromWire(egg.rarityLabel));
    final busy = _phase != _Phase.idle || _queue.isNotEmpty;
    // 演出の着地点が S5 なら孵化ボタン（演出が終わってから出す）。
    final showHatch = widget.onHatch != null &&
        egg.canHatch &&
        step == EggLook.ready.step &&
        !busy;

    // 巣リングの発光: S4 微発光 / 強まる・S5 発光強め（暖色。レア度の色は使わない）。
    final Color? glow = switch (look) {
      EggLook.glow => AppColors.eggLightRay,
      EggLook.glowStrong || EggLook.ready => AppColors.eggLight,
      _ => null,
    };

    final subject = Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        EggArt(rarity: rarity, look: look, animated: !busy),
        // S1→S2: レア度の画像がじわっと浮かぶ。
        if (_phase == _Phase.fadeIn)
          FadeTransition(
            opacity: _fade,
            child: EggArt(rarity: rarity, look: EggLook.pattern),
          ),
        // フラッシュ（白が広がって消える）。
        if (_phase == _Phase.flash || _phase == _Phase.fadeIn)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _flash,
              builder: (context, _) {
                final v = _flash.value;
                final alpha = (1 - v).clamp(0.0, 1.0) * 0.85;
                return Opacity(
                  opacity: _flash.isAnimating || v > 0 ? alpha : 0,
                  child: Container(
                    width: widget.diameter * 1.1,
                    height: widget.diameter * 1.1,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.eggLightSoft,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );

    // ぽんと拡大（1.0→1.12→1.0）。フラッシュと同じコントローラで同期。
    final scaled = AnimatedBuilder(
      animation: _flash,
      child: subject,
      builder: (context, child) {
        final v = _phase == _Phase.flash ? _flash.value : 0.0;
        final bump = 1.0 + 0.12 * (v < 0.5 ? v * 2 : (1 - v) * 2);
        return Transform.scale(
          scale: bump,
          alignment: Alignment.bottomCenter,
          child: child,
        );
      },
    );

    final remaining = egg.remainingToNextStage;
    final captionText = egg.canHatch && step == EggLook.ready.step
        ? '孵化できます！'
        : '${look.label}・つぎの変化まで あと ${remaining}pt';

    return Semantics(
      label: 'たまご: ${look.label}。'
          '${egg.canHatch ? '孵化できます' : 'つぎの変化まであと$remainingポイント'}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? _skip : null,
        child: NestPanel(
          diameter: widget.diameter,
          glow: glow,
          caption: _chipText != null
              ? _StageChip(text: _chipText!, sub: _chipSub)
              : Text(captionText, style: AppType.title),
          subject: scaled,
          footer: Column(
            children: [
              GrowthProgressBar(value: egg.stageProgress),
              const SizedBox(height: AppSpace.sm),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${(egg.stageProgress * 100).round()}%',
                    style: AppType.numLabel,
                  ),
                  const SizedBox(width: AppSpace.md),
                  StageDots(reached: egg.stageIndex + 1, total: egg.stageCount),
                ],
              ),
              if (showHatch) ...[
                const SizedBox(height: AppSpace.md),
                PrimaryButton(label: '孵化する', onPressed: widget.onHatch),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 段階が進んだときのチップ（段階名＋ひとこと）。
class _StageChip extends StatelessWidget {
  const _StageChip({required this.text, this.sub});

  final String text;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.xs,
          ),
          decoration: const BoxDecoration(
            color: AppColors.primary,
            borderRadius: AppRadius.pillR,
          ),
          child: Text(
            text,
            style: AppType.bodyStrong.copyWith(color: AppColors.onPrimary),
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: AppSpace.xs),
          Text(sub!, style: AppType.title, textAlign: TextAlign.center),
        ],
      ],
    );
  }
}

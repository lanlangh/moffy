import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/nest_panel.dart';
import '../../../../core/widgets/world_stage.dart';
import '../../../eggs/presentation/egg_visuals.dart';
import '../../domain/mofi_models.dart';

/// Mofi詳細シート（SCREEN_FLOWS §4 / 要件: 名前・レア・種族・発見日時・色違い有無）。
/// 未発見は項目を伏せ、「卵を育てて見つけよう」を案内する。
class MofiDetailSheet extends StatelessWidget {
  const MofiDetailSheet({
    super.key,
    required this.entry,
    required this.stage2Count,
  });

  final MofiDexEntry entry;

  /// 進化アダルト化の重複しきい値（CollectionState由来 / docs/EVOLUTION.md）。
  final int stage2Count;

  @override
  Widget build(BuildContext context) {
    final discovered = entry.discovered;
    final rarity = RarityVisuals.ofMofi(entry.species.rarity);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      // シート全体に padding を掛けると背景ステージにも左右の余白が付き、
      // 絵が狭く見える（オーナー指摘 2026-08-19「左右はまだ余裕がある」）。
      // padding はステージより下の文章側にだけ掛ける。
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpace.md),
            const _SheetGrip(),
            const SizedBox(height: AppSpace.md),
            // 発見済みの子だけ「世界の風景」の上に立たせる。未発見はシルエットで
            // 正体を伏せる場面なので、背景を出すと発見の驚きが先に漏れる。
            // 砂色の円台は出さない（風景の上だと貼り紙のように浮くため）。
            SizedBox(
              // 🔴 幅を指定しないと中身の巣(160px)の幅に縮み、背景が左右に
              // 余白を残したまま小さく出る（2026-08-19 の指摘の原因はこれ）。
              width: double.infinity,
              height: 240,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (discovered)
                    const Positioned.fill(child: WorldStageBackground()),
                  NestRing(
                    diameter: 160,
                    glow: discovered ? rarity.main : null,
                    showBase: !discovered,
                    child: MofiSubject(
                      speciesId: entry.species.id,
                      family: entry.species.family,
                      rarity: entry.species.rarity,
                      stage: entry.evolutionStage(stage2Count),
                      silhouette: !discovered,
                      isShiny: entry.isShiny,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.lg),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
            Text(
              discovered ? entry.species.name : '？？？',
              style: AppType.display,
            ),
            if (discovered && entry.isShiny) ...[
              const SizedBox(height: AppSpace.sm),
              // キラキラのアイコンを添えるのはやめ、色付きのバッジにする
              // （2026-08-19 オーナー指摘「絵文字は安っぽく見える」）。
              // 装飾で特別さを出すのではなく、**面と色**で出す。
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.warn.withValues(alpha: 0.16),
                  borderRadius: AppRadius.pillR,
                ),
                child: Text(
                  '色違い',
                  style: AppType.bodyStrong.copyWith(color: AppColors.warn),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.xl),

            if (discovered) ...[
              _DetailRow(label: 'レアリティ', value: entry.species.rarity.label),
              _DetailRow(label: '種族', value: entry.species.family.label),
              // 進化ライン（docs/EVOLUTION.md §5。仕様にあったが未実装だった）。
              // 進化すると こどもの姿が二度と見られないのは収集ゲームとして
              // もったいない、というオーナー指摘への対応でもある。
              const SizedBox(height: AppSpace.md),
              _EvolutionLine(entry: entry, stage2Count: stage2Count),
              const SizedBox(height: AppSpace.md),
              _DetailRow(
                label: '進化',
                value: entry.evolutionStage(stage2Count) >= 2
                    ? '進化済み'
                    : (entry.toNextEvolution(stage2Count) > 0
                        ? 'あと${entry.toNextEvolution(stage2Count)}体で進化'
                        : '進化前'),
              ),
              _DetailRow(
                label: '色違い',
                value: entry.isShiny ? 'あり' : '通常色',
              ),
              _DetailRow(
                label: '発見日時',
                value: _formatDate(entry.discoveredAt),
              ),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.lg),
                child: Text(
                  '${entry.species.rarity.label}のMofi。卵を育てて孵化させると見つかります。',
                  style: AppType.body,
                  textAlign: TextAlign.center,
                ),
              ),
            const SizedBox(height: AppSpace.lg),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime? d) {
    if (d == null) return '—';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// ボトムシート上端のつまみ（共通の見た目）。
/// 進化ライン（こども → おとな）。
///
/// `docs/EVOLUTION.md` §5 に「詳細シートに進化ラインを表示」と書かれていたが
/// 未実装だった。実装すると両方向に効く:
///   * 進化済み → **前の姿も見られる**（集めた記録として残る。進化すると
///     こどもの姿が二度と見られないのは、収集ゲームとしてもったいない）
///   * 未進化   → **これから何になるかが分かる**（同じ子を集める動機）
///
/// ただし未進化のときに完成形をそのまま見せるとネタバレになるので、
/// おとなの姿は**シルエット**にする（図鑑の未発見と同じ扱い）。
class _EvolutionLine extends StatelessWidget {
  const _EvolutionLine({required this.entry, required this.stage2Count});

  final MofiDexEntry entry;
  final int stage2Count;

  @override
  Widget build(BuildContext context) {
    final evolved = entry.evolutionStage(stage2Count) >= 2;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _EvolutionStep(
          entry: entry,
          stage: 1,
          label: '進化前',
          silhouette: false,
          dimmed: evolved, // 進化後は「今の姿」でない側を控えめに
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AppSpace.sm),
          child: Icon(
            Icons.arrow_forward_rounded,
            size: 18,
            color: AppColors.textSecondary,
          ),
        ),
        _EvolutionStep(
          entry: entry,
          stage: 2,
          label: evolved ? '進化後' : '？？？',
          // 未進化のうちは完成形を伏せる（発見の驚きを先に漏らさない）。
          silhouette: !evolved,
          dimmed: !evolved,
        ),
      ],
    );
  }
}

class _EvolutionStep extends StatelessWidget {
  const _EvolutionStep({
    required this.entry,
    required this.stage,
    required this.label,
    required this.silhouette,
    required this.dimmed,
  });

  final MofiDexEntry entry;
  final int stage;
  final String label;
  final bool silhouette;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: dimmed ? 0.55 : 1.0,
          child: SizedBox(
            width: 64,
            height: 64,
            child: MofiSubject(
              speciesId: entry.species.id,
              family: entry.species.family,
              rarity: entry.species.rarity,
              stage: stage,
              silhouette: silhouette,
              isShiny: entry.isShiny,
            ),
          ),
        ),
        const SizedBox(height: AppSpace.xs),
        Text(
          label,
          style: AppType.caption.copyWith(
            color: dimmed ? AppColors.textSecondary : AppColors.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _SheetGrip extends StatelessWidget {
  const _SheetGrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 4,
      decoration: const BoxDecoration(
        color: AppColors.divider,
        borderRadius: AppRadius.pillR,
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      child: Row(
        children: [
          Text(label, style: AppType.caption),
          const Spacer(),
          Text(value, style: AppType.bodyStrong),
        ],
      ),
    );
  }
}

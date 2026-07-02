import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/navigation/app_tab.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/state_views.dart';
import '../../eggs/presentation/egg_visuals.dart';
import '../domain/mofi_models.dart';
import 'collection_controller.dart';
import 'widgets/mofi_detail_sheet.dart';
import 'widgets/mofi_grid_tile.dart';

/// 図鑑画面（SCREEN_FLOWS §4）。
/// 達成率 + レアリティ/色違いフィルタ + 30エントリのグリッド（未発見はシルエット）。
///
/// 5状態:
///   * ローディング: 巣リング型スケルトン。
///   * エラー: ErrorView + リトライ。
///   * 空: 1体も未発見 → 「最初のMofiはまだ」誘導（30枠はシルエットで余白を見せる）。
///   * オフライン: キャッシュ表示 + 上端バー。
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  static const String routeName = 'collection';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(collectionControllerProvider);
    final controller = ref.read(collectionControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('図鑑')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const Center(child: NestSkeleton(label: '図鑑をひらいています')),
          error: (e, _) => ErrorView(
            message: '図鑑の読み込みに失敗しました。通信環境を確認してもう一度お試しください。',
            onRetry: controller.refresh,
          ),
          data: (state) => _CollectionBody(state: state),
        ),
      ),
    );
  }
}

class _CollectionBody extends ConsumerWidget {
  const _CollectionBody({required this.state});
  final CollectionState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(collectionFilterProvider);
    final filterNotifier = ref.read(collectionFilterProvider.notifier);

    // 空状態: 1体も未発見（孵化前）。シルエットで「集める余白」を見せつつ誘導。
    if (state.isEmpty) {
      return Column(
        children: [
          if (state.isOffline) const OfflineBar(),
          _AchievementHeader(state: state),
          Expanded(
            child: EmptyState(
              icon: Icons.pets_outlined,
              message: '最初のMofiはまだ',
              subMessage: '卵を育てて孵化させると、ここに登録されます。',
              ctaLabel: '卵を育てる',
              onCta: () => context.go(AppTab.eggs.path),
            ),
          ),
        ],
      );
    }

    final visible =
        state.entries.where(filter.matches).toList(growable: false);

    return Column(
      children: [
        if (state.isOffline) const OfflineBar(),
        _AchievementHeader(state: state),
        _FilterBar(
          filter: filter,
          onRarity: filterNotifier.toggleRarity,
          onShiny: filterNotifier.toggleShiny,
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh:
                ref.read(collectionControllerProvider.notifier).refresh,
            color: AppColors.primary,
            child: GridView.builder(
              padding: const EdgeInsets.all(AppSpace.lg),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: AppSpace.lg,
                crossAxisSpacing: AppSpace.lg,
                childAspectRatio: 0.78,
              ),
              itemCount: visible.length,
              itemBuilder: (context, i) {
                final entry = visible[i];
                return MofiGridTile(
                  entry: entry,
                  stage2Count: state.evolveStage2Count,
                  onTap: () =>
                      _openDetail(context, entry, state.evolveStage2Count),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  void _openDetail(BuildContext context, MofiDexEntry entry, int stage2Count) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => MofiDetailSheet(entry: entry, stage2Count: stage2Count),
    );
  }
}

/// 達成率ヘッダ（23 / 30 を Baloo で主役化 + プログレスバー / SCREEN_FLOWS §4）。
class _AchievementHeader extends StatelessWidget {
  const _AchievementHeader({required this.state});
  final CollectionState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('図鑑達成率', style: AppType.bodyStrong),
              const Spacer(),
              Text('${state.discoveredCount}', style: AppType.numLabel),
              Text(' / ${state.totalEntries}', style: AppType.caption),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          GrowthProgressBar(
            value: state.completionRatio,
            fillColor: AppColors.success,
          ),
        ],
      ),
    );
  }
}

/// フィルタバー: レアリティチップ + 色違いトグル（SCREEN_FLOWS §4）。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.filter,
    required this.onRarity,
    required this.onShiny,
  });

  final CollectionFilter filter;
  final ValueChanged<MofiRarity> onRarity;
  final VoidCallback onShiny;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
        children: [
          for (final r in MofiRarity.values) ...[
            _FilterChip(
              label: r.label,
              color: RarityVisuals.ofMofi(r).main,
              selected: filter.rarity == r,
              onTap: () => onRarity(r),
            ),
            const SizedBox(width: AppSpace.sm),
          ],
          _FilterChip(
            label: '色違い',
            color: AppColors.warn,
            selected: filter.shinyOnly,
            onTap: onShiny,
            icon: Icons.auto_awesome_rounded,
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? color : AppColors.surface,
          borderRadius: AppRadius.pillR,
          border: Border.all(color: color, width: selected ? 0 : 1.5),
          boxShadow: selected ? null : AppElevation.card,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 14,
                color: selected ? AppColors.onPrimary : color,
              ),
              const SizedBox(width: AppSpace.xs),
            ],
            Text(
              label,
              style: AppType.caption.copyWith(
                color: selected ? AppColors.onPrimary : AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

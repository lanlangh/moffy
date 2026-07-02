import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/pricing.dart';
import '../../../core/iap/iap_providers.dart';
import '../../../core/navigation/app_tab.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/observability_providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/egg_art.dart';
import '../../../core/widgets/nest_panel.dart';
import '../../../core/widgets/state_views.dart';
import '../../paywall/presentation/paywall_screen.dart';
import '../data/hatch_share_service.dart';
import '../domain/egg_models.dart';
import 'eggs_controller.dart';
import 'egg_visuals.dart';
import 'widgets/egg_detail_sheet.dart';
import 'widgets/hatch_overlay.dart';
import 'widgets/incubator_slots.dart';
import 'widgets/storage_grid.dart';

/// たまご画面（SCREEN_FLOWS §3）。育成枠3 + 保管枠 + 孵化演出 + 色違いキラリ。
///
/// 5状態:
///   * ローディング: AsyncValue.loading → 巣リング型スケルトン。
///   * エラー: AsyncValue.error → ErrorView + リトライ。
///   * ハッピー/空: data 内で「育成枠あり/空枠誘導」を出し分け。
///   * オフライン: 上端バー + 孵化ボタンのグレーアウト（二重消費防止 / S8）。
class EggsScreen extends ConsumerWidget {
  const EggsScreen({super.key});

  static const String routeName = 'eggs';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(eggsControllerProvider);
    final controller = ref.read(eggsControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('たまご')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const Center(child: NestSkeleton(label: '巣をのぞいています')),
          error: (e, _) => ErrorView(
            message: '卵の読み込みに失敗しました。通信環境を確認してもう一度お試しください。',
            onRetry: controller.refresh,
          ),
          data: (state) => _EggsBody(state: state),
        ),
      ),
    );
  }
}

class _EggsBody extends ConsumerWidget {
  const _EggsBody({required this.state});
  final EggsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(eggsControllerProvider.notifier);

    // 完全に空（保管も育成も無し）→ クエスト誘導の空状態（SCREEN_FLOWS §3）。
    if (state.isCompletelyEmpty) {
      return Column(
        children: [
          if (state.isOffline) const OfflineBar(),
          Expanded(
            child: EmptyState(
              message: 'まだ卵がありません',
              subMessage: 'クエストやポイントで卵を手に入れよう。',
              ctaLabel: 'クエストへ',
              onCta: () => context.go(AppTab.quests.path),
            ),
          ),
        ],
      );
    }

    final active = state.activeEgg;

    return Column(
      children: [
        if (state.isOffline) const OfflineBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.refresh,
            color: AppColors.primary,
            child: ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                // 育成枠3スロット（アクティブ強調 / S6）。
                Text('育成枠', style: AppType.bodyStrong),
                const SizedBox(height: AppSpace.md),
                IncubatorSlots(
                  state: state,
                  onSelectSlot: (egg) => _openDetail(context, ref, egg),
                ),
                const SizedBox(height: AppSpace.xl),

                // アクティブ卵の詳細パネル or 空枠誘導（§5-2）。
                if (active != null)
                  _ActiveEggPanel(
                    egg: active,
                    state: state,
                    onTap: () => _openDetail(context, ref, active),
                  )
                else
                  _NoActiveEggPanel(pooledPoints: state.pooledPoints),
                const SizedBox(height: AppSpace.xl),

                // 保管枠グリッド。
                Text('保管庫', style: AppType.bodyStrong),
                const SizedBox(height: AppSpace.md),
                // 保管枠アップセル（無料上限に近づいたら表示。プレミアムは非表示）。
                _StorageUpsell(storageCount: state.storage.length),
                StorageGrid(
                  state: state,
                  onSelect: (egg) => _openDetail(context, ref, egg),
                ),
                const SizedBox(height: AppSpace.xl),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _openDetail(BuildContext context, WidgetRef ref, Egg egg) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => EggDetailSheet(
        egg: egg,
        state: state,
        onSetActive: () => _runEggAction(
          context,
          () => ref.read(eggsControllerProvider.notifier).setActive(egg.id),
        ),
        onMoveToStorage: () => _runEggAction(
          context,
          () => ref.read(eggsControllerProvider.notifier).moveToStorage(egg.id),
        ),
        onMoveToIncubator: (slot) => _runEggAction(
          context,
          () => ref
              .read(eggsControllerProvider.notifier)
              .moveToIncubator(egg.id, slot),
        ),
        onHatch: () => _hatch(context, ref, egg),
      ),
    );
  }

  /// 枠操作（セット/戻す/切替）の共通実行。完了で詳細シートを閉じ、失敗は握って
  /// トーストで知らせる（リポジトリが満杯/競合/不正状態で例外を投げても未処理にしない）。
  Future<void> _runEggAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await action();
      navigator.pop();
    } catch (_) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('この操作はできませんでした。もう一度お試しください。')),
      );
    }
  }

  Future<void> _hatch(BuildContext context, WidgetRef ref, Egg egg) async {
    Navigator.of(context).pop(); // 詳細シートを閉じる
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);

    HatchResult? result;
    try {
      result = await ref.read(eggsControllerProvider.notifier).hatch(egg.id);
    } catch (_) {
      // エラー: ptを消費せずリトライ可能（二重孵化しない / §5-2）。
      messenger.showSnackBar(
        const SnackBar(content: Text('孵化に失敗しました。もう一度お試しください。')),
      );
      return;
    }

    // オフライン: 孵化確定はオンラインのみ（S8）。
    if (result == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('孵化はオンラインで確定します。接続したら確定されます。')),
      );
      return;
    }

    if (!context.mounted) return;
    final hatched = result;

    // ファネル: 孵化（コアループの山場 / PRD §5-5）。生データ（pt等）は載せず、
    // レアリティ・色違いのカテゴリ値のみ（PII/生データ非送信 / OBSERVABILITY_SETUP.md）。
    final analytics = ref.read(analyticsProvider);
    analytics.capture(
      AnalyticsEvents.eggHatched,
      properties: {
        AnalyticsProps.mofiRarity: hatched.species.rarity.wire,
        AnalyticsProps.isShiny: hatched.isShiny,
      },
    );
    if (hatched.isShiny) {
      // 色違いは専用集計（グロースの種 / S13）。
      analytics.capture(AnalyticsEvents.shinyHatched);
    }
    if (hatched.isNewDexEntry) {
      // ファネル: 図鑑への新規登録（コレクション進捗 / PRD §5-5）。
      analytics.capture(
        AnalyticsEvents.dexRegistered,
        properties: {AnalyticsProps.mofiRarity: hatched.species.rarity.wire},
      );
    }

    // 孵化演出オーバーレイ（操作ロック / スキップ可）。
    await navigator.push<void>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => HatchOverlay(
          result: hatched,
          onClose: () => navigator.maybePop(),
          onGoToDex: () {
            navigator.maybePop();
            router.go(AppTab.collection.path);
          },
          onShare: (imageBytes) async {
            // S13 グロースの種: 結果カードのキャプチャ画像 + 文面をSNSへ共有。
            // 画像生成・共有はサービスに委譲（プラグイン依存の隔離 / ベストエフォート）。
            final text = buildHatchShareText(hatched);
            final ok = await ref.read(hatchShareServiceProvider).shareHatch(
                  text: text,
                  subject: buildHatchShareSubject(hatched),
                  imageBytes: imageBytes,
                );
            // 失敗/未対応時のフォールバック: 文面をクリップボードへコピーしトースト通知
            // （拡散の起点を完全には失わせない / プラットフォーム未対応時の分岐）。
            if (!ok) {
              await Clipboard.setData(ClipboardData(text: text));
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('シェア用のテキストをコピーしました。'),
                ),
              );
            }
          },
        ),
      ),
    );
  }
}

/// アクティブ卵の主役パネル（孵化進捗 + 孵化ボタン）。
class _ActiveEggPanel extends StatelessWidget {
  const _ActiveEggPanel({
    required this.egg,
    required this.state,
    required this.onTap,
  });

  final Egg egg;
  final EggsState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final params = state.params;
    final stage = egg.stage(params);
    final rarity = RarityVisuals.ofEgg(egg.rarity);

    return Semantics(
      button: true,
      container: true,
      label: '育成中の卵の詳細を開く',
      child: GestureDetector(
        onTap: onTap,
        child: NestPanel(
          diameter: 180,
          glow: egg.isNearHatch(params) ? rarity.glow : null,
          caption: Text(
            egg.canHatch(params)
                ? 'まもなく孵化'
                : '孵化まであと ${egg.remaining(params)}pt',
            style: AppType.title,
          ),
          subject: EggSubject(rarity: egg.rarity, stage: stage),
          footer: Column(
            children: [
              GrowthProgressBar(value: egg.progress(params)),
              const SizedBox(height: AppSpace.sm),
              Text(
                '${stage.label}・${(egg.progress(params) * 100).round()}%',
                style: AppType.numLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 保管枠アップセル（無料上限に近づいたらペイウォールへ誘導）。
///
/// 表示条件: クライアント非プレミアム かつ 保管数が無料上限の8割以上。
/// しきい値・上限は [StorageLimits]（SSOT）を参照しハードコードしない。
/// 注意（信頼境界）: ここはあくまで導線。実際の保管枠ガード（200解放）はサーバー検証が正。
class _StorageUpsell extends ConsumerWidget {
  const _StorageUpsell({required this.storageCount});
  final int storageCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPremium = ref.watch(isPremiumProvider);
    if (isPremium) return const SizedBox.shrink();

    const freeLimit = StorageLimits.freeStorageSlots;
    // 上限の8割（= freeLimit * 4 / 5）に達したら訴求。マジックナンバーを避け整数演算。
    const threshold = (freeLimit * 4) ~/ 5;
    if (storageCount < threshold) return const SizedBox.shrink();

    final atLimit = storageCount >= freeLimit;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: const BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: AppRadius.lgR,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.workspace_premium_rounded,
                  color: AppColors.primaryDeep,
                  size: 20,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    atLimit ? '保管庫がいっぱいです' : '保管庫の空きが少なくなっています',
                    style: AppType.bodyStrong,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'プレミアムなら保管枠が '
              '${StorageLimits.freeStorageSlots} → ${StorageLimits.premiumStorageSlots} に。'
              'たっぷり集められます。',
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpace.md),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => context.push(PaywallScreen.routePath),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryDeep,
                ),
                child: const Text('プレミアムを見る'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// アクティブ卵が無い（空枠誘導 / §5-2 空状態）。
class _NoActiveEggPanel extends StatelessWidget {
  const _NoActiveEggPanel({required this.pooledPoints});
  final int pooledPoints;

  @override
  Widget build(BuildContext context) {
    return NestPanel(
      diameter: 160,
      dimmed: true,
      subject: const NestPlaceholder(),
      caption: Text('育てる卵を選ぼう', style: AppType.title),
      footer: Text(
        pooledPoints > 0
            ? '$pooledPoints pt ためてあるよ。卵をセットすると使えます。'
            : '保管庫の卵を育成枠にセットしてください。',
        style: AppType.caption,
        textAlign: TextAlign.center,
      ),
    );
  }
}

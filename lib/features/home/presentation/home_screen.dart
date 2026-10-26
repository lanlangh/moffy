import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/navigation/tab_scroll.dart';
import '../../../core/constants/remote_config.dart';
import '../../../core/navigation/app_tab.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/usage/usage_models.dart';
import '../../../core/usage/usage_providers.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/state_views.dart';
import '../../paywall/presentation/paywall_screen.dart';
import '../data/usual_minutes_repository.dart';
import '../domain/home_state.dart';
import 'home_controller.dart';
import 'widgets/active_egg_panel.dart';
import 'widgets/app_usage_chips.dart';
import 'widgets/daily_result_card.dart';
import 'widgets/home_activity.dart';
import 'widgets/usual_minutes_sheet.dart';
import 'widgets/warmup_celebration.dart';

/// ホーム画面（最も開く画面 / SCREEN_FLOWS §2）。
///
/// 5状態の出し分け（受け入れ §5-1）:
///   * ローディング: AsyncValue.loading -> 巣リング型スケルトン（全画面ブロックしない）。
///   * エラー(致命): AsyncValue.error -> ErrorView + リトライ。
///   * ハッピー/権限なし/空/マイナス/オフライン: data 内で局所的に出し分け。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  static const String routeName = 'home';

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _promptScheduled = false;

  @override
  void initState() {
    super.initState();
    // 0018: 既存ユーザーには「ふだんのSNS時間」を1回だけ聞く（スキップ可 / §2-1）。
    // オンボーディングで答えた新規ユーザーには出ない（asked フラグが立っている）。
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_maybeAskUsualMinutes()),
    );
  }

  Future<void> _maybeAskUsualMinutes() async {
    if (_promptScheduled || !mounted) return;
    _promptScheduled = true;
    final repo = ref.read(usualMinutesRepositoryProvider);
    if (await repo.hasBeenAsked()) return;
    final params = await ref.read(economyParamsProvider.future);
    if (!mounted) return;
    await showUsualMinutesSheet(
      context,
      choices: params.usualMinutesChoices,
      onDone: (minutes) =>
          ref.read(homeControllerProvider.notifier).reportUsualMinutes(minutes),
    );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(homeControllerProvider);
    final controller = ref.read(homeControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: async.when(
          // ローディング: 巣リング型スケルトン（SCREEN_FLOWS §7）。
          loading: () => const Center(
            child: NestSkeleton(label: '準備しています'),
          ),
          // 致命的エラー（経済パラメータ取得失敗等）: 全体リトライ。
          error: (e, _) => ErrorView(
            message: '読み込みに失敗しました。通信環境を確認してもう一度お試しください。',
            onRetry: controller.refresh,
          ),
          data: (state) => _HomeBody(
            state: state,
            scrollController: ref.watch(tabScrollControllerProvider(AppTab.home)),
            onRefresh: controller.refresh,
            onRequestPermission: controller.requestPermissionAndReload,
            // 判定できるまで（loading/error）は警告を出さない側に倒す。
            hasAppSelection:
                ref.watch(hasAppSelectionProvider).valueOrNull ?? true,
            onPickApps: controller.pickAppsAndReload,
          ),
        ),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody({
    required this.state,
    required this.scrollController,
    required this.onRefresh,
    required this.onRequestPermission,
    required this.hasAppSelection,
    required this.onPickApps,
  });

  final HomeState state;

  /// 下タブの再タップで先頭へ戻すための controller（[tabScrollControllerProvider]）。
  final ScrollController scrollController;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRequestPermission;

  /// 対象アプリ（iOS の「見守るアプリ」）が選ばれているか。
  final bool hasAppSelection;
  final Future<void> Function() onPickApps;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // オフライン上端バー（S8 / SCREEN_FLOWS §7）。
        if (state.isOffline) const OfflineBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            color: AppColors.primary,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                _TopBar(state: state),
                const SizedBox(height: AppSpace.xl),

                // F-01 付与成功: 祝福カード（初日体験 / S1）。未対象/エラー/オフラインは出さない。
                if (state.showWarmupCelebration) ...[
                  WarmupCelebration(grant: state.warmupGrant!),
                  const SizedBox(height: AppSpace.xl),
                ],

                // 主役: 育成卵（5段階＋段階アップ演出）or 空枠誘導（§5-2）。
                ActiveEggPanel(
                  state: state,
                  onSetEgg: () => context.go(AppTab.eggs.path),
                  // 孵化できる状態のときだけ出る。たまご画面へ送る（そこで卵をタップ）。
                  onHatch: () => context.go(AppTab.eggs.path),
                ),
                const SizedBox(height: AppSpace.xl),

                // きのうの結果＋きょうのペース（0018 §4-5）。権限なし/未選択はこの中でフォールバック。
                DailyResultCard(
                  state: state,
                  onRequestPermission: () => onRequestPermission(),
                  hasAppSelection: hasAppSelection,
                  onPickApps: () => onPickApps(),
                ),
                const SizedBox(height: AppSpace.lg),

                // 今日のクエスト（ストリーク＋上位2件）＋コレクション達成率。
                // 毎日の動機づけ・収集導線（ユーザーFB: ホームの情報量を増やす）。
                HomeQuestsCard(
                  onSeeAll: () => context.go(AppTab.quests.path),
                ),
                const SizedBox(height: AppSpace.lg),
                HomeCollectionCard(
                  onOpen: () => context.go(AppTab.collection.path),
                ),
                const SizedBox(height: AppSpace.lg),

                // プレミアム導線（非プレミアムのみ表示・実提供特典のみ訴求 / 磨き込み②）。
                // 非表示時（加入者）は shrink し、上の間隔だけ残る（二重の空きを作らない）。
                HomePremiumCard(
                  onOpen: () => context.push(
                    PaywallScreen.pathWithSource(PaywallSource.home),
                  ),
                ),

                // 対象4アプリ別の利用時間（権限ありかつ取得済みのみ）。
                // ⚠️ アプリ別内訳が取れるのは Android（exactMinutes）だけ。iOS は
                //    アプリを識別できず全アプリ0分のチップが4枚並んでいた
                //    （削減できているのに「0分」と出る嘘 / docs/IOS_SCREENTIME.md）。
                //    Platform.isIOS ではなく計測モードで分岐する（Web/テストでも壊れない）。
                if (!state.isPermissionMissing && state.todayUsage != null) ...[
                  if (state.todayUsage!.mode == UsageMode.exactMinutes) ...[
                    Text('アプリ別', style: AppType.bodyStrong),
                    const SizedBox(height: AppSpace.sm),
                    AppUsageChips(
                      perAppMinutes: state.todayUsage!.perAppMinutes,
                      mode: state.todayUsage!.mode,
                    ),
                    const SizedBox(height: AppSpace.lg),
                  ] else ...[
                    Text(
                      'iPhoneではスクリーンタイムの仕組み上、アプリごとの内訳は取得できません。'
                      '合計時間だけを見ています。',
                      style: AppType.caption,
                    ),
                    const SizedBox(height: AppSpace.lg),
                  ],
                ],
                // 「卵を育てる」CTAは撤去（下タブ「たまご」＋空状態の「卵をセットする」と
                // 重複していたため / ユーザーFB）。育成はたまごタブに集約。
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// トップバー: ロゴ + 通貨バッジ（キャッシュ即時表示 / SCREEN_FLOWS §2-1）。
class _TopBar extends StatelessWidget {
  const _TopBar({required this.state});

  final HomeState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text('Moffy', style: AppType.display),
        const Spacer(),
        StatBadge(
          icon: Icons.bolt_rounded,
          value: state.pointBalance,
          color: AppColors.primarySoft,
          iconColor: AppColors.primary,
        ),
        const SizedBox(width: AppSpace.sm),
        StatBadge(
          icon: Icons.diamond_rounded,
          value: state.gemBalance,
          color: AppColors.successSoft,
          iconColor: AppColors.successDeep,
        ),
      ],
    );
  }
}

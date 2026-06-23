import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/navigation/app_tab.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/state_views.dart';
import '../domain/home_state.dart';
import 'home_controller.dart';
import 'widgets/active_egg_panel.dart';
import 'widgets/app_usage_chips.dart';
import 'widgets/reduction_card.dart';
import 'widgets/warmup_celebration.dart';

/// ホーム画面（最も開く画面 / SCREEN_FLOWS §2）。
///
/// 5状態の出し分け（受け入れ §5-1）:
///   * ローディング: AsyncValue.loading -> 巣リング型スケルトン（全画面ブロックしない）。
///   * エラー(致命): AsyncValue.error -> ErrorView + リトライ。
///   * ハッピー/権限なし/空/マイナス/オフライン: data 内で局所的に出し分け。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const String routeName = 'home';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            onRefresh: controller.refresh,
            onRequestPermission: controller.requestPermissionAndReload,
          ),
        ),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody({
    required this.state,
    required this.onRefresh,
    required this.onRequestPermission,
  });

  final HomeState state;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onRequestPermission;

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
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                _TopBar(state: state),
                const SizedBox(height: AppSpace.xl),

                // F-01 付与成功: 祝福カード（初日体験 / S1）。未対象/エラー/オフラインは出さない。
                if (state.showWarmupCelebration) ...[
                  WarmupCelebration(grant: state.warmupGrant!),
                  const SizedBox(height: AppSpace.xl),
                ],

                // 主役: 育成卵 or 空枠誘導（§5-2）。
                ActiveEggPanel(
                  state: state,
                  onSetEgg: () => context.go(AppTab.eggs.path),
                ),
                const SizedBox(height: AppSpace.xl),

                // 今日の削減カード（権限/ウォームアップ/マイナス/ハッピー出し分け）。
                ReductionCard(
                  state: state,
                  onRequestPermission: () => onRequestPermission(),
                ),
                const SizedBox(height: AppSpace.lg),

                // 対象4アプリ別の利用時間（権限ありかつ取得済みのみ）。
                if (!state.isPermissionMissing &&
                    !state.isWarmup &&
                    state.todayUsage != null) ...[
                  Text('アプリ別', style: AppType.bodyStrong),
                  const SizedBox(height: AppSpace.sm),
                  AppUsageChips(
                    perAppMinutes: state.todayUsage!.perAppMinutes,
                  ),
                  const SizedBox(height: AppSpace.lg),
                ],

                // 主CTA: 卵を育てる（→ たまご画面）。
                PrimaryButton(
                  label: '卵を育てる',
                  icon: Icons.egg_rounded,
                  onPressed: () => context.go(AppTab.eggs.path),
                ),
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

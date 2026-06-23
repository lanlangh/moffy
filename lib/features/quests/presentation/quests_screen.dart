import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/state_views.dart';
import '../domain/quest_models.dart';
import 'quests_controller.dart';
import 'widgets/quest_card.dart';
import 'widgets/streak_header.dart';

/// クエスト画面（SCREEN_FLOWS §5）。デイリー/ウィークリー + ストリーク倍率 + 報酬受取。
///
/// 5状態:
///   * ローディング: AsyncValue.loading → 巣リング型スケルトン。
///   * エラー: AsyncValue.error → ErrorView + リトライ。
///   * ハッピー/空: data 内で「クエストあり / 生成前 / 全クリア」を出し分け。
///   * オフライン: 上端バー + 受取ボタンのグレーアウト（残高操作=オンライン確定 / S8）。
class QuestsScreen extends ConsumerStatefulWidget {
  const QuestsScreen({super.key});

  static const String routeName = 'quests';

  @override
  ConsumerState<QuestsScreen> createState() => _QuestsScreenState();
}

class _QuestsScreenState extends ConsumerState<QuestsScreen> {
  /// 受取処理中のクエストID（多重タップ防止 / カード単位のスピナー）。
  String? _claimingId;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(questsControllerProvider);
    final controller = ref.read(questsControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('クエスト')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () =>
              const Center(child: NestSkeleton(label: '今日のクエスト準備中')),
          error: (e, _) => ErrorView(
            message: 'クエストの読み込みに失敗しました。通信環境を確認してもう一度お試しください。',
            onRetry: controller.refresh,
          ),
          data: (state) => _QuestsBody(
            state: state,
            claimingId: _claimingId,
            onClaim: _onClaim,
            onRefresh: controller.refresh,
          ),
        ),
      ),
    );
  }

  Future<void> _onClaim(Quest quest) async {
    setState(() => _claimingId = quest.id);
    final messenger = ScaffoldMessenger.of(context);
    final failure =
        await ref.read(questsControllerProvider.notifier).claim(quest.id);
    if (!mounted) return;
    setState(() => _claimingId = null);
    if (failure != null) {
      // エラー: 二重付与せずリトライ可能（§5-3）。責めない文言。
      messenger.showSnackBar(SnackBar(content: Text(failure.message)));
    }
  }
}

class _QuestsBody extends StatelessWidget {
  const _QuestsBody({
    required this.state,
    required this.claimingId,
    required this.onClaim,
    required this.onRefresh,
  });

  final QuestsState state;
  final String? claimingId;
  final void Function(Quest) onClaim;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    // 生成前の空状態（SCREEN_FLOWS §5）。
    if (state.isEmpty) {
      return Column(
        children: [
          if (state.isOffline) const OfflineBar(),
          const Expanded(
            child: EmptyState(
              icon: Icons.flag_outlined,
              message: '今日のクエストを準備中',
              subMessage: 'もう少しでデイリー/ウィークリークエストが届きます。',
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        if (state.isOffline) const OfflineBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: onRefresh,
            color: AppColors.primary,
            child: ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                // ストリークヘッダ（連続日数 + 倍率 / S14）。
                StreakHeader(streak: state.streak),
                const SizedBox(height: AppSpace.xl),

                // 全クリア時の祝福（空状態の一種 / SCREEN_FLOWS §5）。
                if (state.isAllCompleted) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpace.lg),
                    decoration: const BoxDecoration(
                      color: AppColors.successSoft,
                      borderRadius: AppRadius.lgR,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.celebration_rounded,
                          color: AppColors.successDeep,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Text(
                            '今日のクエストは全部クリア！また明日。',
                            style: AppType.bodyStrong,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpace.xl),
                ],

                if (state.daily.isNotEmpty) ...[
                  Text('デイリー', style: AppType.title),
                  const SizedBox(height: AppSpace.md),
                  ..._questCards(state.daily),
                  const SizedBox(height: AppSpace.xl),
                ],
                if (state.weekly.isNotEmpty) ...[
                  Text('ウィークリー', style: AppType.title),
                  const SizedBox(height: AppSpace.md),
                  ..._questCards(state.weekly),
                ],
                const SizedBox(height: AppSpace.xl),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _questCards(List<Quest> quests) {
    return [
      for (final q in quests) ...[
        QuestCard(
          quest: q,
          claiming: claimingId == q.id,
          // 受取可能かつオンライン時のみ有効。オフラインは null でグレーアウト（S8）。
          onClaim: (q.isClaimable && !state.isOffline) ? () => onClaim(q) : null,
        ),
        const SizedBox(height: AppSpace.md),
      ],
    ];
  }
}

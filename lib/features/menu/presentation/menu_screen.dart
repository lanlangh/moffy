import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/iap/iap_providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/state_views.dart';
import '../../paywall/presentation/paywall_screen.dart';
import '../../profile/data/profile_repository.dart';
import '../../profile/domain/legal_links.dart';
import '../../profile/domain/profile_models.dart';
import '../../profile/presentation/account_link_screen.dart';
import '../../profile/presentation/delete_account_screen.dart';
import '../../profile/presentation/notification_settings_screen.dart';

/// メニュー画面（SCREEN_FLOWS §6）。プロフィール統計 + 設定 + アカウント連携 + 退会導線。
///
/// 5状態:
///   * ローディング: AsyncValue.loading → スケルトン。
///   * エラー: 統計読み込み失敗 → ErrorView + リトライ。
///   * ハッピー/空: data 内で統計表示（全0でも「これから集めよう」）。
///   * オフライン: 上端バー + 連携/退会導線のグレーアウト（オンライン必須 / S10,S12）。
class MenuScreen extends ConsumerWidget {
  const MenuScreen({super.key});

  static const String routeName = 'menu';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(profileStateProvider);
    // クライアント側のプレミアム状態（即時UI反映 / 機能解放の正はサーバー）。
    final isPremium = ref.watch(isPremiumProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('メニュー')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const Center(child: NestSkeleton(label: '読み込み中')),
          error: (e, _) => ErrorView(
            message: 'プロフィールの読み込みに失敗しました。通信環境を確認してもう一度お試しください。',
            onRetry: () => ref.invalidate(profileStateProvider),
          ),
          data: (state) => _MenuBody(state: state, isPremium: isPremium),
        ),
      ),
    );
  }
}

class _MenuBody extends StatelessWidget {
  const _MenuBody({required this.state, required this.isPremium});
  final ProfileState state;
  final bool isPremium;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (state.isOffline) const OfflineBar(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              // プロフィール統計（SCREEN_FLOWS §6 / 数字はBaloo）。
              _StatsSection(stats: state.stats),
              const SizedBox(height: AppSpace.xl),

              // アカウント連携（S10）。匿名のままでも使える旨を明示。
              Text('アカウント', style: AppType.title),
              const SizedBox(height: AppSpace.md),
              _MenuTile(
                icon: Icons.link_rounded,
                title: state.account.isLinked ? 'アカウント連携済み' : 'アカウントを引き継ぐ（任意）',
                subtitle: state.account.isLinked
                    ? null
                    : '機種変更や再インストールに備えて連携できます',
                onTap: () => context.push(AccountLinkScreen.routePath),
              ),
              const SizedBox(height: AppSpace.xl),

              // 設定（S9 通知 / 法務 / フィードバック）。
              Text('設定', style: AppType.title),
              const SizedBox(height: AppSpace.md),
              _MenuTile(
                icon: Icons.notifications_none_rounded,
                title: '通知設定',
                subtitle: '5種類の通知を個別にON/OFF',
                onTap: () => context.push(NotificationSettingsScreen.routePath),
              ),
              _MenuTile(
                icon: Icons.workspace_premium_outlined,
                title: isPremium ? 'プレミアム（加入中）' : 'プレミアムにする',
                subtitle: isPremium
                    ? '特典が解放されています'
                    : '保管枠アップ・限定Mofi・プレミアム卵',
                onTap: () => context.push(PaywallScreen.routePath),
              ),
              const SizedBox(height: AppSpace.xl),

              // 法務文書（SCREEN_FLOWS §6 / §5-6）。URLはプレースホルダ定数（SSOT）。
              Text('情報', style: AppType.title),
              const SizedBox(height: AppSpace.md),
              const _MenuTile(
                icon: Icons.privacy_tip_outlined,
                title: 'プライバシーポリシー',
                // TODO(法務): LegalLinks.privacyPolicy を url_launcher で開く。
                onTap: null,
              ),
              const _MenuTile(
                icon: Icons.description_outlined,
                title: '利用規約',
                onTap: null, // TODO: LegalLinks.termsOfService を開く。
              ),
              const _MenuTile(
                icon: Icons.receipt_long_outlined,
                title: '特定商取引法に基づく表記',
                onTap: null, // TODO: LegalLinks.commercialTransactions を開く。
              ),
              const _MenuTile(
                icon: Icons.mail_outline_rounded,
                title: 'お問い合わせ',
                subtitle: LegalLinks.supportEmail,
                onTap: null, // TODO: LegalLinks.supportMailto を開く。
              ),
              const SizedBox(height: AppSpace.xxl),

              // 退会導線（S12 / 審査必須）。控えめに最下部（SCREEN_FLOWS §6）。
              Center(
                child: TextButton(
                  onPressed: () => context.push(DeleteAccountScreen.routePath),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSecondary,
                  ),
                  child: const Text('アカウント削除'),
                ),
              ),
              const SizedBox(height: AppSpace.xl),
            ],
          ),
        ),
      ],
    );
  }
}

/// プロフィール統計セクション（5指標 / 数字はBaloo）。
class _StatsSection extends StatelessWidget {
  const _StatsSection({required this.stats});
  final ProfileStats stats;

  @override
  Widget build(BuildContext context) {
    // 全0でも空状態にせず「これから集めよう」を見せる（SCREEN_FLOWS §6）。
    final reducedLabel = stats.isFresh
        ? '0分'
        : '${stats.reducedHours}時間${stats.reducedMinutesPart}分';

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('プロフィール', style: AppType.title),
          if (stats.isFresh) ...[
            const SizedBox(height: AppSpace.sm),
            Text('これから記録を集めていきましょう。', style: AppType.caption),
          ],
          const SizedBox(height: AppSpace.lg),
          Wrap(
            spacing: AppSpace.lg,
            runSpacing: AppSpace.lg,
            children: [
              _StatItem(label: '総削減時間', value: reducedLabel),
              _StatItem(label: '獲得Mofi', value: '${stats.totalMofi}'),
              _StatItem(
                label: '図鑑達成率',
                value: '${stats.dexDiscovered}/${stats.dexTotal}',
              ),
              _StatItem(label: '最長ストリーク', value: '${stats.longestStreak}日'),
              _StatItem(label: '累計ポイント', value: '${stats.totalPoints}'),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 数字は Baloo（numLabel）。
          Text(value, style: AppType.numLabel),
          const SizedBox(height: AppSpace.xs),
          Text(label, style: AppType.caption),
        ],
      ),
    );
  }
}

/// メニュー項目タイル。onTap=null で「準備中」グレーアウト。
class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color =
        disabled ? AppColors.textDisabled : AppColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Material(
        color: AppColors.surface,
        borderRadius: AppRadius.lgR,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.lgR,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              children: [
                Icon(icon, color: disabled ? AppColors.textDisabled : AppColors.primary),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: AppType.bodyStrong.copyWith(color: color)),
                      if (subtitle != null) ...[
                        const SizedBox(height: AppSpace.xs),
                        Text(subtitle!, style: AppType.caption),
                      ],
                    ],
                  ),
                ),
                if (!disabled)
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textSecondary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

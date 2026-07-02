import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/feature_flags.dart';
import '../../../core/iap/iap_providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/egg_art.dart';
import '../../../core/widgets/nest_panel.dart';
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
              // 署名要素「巣リング」をプロフィール頭に反復（全画面共通の核 / DESIGN_DIRECTION）。
              const Center(
                child: NestRing(
                  diameter: 112,
                  child: EggArt(rarity: RarityToken.common),
                ),
              ),
              const SizedBox(height: AppSpace.xl),
              // プロフィール統計（SCREEN_FLOWS §6 / 数字はBaloo）。
              _StatsSection(stats: state.stats),
              const SizedBox(height: AppSpace.xl),

              // アカウント（S10）。v1.0 は連携未対応（kAccountLinkingEnabled=false）。
              // 行き止まりを作らず、匿名運用（機種変でデータ復元不可）を明示する。
              Text('アカウント', style: AppType.title),
              const SizedBox(height: AppSpace.md),
              if (kAccountLinkingEnabled)
                _MenuTile(
                  icon: Icons.link_rounded,
                  title:
                      state.account.isLinked ? 'アカウント連携済み' : 'アカウントを引き継ぐ（任意）',
                  subtitle: state.account.isLinked
                      ? null
                      : '機種変更や再インストールに備えて連携できます',
                  onTap: () => context.push(AccountLinkScreen.routePath),
                )
              else
                const _MenuInfoTile(
                  icon: Icons.person_outline_rounded,
                  title: '匿名アカウントで利用中',
                  body: 'データはこの端末で管理しています。機種変更やアプリの削除をすると、'
                      'Mofiや図鑑は復元できません。アカウント連携（引き継ぎ）は今後の'
                      'アップデートで対応予定です。',
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

              // 法務文書（SCREEN_FLOWS §6 / §5-6）。URLは LegalLinks（SSOT）= Notion公開ページ。
              Text('情報', style: AppType.title),
              const SizedBox(height: AppSpace.md),
              _MenuTile(
                icon: Icons.privacy_tip_outlined,
                title: 'プライバシーポリシー',
                onTap: () => _launchUrl(context, LegalLinks.privacyPolicy),
              ),
              _MenuTile(
                icon: Icons.description_outlined,
                title: '利用規約',
                onTap: () => _launchUrl(context, LegalLinks.termsOfService),
              ),
              _MenuTile(
                icon: Icons.receipt_long_outlined,
                title: '特定商取引法に基づく表記',
                onTap: () => _launchUrl(context, LegalLinks.commercialTransactions),
              ),
              _MenuTile(
                icon: Icons.mail_outline_rounded,
                title: 'お問い合わせ',
                subtitle: LegalLinks.supportEmail,
                onTap: () => _launchUrl(context, LegalLinks.supportMailto),
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

/// 情報提示用の非操作タイル（タップ不可・グレーアウトに見せない）。
/// 「準備中（disabled）」とは区別し、意図した案内として通常色で表示する。
class _MenuInfoTile extends StatelessWidget {
  const _MenuInfoTile({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: AppCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppColors.primary),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppType.bodyStrong),
                  const SizedBox(height: AppSpace.xs),
                  Text(body, style: AppType.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 法務リンク/問い合わせを外部アプリで開く（url_launcher）。
/// http(s) は外部ブラウザ、mailto は既定のメールアプリ。失敗時は握ってSnackBar通知（クラッシュさせない）。
Future<void> _launchUrl(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  final mode = uri.scheme == 'mailto'
      ? LaunchMode.platformDefault
      : LaunchMode.externalApplication;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final ok = await launchUrl(uri, mode: mode);
    if (!ok) {
      messenger.showSnackBar(
        const SnackBar(content: Text('リンクを開けませんでした。')),
      );
    }
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('リンクを開けませんでした。')),
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
          // 純粋な数字・記号(5 / 23/30)は Baloo でブランドを立て、日本語の単位を含む値
          // (23時間45分 / 7日 / 0分)は本文太字にする（Baloo は日本語グリフが無く字化けするため）。
          Text(
            value,
            style: RegExp(r'[^\x00-\x7F]').hasMatch(value)
                ? AppType.bodyStrong
                : AppType.numLabel,
          ),
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

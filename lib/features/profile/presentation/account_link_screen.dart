import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/failure.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/state_views.dart';
import '../data/account_repository.dart';
import '../data/profile_repository.dart';
import '../domain/profile_models.dart';

/// アカウント連携画面（S10）。匿名→Apple(iOS必須)/Google/メール 連携導線。
///
/// 5状態:
///   * ハッピー: 各プロバイダで連携 → 成功表示。
///   * エラー: 連携失敗 → スナックバー（責めない）。
///   * ローディング: 連携処理中はボタンにスピナー。
///   * 空: 該当なし（プロバイダは固定）。
///   * オフライン: 連携はオンライン必須 → ボタンをグレーアウト + 理由表示（S10）。
class AccountLinkScreen extends ConsumerStatefulWidget {
  const AccountLinkScreen({super.key});

  static const String routeName = 'account-link';
  static const String routePath = '/menu/account';

  @override
  ConsumerState<AccountLinkScreen> createState() => _AccountLinkScreenState();
}

class _AccountLinkScreenState extends ConsumerState<AccountLinkScreen> {
  AuthProvider? _linking; // 処理中のプロバイダ（スピナー表示）

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(isOnlineProvider);
    final profileAsync = ref.watch(profileStateProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('アカウントを引き継ぐ')),
      body: SafeArea(
        top: false,
        child: profileAsync.when(
          loading: () => const Center(child: NestSkeleton(label: '読み込み中')),
          error: (e, _) => ErrorView(
            message: 'アカウント情報の読み込みに失敗しました。',
            onRetry: () => ref.invalidate(profileStateProvider),
          ),
          data: (profile) => _body(context, profile, isOnline),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, ProfileState profile, bool isOnline) {
    final account = profile.account;

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (!isOnline) const OfflineBar(),
        const SizedBox(height: AppSpace.sm),
        Text(
          '連携すると、機種変更や再インストールのあともMofiと図鑑を引き継げます。',
          style: AppType.body,
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          '匿名のままでも今までどおり遊べます（連携は任意です）。',
          style: AppType.caption,
        ),
        const SizedBox(height: AppSpace.xl),

        if (account.isLinked)
          AppCard(
            child: Row(
              children: [
                const Icon(Icons.verified_rounded, color: AppColors.success),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    '連携済み（${account.displayIdentifier ?? account.linkedProviders.join(", ")}）',
                    style: AppType.bodyStrong,
                  ),
                ),
              ],
            ),
          )
        else ...[
          // Apple は iOS で必須（他社ソーシャルを出す場合 4.8/5.1）。
          // Android では Google + メールで開始（iOS追従時に Apple を追加 / S10）。
          if (_showApple)
            _LinkButton(
              provider: AuthProvider.apple,
              icon: Icons.apple_rounded,
              busy: _linking == AuthProvider.apple,
              enabled: isOnline && _linking == null,
              onTap: () => _link(AuthProvider.apple),
            ),
          _LinkButton(
            provider: AuthProvider.google,
            icon: Icons.g_mobiledata_rounded,
            busy: _linking == AuthProvider.google,
            enabled: isOnline && _linking == null,
            onTap: () => _link(AuthProvider.google),
          ),
          _LinkButton(
            provider: AuthProvider.email,
            icon: Icons.mail_outline_rounded,
            busy: _linking == AuthProvider.email,
            enabled: isOnline && _linking == null,
            onTap: () => _link(AuthProvider.email),
          ),
          if (!isOnline) ...[
            const SizedBox(height: AppSpace.md),
            Text(
              '連携には接続が必要です。',
              style: AppType.caption.copyWith(color: AppColors.offline),
            ),
          ],
        ],
      ],
    );
  }

  /// Apple ボタンを出すか（iOS のみ / S10）。Web は対象外。
  bool get _showApple =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _link(AuthProvider provider) async {
    setState(() => _linking = provider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(accountRepositoryProvider).linkProvider(provider);
      if (!mounted) return;
      // 連携状態を反映（プロフィール再読込）。
      ref.invalidate(profileStateProvider);
      messenger.showSnackBar(
        const SnackBar(content: Text('アカウントを連携しました。')),
      );
    } on Failure catch (f) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(f.message)));
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('連携に失敗しました。もう一度お試しください。')),
      );
    } finally {
      if (mounted) setState(() => _linking = null);
    }
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({
    required this.provider,
    required this.icon,
    required this.busy,
    required this.enabled,
    required this.onTap,
  });

  final AuthProvider provider;
  final IconData icon;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: busy
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpace.md),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
              ),
            )
          : PrimaryButton(
              label: provider.label,
              icon: icon,
              onPressed: enabled ? onTap : null, // オフラインはグレーアウト（S10）
            ),
    );
  }
}

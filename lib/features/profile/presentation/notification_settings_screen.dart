import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/state_views.dart';
import '../domain/notification_settings.dart';
import 'notification_settings_controller.dart';

/// 通知設定画面（S9）。5種の個別ON/OFF。
///
/// 5状態:
///   * ローディング: AsyncValue.loading → スケルトン。
///   * エラー: 読み込み失敗 → ErrorView（保存はローカルなので稀）。
///   * ハッピー: 5種のトグル。
///   * 空: 該当なし（5種は固定）。
///   * オフライン: 設定はローカル保存のため、オフラインでも操作可能（制限しない）。
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  static const String routeName = 'notification-settings';
  static const String routePath = '/menu/notifications';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(notificationSettingsControllerProvider);
    final controller =
        ref.read(notificationSettingsControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('通知設定')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const Center(child: NestSkeleton(label: '読み込み中')),
          error: (e, _) => ErrorView(
            message: '通知設定の読み込みに失敗しました。',
            onRetry: () =>
                ref.invalidate(notificationSettingsControllerProvider),
          ),
          data: (settings) => ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Text(
                '通知は設定後、コアループを一度体験したあとにOSへ許可をお願いします。',
                style: AppType.caption,
              ),
              const SizedBox(height: AppSpace.lg),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final kind in NotificationKind.values)
                      _NotificationTile(
                        kind: kind,
                        value: settings.isEnabled(kind),
                        onChanged: (v) => controller.toggle(kind, v),
                        showDivider: kind != NotificationKind.values.last,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.kind,
    required this.value,
    required this.onChanged,
    required this.showDivider,
  });

  final NotificationKind kind;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SwitchListTile.adaptive(
          contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
          activeThumbColor: AppColors.primary,
          title: Text(kind.label, style: AppType.bodyStrong),
          subtitle: Text(kind.description, style: AppType.caption),
          value: value,
          onChanged: onChanged,
        ),
        if (showDivider)
          const Divider(height: 1, color: AppColors.divider, indent: AppSpace.lg, endIndent: AppSpace.lg),
      ],
    );
  }
}

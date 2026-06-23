import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/error/failure.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/state_views.dart';
import '../data/account_repository.dart';
import '../domain/legal_links.dart';

/// 退会導線（S12 / 審査必須）。SCREEN_FLOWS §6 のフローを実装。
///
/// フロー: 影響説明 → 最終確認（誤操作防止に入力要求）→ 削除実行 → サブスク解約案内 → 完了。
///
/// 5状態:
///   * ハッピー: 影響説明→確認→削除→サブスク案内→完了。
///   * エラー: 削除API失敗 → 「削除できませんでした」。データは消さない（中途半端な削除を防ぐ）。
///   * ローディング: 削除実行中はフルスクリーンで操作ロック + 「削除しています」。
///   * 空: 該当なし。
///   * オフライン: 削除はオンライン必須 → ボタンをグレーアウト + 理由表示（S12）。
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  static const String routeName = 'delete-account';
  static const String routePath = '/menu/delete';

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

/// 退会フローのステップ。
enum _DeleteStep { impact, confirm, subscription, done }

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  _DeleteStep _step = _DeleteStep.impact;
  final TextEditingController _confirmText = TextEditingController();
  bool _deleting = false;

  /// 誤操作防止に入力を求めるキーワード（SCREEN_FLOWS §6）。
  static const String _confirmKeyword = '削除';

  @override
  void initState() {
    super.initState();
    _confirmText.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _confirmText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(isOnlineProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('アカウント削除'),
        automaticallyImplyLeading: !_deleting, // 削除中は戻れない（操作ロック）
      ),
      body: SafeArea(
        top: false,
        child: _deleting
            ? const Center(child: NestSkeleton(label: '削除しています'))
            : _buildStep(context, isOnline),
      ),
    );
  }

  Widget _buildStep(BuildContext context, bool isOnline) {
    return switch (_step) {
      _DeleteStep.impact => _ImpactView(
          isOnline: isOnline,
          onContinue: () => setState(() => _step = _DeleteStep.confirm),
          onCancel: () => Navigator.of(context).pop(),
        ),
      _DeleteStep.confirm => _ConfirmView(
          controller: _confirmText,
          keyword: _confirmKeyword,
          canDelete:
              isOnline && _confirmText.text.trim() == _confirmKeyword,
          isOnline: isOnline,
          onCancel: () => Navigator.of(context).pop(),
          onDelete: _execute,
        ),
      _DeleteStep.subscription => _SubscriptionNoticeView(
          onDone: () => setState(() => _step = _DeleteStep.done),
        ),
      _DeleteStep.done => _DoneView(
          onClose: () => Navigator.of(context).pop(),
        ),
    };
  }

  Future<void> _execute() async {
    setState(() => _deleting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(accountRepositoryProvider).deleteAccount();
      if (!mounted) return;
      // 成功 → サブスク解約案内へ（S12: アプリから解約不可と明示）。
      setState(() {
        _deleting = false;
        _step = _DeleteStep.subscription;
      });
    } on Failure catch (f) {
      if (!mounted) return;
      setState(() => _deleting = false);
      // エラー: データは消さない（中途半端な削除を防ぐ / §5-4）。
      messenger.showSnackBar(SnackBar(content: Text(f.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _deleting = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('削除できませんでした。もう一度お試しください。')),
      );
    }
  }
}

/// D2 影響説明（SCREEN_FLOWS §6）。消えるものをアイコンで列挙・責めず事務的に。
class _ImpactView extends StatelessWidget {
  const _ImpactView({
    required this.isOnline,
    required this.onContinue,
    required this.onCancel,
  });

  final bool isOnline;
  final VoidCallback onContinue;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (!isOnline) const OfflineBar(),
        const SizedBox(height: AppSpace.sm),
        Text('アカウントを削除すると', style: AppType.title),
        const SizedBox(height: AppSpace.md),
        Text(
          'Mofi・図鑑・購入履歴がすべて消え、復元できません。',
          style: AppType.bodyStrong.copyWith(color: AppColors.error),
        ),
        const SizedBox(height: AppSpace.lg),
        const _ImpactItem(icon: Icons.pets_rounded, label: '育てたMofiと卵'),
        const _ImpactItem(icon: Icons.menu_book_rounded, label: '図鑑の記録'),
        const _ImpactItem(icon: Icons.star_rounded, label: 'ポイント・ジェム残高'),
        const _ImpactItem(icon: Icons.timeline_rounded, label: '削減時間・ストリーク記録'),
        const SizedBox(height: AppSpace.xl),
        Text(
          'データは即時に利用できなくなり、30日以内に完全に削除されます。',
          style: AppType.caption,
        ),
        const SizedBox(height: AppSpace.xl),
        PrimaryButton(
          label: '削除を続ける',
          onPressed: isOnline ? onContinue : null,
        ),
        if (!isOnline) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            '削除には接続が必要です。',
            style: AppType.caption.copyWith(color: AppColors.offline),
          ),
        ],
        const SizedBox(height: AppSpace.md),
        TextButton(onPressed: onCancel, child: const Text('やめる')),
      ],
    );
  }
}

class _ImpactItem extends StatelessWidget {
  const _ImpactItem({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppColors.textSecondary),
          const SizedBox(width: AppSpace.sm),
          Text(label, style: AppType.body),
        ],
      ),
    );
  }
}

/// D3 最終確認（SCREEN_FLOWS §6）。誤操作防止に「削除」と入力を必須化。
class _ConfirmView extends StatelessWidget {
  const _ConfirmView({
    required this.controller,
    required this.keyword,
    required this.canDelete,
    required this.isOnline,
    required this.onCancel,
    required this.onDelete,
  });

  final TextEditingController controller;
  final String keyword;
  final bool canDelete;
  final bool isOnline;
  final VoidCallback onCancel;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        if (!isOnline) const OfflineBar(),
        const SizedBox(height: AppSpace.sm),
        Text('最終確認', style: AppType.title),
        const SizedBox(height: AppSpace.md),
        Text('続けるには下の欄に「$keyword」と入力してください。', style: AppType.body),
        const SizedBox(height: AppSpace.lg),
        TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: keyword,
            filled: true,
            fillColor: AppColors.surface,
            border: const OutlineInputBorder(
              borderRadius: AppRadius.smR,
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        // 破壊的アクション: PrimaryButton ではなく state.error 色（SCREEN_FLOWS §6）。
        ElevatedButton(
          onPressed: canDelete ? onDelete : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.error,
            foregroundColor: AppColors.onPrimary,
            disabledBackgroundColor: AppColors.offline,
          ),
          child: const Text('削除を実行'),
        ),
        const SizedBox(height: AppSpace.md),
        TextButton(onPressed: onCancel, child: const Text('キャンセル')),
      ],
    );
  }
}

/// D6 サブスク解約案内（S12 重要）。アプリから解約不可と明示。
class _SubscriptionNoticeView extends StatelessWidget {
  const _SubscriptionNoticeView({required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        Text('サブスクの解約について', style: AppType.title),
        const SizedBox(height: AppSpace.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'アカウントを削除しても、ストアの定期購読は自動では解約されません。',
                style: AppType.bodyStrong,
              ),
              const SizedBox(height: AppSpace.sm),
              Text(
                '解約は App Store / Google Play の「定期購読の管理」から行ってください。'
                'アプリ側からは解約できません。',
                style: AppType.body,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        Text(
          'アプリを再インストールせずに削除を依頼したい場合は、'
          '${LegalLinks.accountDeletionEmail} までご連絡ください。',
          style: AppType.caption,
        ),
        const SizedBox(height: AppSpace.xl),
        PrimaryButton(label: '確認しました', onPressed: onDone),
      ],
    );
  }
}

/// D7 完了。
class _DoneView extends StatelessWidget {
  const _DoneView({required this.onClose});
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.check_rounded,
      message: '削除を受け付けました',
      subMessage: 'ご利用ありがとうございました。',
      ctaLabel: '閉じる',
      onCta: onClose,
    );
  }
}

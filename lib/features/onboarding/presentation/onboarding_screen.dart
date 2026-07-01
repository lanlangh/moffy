import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/economy.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/observability_providers.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/usage/usage_models.dart';
import '../../../core/usage/usage_provider.dart';
import '../../../core/usage/usage_providers.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/egg_art.dart';
import '../../../core/widgets/nest_panel.dart';
import '../../../core/widgets/state_views.dart';
import '../data/onboarding_repository.dart';
import 'welcome_screen.dart';

/// オンボーディング画面（SCREEN_FLOWS §1）。
///
/// フロー: OB1 価値説明 → OB2 権限の理由 → OS権限付与（UsageAccess誘導/未許可フォールバック）
///   → 対象SNS選択 → 完了でホームへ。初回のみ表示（フラグはローカル）。
///
/// 5状態（SCREEN_FLOWS §1）:
///   * ハッピー: OB1→OB2→許可→選択→ホーム。
///   * エラー: 権限取得失敗 → 「もう一度ひらく」+ 手順（権限拒否でも先へ進める二段構え）。
///   * ローディング: 権限確認中はボタンを無効化。
///   * 空状態: 権限ありでもデータ0 → ボーナス卵フロー（実利用非依存）の説明で吸収。
///   * オフライン: 匿名認証はオンライン必須 → 上端バー + 「接続すると始められます」。
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  static const String routePath = '/onboarding';
  static const String routeName = 'onboarding';

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  /// 権限要求中（ボタンの二重押下防止 / ローディング）。
  bool _requesting = false;

  /// 直近の権限状態（OB2で表示し、未許可時はフォールバック文言を出す）。
  UsagePermissionStatus? _permission;

  /// 対象SNS選択（Android: MVPは4固定。トグルで「育てる対象」を選ぶ体験 / S3）。
  /// 真のSSOTは tracked_apps（後続で永続化）。ここでは選択状態のみ保持。
  late final Map<String, bool> _selectedApps = {
    for (final t in AppConstants.defaultAndroidTargets) t.packageName: true,
  };

  /// iOS: 対象アプリは OS の FamilyActivityPicker でユーザー自身が選ぶ（不透明トークンの
  /// ため Moffy から4SNSを自動指定できない / ORG_STATE 2026-06-26）。Android のトグルとは別物。
  bool get _isIOS => !kIsWeb && Platform.isIOS;
  int _iosSelectedCount = 0;
  bool _iosPicked = false;

  static const int _pageCount = 4; // OB1 / OB2 / 権限 / 対象選択

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page < _pageCount - 1) {
      _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _requesting = true);
    try {
      final usage = ref.read(usageProviderProvider);
      final status = await usage.requestPermission();
      if (!mounted) return;
      setState(() => _permission = status);
      // ファネル: 利用時間権限の許可（PRD §5-5）。許可された時のみ発火。
      if (status.isGranted) {
        ref
            .read(analyticsProvider)
            .capture(AnalyticsEvents.usagePermissionGranted);
      }
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
    _next(); // 許可/拒否どちらでも次へ（拒否はボーナス卵で吸収 / SCREEN_FLOWS §1）。
  }

  /// iOS: OS の FamilyActivityPicker を開いて対象アプリを選ばせ、選択数を反映する。
  /// 選択は端末に永続化＋DeviceActivity 監視開始までネイティブが行う（IOSUsageProvider）。
  Future<void> _pickIOSApps() async {
    final provider = ref.read(usageProviderProvider);
    if (provider is! ScreenTimeAppSelection) return;
    // ScreenTimeAppSelection は UsageProvider のサブタイプではない（独立 capability）ため
    // 型 promotion が効かない。is! ガード済みなので明示キャストは安全。
    final screenTime = provider as ScreenTimeAppSelection;
    setState(() => _requesting = true);
    try {
      final result = await screenTime.presentAppPicker();
      if (!mounted) return;
      setState(() {
        _iosSelectedCount = result.count;
        _iosPicked = result.selected;
      });
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  Future<void> _finish() async {
    await ref.read(onboardingRepositoryProvider).markCompleted();
    ref.invalidate(onboardingCompletedProvider);
    // ファネル: オンボーディング完了（コアループ到達 / PRD §5-5）。
    ref.read(analyticsProvider).capture(AnalyticsEvents.onboardingCompleted);
    if (!mounted) return;
    // 歓迎画面（最初の卵プレゼント）を経由してホームへ（warmup はホームで付与）。
    context.go(WelcomeScreen.routePath);
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(isOnlineProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(
        children: [
          // オフライン: 匿名認証はオンライン必須（SCREEN_FLOWS §1）。
          if (!isOnline)
            const OfflineBar(message: 'オフライン・接続すると始められます'),
          Expanded(
            child: PageView(
              controller: _controller,
              physics: const NeverScrollableScrollPhysics(), // スキップ不可・順送り
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                _ValuePage(onNext: _next),
                _PermissionInfoPage(onNext: _next, isIOS: _isIOS),
                _PermissionGrantPage(
                  requesting: _requesting,
                  permission: _permission,
                  isIOS: _isIOS,
                  onGrant: _requesting ? null : _requestPermission,
                  onSkip: _next,
                ),
                if (_isIOS)
                  _IOSAppPickerPage(
                    requesting: _requesting,
                    selectedCount: _iosSelectedCount,
                    picked: _iosPicked,
                    onPick: _requesting ? null : _pickIOSApps,
                    onFinish: isOnline ? _finish : null,
                  )
                else
                  _TargetSelectPage(
                    selected: _selectedApps,
                    onToggle: (pkg) => setState(
                      () => _selectedApps[pkg] = !(_selectedApps[pkg] ?? false),
                    ),
                    onFinish: isOnline ? _finish : null,
                  ),
              ],
            ),
          ),
          _Dots(count: _pageCount, index: _page),
          const SizedBox(height: AppSpace.lg),
        ],
      ),
    );
  }
}

/// OB1 価値説明（巣の上の卵 + コピー / SCREEN_FLOWS §1）。
class _ValuePage extends StatelessWidget {
  const _ValuePage({required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPane(
      subject: const EggArt(rarity: RarityToken.common),
      title: 'SNSを見ない時間が、\nMofiを育てる',
      body: '減らせた時間がポイントになり、卵が育って孵化します。'
          '集めたMofiで図鑑を埋めていく、ぬくもりのある収集ゲームです。',
      cta: PrimaryButton(label: 'はじめる', onPressed: onNext),
    );
  }
}

/// OB2 権限の理由（安心情報を先出し / SCREEN_FLOWS §1）。
class _PermissionInfoPage extends StatelessWidget {
  const _PermissionInfoPage({required this.onNext, required this.isIOS});
  final VoidCallback onNext;
  final bool isIOS;

  @override
  Widget build(BuildContext context) {
    return _OnboardingPane(
      subject: const Icon(Icons.lock_outline_rounded, color: AppColors.primary),
      title: isIOS ? 'スクリーンタイムの使い方' : '利用時間の見かた',
      body: isIOS
          ? '見るのは「時間」だけ。アプリの中身は一切見ません。'
              '次の画面で、減らしたいSNSをあなた自身で選びます。'
          : '利用時間は端末の中だけで読み取ります。'
              'SNS4アプリ（TikTok / Instagram / YouTube / X）の時間だけを見て、'
              '中身は一切見ません。',
      cta: PrimaryButton(label: '次へ', onPressed: onNext),
    );
  }
}

/// 権限付与（OS設定誘導 + 未許可フォールバック / SCREEN_FLOWS §1）。
class _PermissionGrantPage extends StatelessWidget {
  const _PermissionGrantPage({
    required this.requesting,
    required this.permission,
    required this.isIOS,
    required this.onGrant,
    required this.onSkip,
  });

  final bool requesting;
  final UsagePermissionStatus? permission;
  final bool isIOS;
  final VoidCallback? onGrant;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    // 拒否/未対応で戻ってきた場合のフォールバック文言（責めない / §4-5）。
    final denied = permission != null && !permission!.isGranted;

    return _OnboardingPane(
      subject: const Icon(
        Icons.bar_chart_rounded,
        color: AppColors.primary,
      ),
      title: isIOS ? 'スクリーンタイムを許可' : '「使用状況へのアクセス」を許可',
      body: denied
          ? (isIOS
              ? '今は許可されていません。設定 > スクリーンタイム からあとで許可できます。'
                  '許可がなくても、最初のボーナス卵でMofiを育て始められます。'
              : '今は許可されていません。あとで設定から許可できます。'
                  '許可がなくても、最初のボーナス卵でMofiを育て始められます。')
          : (isIOS
              ? '次にAppleの確認が出ます。「許可」を押すと、'
                  '減らした時間がポイントになります。'
              : '設定画面が開いたら Moffy をオンにしてください。'
                  '正確な削減ポイントの計算に使います。'),
      cta: Column(
        children: [
          if (requesting)
            const NestSkeleton(diameter: 80, label: '確認しています')
          else
            PrimaryButton(
              label: denied ? 'もう一度ひらく' : '許可する',
              onPressed: onGrant,
            ),
          const SizedBox(height: AppSpace.sm),
          TextButton(
            onPressed: onSkip,
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
            ),
            child: const Text('あとで設定する'),
          ),
        ],
      ),
    );
  }
}

/// 対象SNS選択（MVP4固定。育てる対象を選ぶ体験 / S3）。
class _TargetSelectPage extends StatelessWidget {
  const _TargetSelectPage({
    required this.selected,
    required this.onToggle,
    required this.onFinish,
  });

  final Map<String, bool> selected;
  final ValueChanged<String> onToggle;

  /// オフライン時は null（匿名認証オンライン必須 / グレーアウト）。
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpace.xl),
          Text('減らしたいSNSを選ぼう', style: AppType.title),
          const SizedBox(height: AppSpace.sm),
          Text(
            'これらの利用時間が削減ポイントの対象になります。あとで変更できます。',
            style: AppType.caption,
          ),
          const SizedBox(height: AppSpace.xl),
          Expanded(
            child: ListView(
              children: [
                for (final t in AppConstants.defaultAndroidTargets)
                  _AppToggleTile(
                    label: t.label,
                    on: selected[t.packageName] ?? false,
                    onTap: () => onToggle(t.packageName),
                  ),
              ],
            ),
          ),
          if (onFinish == null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Text(
                '接続すると始められます。',
                style: AppType.caption.copyWith(color: AppColors.offline),
                textAlign: TextAlign.center,
              ),
            ),
          PrimaryButton(label: 'Moffyをはじめる', onPressed: onFinish),
        ],
      ),
    );
  }
}

/// iOS 対象アプリ選択（OSの FamilyActivityPicker を開く / S3 の iOS 版）。
///
/// Android のトグル一覧と違い、iOS は Moffy から4SNSを自動指定できない（不透明トークン・
/// プライバシー設計）。ユーザーが Apple のピッカーで自分で選ぶ。選択の永続化と
/// DeviceActivity 監視開始はネイティブ（[ScreenTimeAppSelection.presentAppPicker]）が行う。
class _IOSAppPickerPage extends StatelessWidget {
  const _IOSAppPickerPage({
    required this.requesting,
    required this.selectedCount,
    required this.picked,
    required this.onPick,
    required this.onFinish,
  });

  final bool requesting;
  final int selectedCount;
  final bool picked;
  final VoidCallback? onPick;

  /// オフライン時は null（匿名認証オンライン必須 / グレーアウト）。
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpace.xl),
          Text('見守るアプリを選ぼう', style: AppType.title),
          const SizedBox(height: AppSpace.sm),
          Text(
            'ボタンを押すとAppleの画面が開きます。Instagram・TikTok・YouTube など、'
            '減らしたいアプリにチェックしてください。'
            '選んだアプリの利用時間だけが対象です（あとで変更できます）。',
            style: AppType.caption,
          ),
          const SizedBox(height: AppSpace.xl),
          Expanded(
            child: Center(
              child: requesting
                  ? const NestSkeleton(diameter: 80, label: '開いています')
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NestRing(
                          diameter: 140,
                          inset: 0.04,
                          child: Icon(
                            picked ? Icons.check_rounded : Icons.apps_rounded,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(height: AppSpace.lg),
                        Text(
                          picked ? '$selectedCount件を選択中' : 'まだ選んでいません',
                          style: AppType.bodyStrong,
                        ),
                        const SizedBox(height: AppSpace.sm),
                        OutlinedButton.icon(
                          onPressed: onPick,
                          icon: const Icon(Icons.tune_rounded),
                          label: Text(picked ? 'アプリを選び直す' : 'アプリを選ぶ'),
                        ),
                      ],
                    ),
            ),
          ),
          if (onFinish == null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Text(
                '接続すると始められます。',
                style: AppType.caption.copyWith(color: AppColors.offline),
                textAlign: TextAlign.center,
              ),
            ),
          PrimaryButton(
            label: picked
                ? 'Moffyをはじめる（$selectedCount件を見守る）'
                : 'あとで選んで始める',
            onPressed: onFinish,
          ),
        ],
      ),
    );
  }
}

class _AppToggleTile extends StatelessWidget {
  const _AppToggleTile({
    required this.label,
    required this.on,
    required this.onTap,
  });

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
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
                CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.surfaceNest,
                  child: Text(
                    label.characters.first,
                    style: AppType.bodyStrong,
                  ),
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(child: Text(label, style: AppType.bodyStrong)),
                Switch(
                  value: on,
                  onChanged: (_) => onTap(),
                  activeThumbColor: AppColors.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// オンボーディング各ページの共通レイアウト（主役=巣リング / 署名要素の反復）。
class _OnboardingPane extends StatelessWidget {
  const _OnboardingPane({
    required this.subject,
    required this.title,
    required this.body,
    required this.cta,
  });

  final Widget subject;
  final String title;
  final String body;
  final Widget cta;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        children: [
          const Spacer(),
          // inset を詰めて、円に対してアイコン/卵が小さく見えないようにする。
          NestRing(diameter: 180, inset: 0.04, child: subject),
          const SizedBox(height: AppSpace.xxl),
          Text(title, style: AppType.display, textAlign: TextAlign.center),
          const SizedBox(height: AppSpace.md),
          Text(body, style: AppType.body, textAlign: TextAlign.center),
          const Spacer(),
          SizedBox(width: double.infinity, child: cta),
        ],
      ),
    );
  }
}

/// ページインジケータ（巣の卵が並ぶ風のドット）。
class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});
  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs),
            child: Container(
              width: i == index ? 20 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: i == index ? AppColors.primary : AppColors.divider,
                borderRadius: AppRadius.pillR,
              ),
            ),
          ),
      ],
    );
  }
}

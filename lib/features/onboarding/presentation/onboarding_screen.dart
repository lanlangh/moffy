import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/economy.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/log.dart';
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

  // 【v1.1】Android の「対象SNSトグル」を撤去した。
  // 保存先がどこにも無く（OnboardingRepository が持つキーは完了フラグ1個だけ）、
  // targetPackagesProvider は常に AppConstants.defaultAndroidTargets を返すため、
  // トグルを切り替えても計測対象は1ミリも変わらなかった。
  // **何も起きないスイッチは、固定表示より悪い嘘**なので表示専用の一覧にする。
  // 対象を本当に選べるようにするのは v1.2（基準値の作り直しとセットで実装する。
  // それ無しに対象を減らすと、削減量が跳ね上がって1日上限まで稼げる穴が開く）。

  /// iOS: 対象アプリは OS の FamilyActivityPicker でユーザー自身が選ぶ（不透明トークンの
  /// ため Moffy から4SNSを自動指定できない / ORG_STATE 2026-06-26）。Android のトグルとは別物。
  bool get _isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  int _iosSelectedCount = 0;
  bool _iosPicked = false;

  /// 権限要求が済んで許可されたか。未要求・失敗時は false。
  /// iOS のピッカーは未許可だとネイティブ側が無言で空を返すため、その判別に使う。
  bool get _permissionGranted => _permission?.isGranted ?? false;

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
      // 【B-1 / 第三者レビュー指摘】タイムアウト必須。
      // 「あとで設定する」を撤去したため、要求中の画面には押せる要素が1つも無い
      // （cta は NestSkeleton＝装飾のみ）。OS 側の要求が返らないと _requesting が
      // true のまま固まり、**逃げ道ゼロの行き止まり**になる＝今度は 2.1 で落ちる。
      // TimeoutException は下の catch が拾い、必ず _next() まで進む。
      final status = await usage
          .requestPermission()
          .timeout(const Duration(seconds: 30));
      if (mounted) {
        setState(() => _permission = status);
        // ファネル: 利用時間権限の許可（PRD §5-5）。許可された時のみ発火。
        if (status.isGranted) {
          ref
              .read(analyticsProvider)
              .capture(AnalyticsEvents.usagePermissionGranted);
        }
      }
    } catch (e, st) {
      // 【5.1.1(iv) 対応で必須】「あとで設定する」を撤去したため、ここで例外が抜けると
      // 先へ進む手段が消えて行き止まりになる（＝今度は 2.1 で落ちる）。よって握りつぶす。
      // ただし**無言にはしない**（B-7 / 第三者レビュー指摘）。
      // 通常のユーザー拒否は例外ではなく UsagePermissionStatus として返るため、ここに
      // 来るのは MissingPluginException・DI 障害・タイムアウトといった**本物の異常**だけ。
      // 広告の no-fill のような「正常系の大量発生」とは性質が違うので Log.e で拾う。
      // 黙らせると、チャネルが丸ごと壊れてもコアループの入口の崩壊に誰も気づけない。
      Log.e('usage requestPermission failed', error: e, stack: st);
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
    if (!mounted) return;
    _next(); // 許可/拒否/失敗のどれでも次へ（拒否はボーナス卵で吸収 / SCREEN_FLOWS §1）。
  }

  /// iOS: OS の FamilyActivityPicker を開いて対象アプリを選ばせ、選択数を反映する。
  /// 選択は端末に永続化＋DeviceActivity 監視開始までネイティブが行う（IOSUsageProvider）。
  Future<void> _pickIOSApps() async {
    final provider = ref.read(usageProviderProvider);
    if (provider is! ScreenTimeAppSelection) return;
    // ScreenTimeAppSelection は UsageProvider のサブタイプではない（独立 capability）ため
    // 型 promotion が効かない。is! ガード済みなので明示キャストは安全。
    final screenTime = provider as ScreenTimeAppSelection;
    // await をまたぐので context は先に解決しておく（use_build_context_synchronously）。
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _requesting = true);
    try {
      final result = await screenTime.presentAppPicker();
      if (!mounted) return;
      setState(() {
        _iosSelectedCount = result.count;
        _iosPicked = result.selected;
      });
      // 【B-2 / 第三者レビュー指摘・重要】ネイティブ側は未許可だとピッカーを出さずに
      // selected:false を即返す（ScreenTimeHandler.swift の `guard status == .approved`）。
      // 無言で終わると**押しても何も起きないボタン**にしか見えず、2.1 を招く。
      // しかも「あとで設定する」を撤去した結果、権限を拒否した人は全員ここへ来る
      // （審査員はわざと拒否して挙動を見る）。理由と次の手を必ず出す。
      if (!result.selected) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              _permissionGranted
                  ? 'アプリが選ばれていません。1つ以上選ぶと計測がはじまります。'
                  : 'スクリーンタイムが許可されていないため、アプリを選べません。'
                      'このまま始められます（最初のボーナス卵で育てられます）。'
                      'あとで「設定 > スクリーンタイム」から許可すると選べるようになります。',
            ),
          ),
        );
      }
    } catch (e, st) {
      // profile 側の同じ導線（target_apps_screen.dart）と作法をそろえる。
      Log.e('presentAppPicker failed (onboarding)', error: e, stack: st);
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('アプリを選ぶ画面を開けませんでした。')),
        );
      }
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
                ),
                if (_isIOS)
                  _IOSAppPickerPage(
                    requesting: _requesting,
                    selectedCount: _iosSelectedCount,
                    picked: _iosPicked,
                    permissionGranted: _permissionGranted,
                    onPick: _requesting ? null : _pickIOSApps,
                    onFinish: isOnline ? _finish : null,
                  )
                else
                  _TargetSelectPage(
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
///
/// 【v1.1.1 / App Store Guideline 5.1.1(iv) 対応】2026-08-10 の審査で、この画面が
/// 「OSの許可ダイアログを出す前に、アプリ側が許可を促している」として却下された。
/// Apple の指摘は次の2点で、いずれもボタンの話である（説明文そのものは問題視されていない）:
///   1. 前置き画面のボタンが **「許可する」** だった
///      → Apple の指定どおり "Continue"/"Next" 相当の **「次へ」** にする。
///      （Android は OS 設定アプリへ飛ばすので「設定を開く」＝実態どおりの表現）
///   2. **「あとで設定する」** で OS の要求そのものを先送りできた
///      → 撤去。説明を読んだら必ず OS の要求まで進む。
/// 撤去しても行き止まりにならないのは `_requestPermission` が許可/拒否/失敗の
/// どの場合でも `_next()` するため（例外の握りつぶしも同メソッドで担保している）。
class _PermissionGrantPage extends StatelessWidget {
  const _PermissionGrantPage({
    required this.requesting,
    required this.permission,
    required this.isIOS,
    required this.onGrant,
  });

  final bool requesting;
  final UsagePermissionStatus? permission;
  final bool isIOS;
  final VoidCallback? onGrant;

  @override
  Widget build(BuildContext context) {
    // 拒否/未対応で戻ってきた場合のフォールバック文言（責めない / §4-5）。
    final denied = permission != null && !permission!.isGranted;

    return _OnboardingPane(
      subject: const Icon(
        Icons.bar_chart_rounded,
        color: AppColors.primary,
      ),
      // 【B-6 / 第三者レビュー指摘】見出しと本文から「許可」の誘導語を外す。
      // Apple が列挙したのはボタン2点だが、指摘冒頭の
      // "encourages or directs users to allow" は見出し「スクリーンタイムを許可」にも
      // 当たりうる。書き換えは数分、二度目の 5.1.1(iv) は審査1サイクル＝期待コストが非対称。
      title: isIOS ? 'スクリーンタイムについて' : '「使用状況へのアクセス」について',
      body: denied
          ? (isIOS
              ? '今は許可されていません。設定 > スクリーンタイム からあとで許可できます。'
                  '許可がなくても、最初のボーナス卵でMofiを育て始められます。'
              : '今は許可されていません。あとで設定から許可できます。'
                  '許可がなくても、最初のボーナス卵でMofiを育て始められます。')
          : (isIOS
              // システム側ボタン名の引用と「押せ」という指示を除去（B-6）。
              // 「『許可』を押すと報酬になる」は、システムダイアログへの回答を
              // アプリ内の報酬で誘導する形になっており 5.1.1(iv) の核心に触れる。
              ? '次にAppleの確認画面が表示されます。'
                  '計測を有効にすると、減らした時間がポイントになります。'
              : '次に端末の設定画面が開きます。'
                  'Moffy を有効にすると、正確な削減ポイントを計算できます。'),
      cta: requesting
          ? const NestSkeleton(diameter: 80, label: '確認しています')
          : PrimaryButton(
              // 5.1.1(iv): OSの要求前に「許可」を促す語を使わない。
              // denied は要求が済んだ**後**の状態なので再試行の語でよい。
              label: denied
                  ? 'もう一度ひらく'
                  : (isIOS ? '次へ' : '設定を開く'),
              onPressed: onGrant,
            ),
    );
  }
}

/// 対象SNSの案内（Android: 4アプリ固定 / S3）。
///
/// v1.1 で「選べるように見えるトグル」をやめ、事実どおりの表示専用一覧にした
/// （選択を保存する先が無く、切り替えても計測対象が変わらなかった）。
class _TargetSelectPage extends StatelessWidget {
  const _TargetSelectPage({
    required this.onFinish,
  });

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
          Text('見守るのはこの4つ', style: AppType.title),
          const SizedBox(height: AppSpace.sm),
          Text(
            'これらの利用時間を合計して、削減ポイントを計算します。',
            style: AppType.caption,
          ),
          const SizedBox(height: AppSpace.xl),
          Expanded(
            child: ListView(
              children: [
                for (final t in AppConstants.defaultAndroidTargets)
                  _AppListTile(label: t.label),
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
    required this.permissionGranted,
    required this.onPick,
    required this.onFinish,
  });

  final bool requesting;
  final int selectedCount;
  final bool picked;

  /// スクリーンタイムが許可済みか。false のときピッカーは開かない（ネイティブが
  /// 無言で空を返す）ため、理由と「このまま始められる」ことを**常設で**示す。
  /// SnackBar だけだと消えてしまい、行き止まりに見える（B-2 / B-3）。
  final bool permissionGranted;
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
            permissionGranted
                ? 'ボタンを押すとAppleの画面が開きます。Instagram・TikTok・YouTube など、'
                    '減らしたいアプリにチェックしてください。'
                    '選んだアプリの利用時間だけが対象です（あとで変更できます）。'
                // 【B-3 / 第三者レビュー指摘】拒否した人向けの安心文言は、
                // 権限ページが自動で次へ進むため**誰にも読まれない死にコード**だった。
                // 実際に拒否した人が着地するこのページへ移す。
                : 'スクリーンタイムが許可されていないため、いまはアプリを選べません。'
                    'このまま始められます（最初のボーナス卵でMofiを育てられます）。'
                    'あとで「設定 > スクリーンタイム」から許可し、'
                    'メニューの「対象アプリ」で選べます。',
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

/// 対象アプリの表示専用タイル（Android / v1.1）。
///
/// 以前は Switch 付きのトグルだったが、保存先が存在せず切り替えても計測対象が
/// 変わらなかったため撤去した。操作できないことが見た目で分かるよう、
/// チェックアイコンで「対象です」と示すだけにしている。
class _AppListTile extends StatelessWidget {
  const _AppListTile({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Material(
        color: AppColors.surface,
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
              const Icon(Icons.check_rounded, color: AppColors.primary),
            ],
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

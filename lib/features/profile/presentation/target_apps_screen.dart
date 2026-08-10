import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/economy.dart';
import '../../../core/observability/log.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/usage/usage_provider.dart';
import '../../../core/usage/usage_providers.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../home/presentation/home_controller.dart';

/// 対象アプリ設定（S12 / v1.1 で新設）。
///
/// ## なぜこの画面が要るか（v1.1 で最も影響の大きい欠落）
/// iOS は Screen Time（FamilyControls）の制約でアプリを識別できないため、
/// ユーザーが OS の `FamilyActivityPicker` で対象を選ぶ必要がある。ところが
/// `presentAppPicker()` の呼び出し元は**オンボーディングの1箇所だけ**だった。
/// つまりオンボで「あとで選んで始める」を押した iPhone ユーザーは、
/// アプリ内に選び直す入口が存在せず:
///   * DeviceActivity の監視対象なし → 毎日0分
///   * 0分の日は履歴から除外される → 基準値のサンプルが永久に貯まらない
///   * ホームが**永久に**「明日から計測スタート」を出し続ける
/// ＝「オンボで1回スキップしたら、アプリが二度と動かない」状態だった。
/// しかもオンボーディングの文言は「（あとで変更できます）」と約束していた。
///
/// この画面がその約束を初めて本当にする。
///
/// ## Android について
/// Android は `UsageStatsManager` で対象パッケージを自前で集計するので、選択 UI は
/// 不要（現在は固定4アプリ）。ここでは対象を一覧で示すだけに留める。
/// **選べるようにするのは v1.2**（対象を変えると基準値の作り直しが必要で、
/// やらないと「対象を減らした日から削減量が跳ね上がって1日上限まで稼げる」穴が開く）。
class TargetAppsScreen extends ConsumerStatefulWidget {
  const TargetAppsScreen({super.key});

  static const String routeName = 'target-apps';
  static const String routePath = '/settings/target-apps';

  @override
  ConsumerState<TargetAppsScreen> createState() => _TargetAppsScreenState();
}

class _TargetAppsScreenState extends ConsumerState<TargetAppsScreen> {
  /// iOS: 選択が保存済みか。null = 確認中。
  bool? _hasSelection;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    // ignore: discarded_futures
    _refreshSelection();
  }

  /// iOS の選択状態を読み直す（`hasAppSelection` は今まで誰も呼んでいなかった）。
  Future<void> _refreshSelection() async {
    final provider = ref.read(usageProviderProvider);
    if (provider is! ScreenTimeAppSelection) return;
    try {
      final has = await provider.hasAppSelection();
      if (!mounted) return;
      setState(() => _hasSelection = has);
    } catch (e, st) {
      Log.e('hasAppSelection failed', error: e, stack: st);
      if (!mounted) return;
      setState(() => _hasSelection = null);
    }
  }

  /// OS のアプリ選択画面を開く。選択後は監視が（再）開始される。
  Future<void> _pickApps() async {
    final provider = ref.read(usageProviderProvider);
    if (provider is! ScreenTimeAppSelection) return;
    if (_picking) return;
    setState(() => _picking = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await provider.presentAppPicker();
      if (!mounted) return;
      setState(() {
        _picking = false;
        _hasSelection = result.selected;
      });
      if (result.selected) {
        // 監視対象が変わったのでホームを取り直す（「明日から計測スタート」から抜ける）。
        ref.invalidate(homeControllerProvider);
        messenger.showSnackBar(
          SnackBar(content: Text('${result.count}件のアプリを見守ります')),
        );
      } else {
        messenger.showSnackBar(
          const SnackBar(content: Text('アプリが選ばれていません。1つ以上選ぶと計測がはじまります。')),
        );
      }
    } catch (e, st) {
      Log.e('presentAppPicker failed', error: e, stack: st);
      if (!mounted) return;
      setState(() => _picking = false);
      messenger.showSnackBar(
        const SnackBar(content: Text('アプリ選択の画面を開けませんでした。')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(usageProviderProvider);
    final canPick = provider is ScreenTimeAppSelection;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('対象アプリ')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(AppSpace.lg),
          children: [
            if (canPick) ..._iosSection() else ..._androidSection(),
          ],
        ),
      ),
    );
  }

  /// iOS: OS のピッカーで選び直す（唯一の脱出口）。
  List<Widget> _iosSection() {
    final has = _hasSelection;
    return [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('見守るアプリ', style: AppType.title),
            const SizedBox(height: AppSpace.sm),
            Text(
              switch (has) {
                null => '選択状態を確認しています。',
                true => 'アプリが選ばれています。利用時間の合計を見て、削減ポイントを計算します。',
                false => 'まだアプリが選ばれていません。'
                    '選ぶまで利用時間が記録されず、削減ポイントもたまりません。',
              },
              style: AppType.body,
            ),
            if (has == false) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                'ホームがずっと「明日から計測スタート」のままの場合は、これが原因です。',
                style: AppType.caption.copyWith(color: AppColors.error),
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            PrimaryButton(
              label: has == false ? 'アプリを選ぶ' : 'アプリを選び直す',
              onPressed: _picking ? null : _pickApps,
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.lg),
      Text(
        'iPhoneではプライバシー保護のため、アプリの名前や個別の利用時間をMoffyが'
        '受け取ることはできません。選ばれたアプリの合計時間だけを見ています。',
        style: AppType.caption,
      ),
    ];
  }

  /// Android: 対象は固定4アプリ。選択UIは v1.2（基準値の作り直しとセットで実装する）。
  List<Widget> _androidSection() {
    return [
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('見守るアプリ', style: AppType.title),
            const SizedBox(height: AppSpace.sm),
            Text('次のアプリの利用時間を合計して、削減ポイントを計算します。',
                style: AppType.body),
            const SizedBox(height: AppSpace.lg),
            for (final def in AppConstants.defaultAndroidTargets)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.sm),
                child: Row(
                  children: [
                    const Icon(Icons.check_rounded,
                        size: 18, color: AppColors.primary),
                    const SizedBox(width: AppSpace.sm),
                    Text(def.label, style: AppType.body),
                  ],
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: AppSpace.lg),
      Text(
        '対象アプリを自分で選べるようにする機能は、今後のアップデートで対応予定です。',
        style: AppType.caption,
      ),
    ];
  }
}

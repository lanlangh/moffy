import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/pricing.dart';
import '../../../core/iap/iap_providers.dart';
import '../../../core/navigation/app_tab.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/observability_providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/egg_art.dart';
import '../../../core/widgets/nest_panel.dart';
import '../../../core/widgets/state_views.dart';
import '../../paywall/presentation/paywall_screen.dart';
import '../data/hatch_share_service.dart';
import '../domain/egg_models.dart';
import 'eggs_controller.dart';
import 'egg_visuals.dart';
import 'widgets/egg_detail_sheet.dart';
import 'widgets/hatch_overlay.dart';
import 'widgets/incubator_slots.dart';
import 'widgets/storage_grid.dart';

/// たまご画面（SCREEN_FLOWS §3）。育成枠3 + 保管枠 + 孵化演出 + 色違いキラリ。
///
/// 5状態:
///   * ローディング: AsyncValue.loading → 巣リング型スケルトン。
///   * エラー: AsyncValue.error → ErrorView + リトライ。
///   * ハッピー/空: data 内で「育成枠あり/空枠誘導」を出し分け。
///   * オフライン: 上端バー + 孵化ボタンのグレーアウト（二重消費防止 / S8）。
class EggsScreen extends ConsumerWidget {
  const EggsScreen({super.key});

  static const String routeName = 'eggs';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(eggsControllerProvider);
    final controller = ref.read(eggsControllerProvider.notifier);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('たまご')),
      body: SafeArea(
        top: false,
        child: async.when(
          loading: () => const Center(child: NestSkeleton(label: '巣をのぞいています')),
          error: (e, _) => ErrorView(
            message: '卵の読み込みに失敗しました。通信環境を確認してもう一度お試しください。',
            onRetry: controller.refresh,
          ),
          data: (state) => _EggsBody(state: state),
        ),
      ),
    );
  }
}

class _EggsBody extends ConsumerWidget {
  const _EggsBody({required this.state});
  final EggsState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(eggsControllerProvider.notifier);

    // 完全に空（保管も育成も無し）→ クエスト誘導の空状態（SCREEN_FLOWS §3）。
    if (state.isCompletelyEmpty) {
      return Column(
        children: [
          if (state.isOffline) const OfflineBar(),
          Expanded(
            child: EmptyState(
              message: 'まだ卵がありません',
              subMessage: 'クエストやポイントで卵を手に入れよう。',
              ctaLabel: 'クエストへ',
              onCta: () => context.go(AppTab.quests.path),
            ),
          ),
        ],
      );
    }

    final active = state.activeEgg;

    return Column(
      children: [
        if (state.isOffline) const OfflineBar(),
        Expanded(
          child: RefreshIndicator(
            onRefresh: controller.refresh,
            color: AppColors.primary,
            // padding は 0。**主役ステージを画面の左右いっぱいに出す**ため
            // （2026-08-19 オーナー指摘「上部のみ背景を左右上部全面に」）。
            // 余白は下のカード群だけに付け直す。
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // ① 主役ステージ（全面背景 + 卵）。画面最上部に置き、
                //    背景画像の上端が単色なので AppBar 側の地色と自然につながる。
                if (active != null)
                  _EggStage(
                    egg: active,
                    state: state,
                    onTap: () => _openDetail(context, ref, active),
                  )
                else
                  _NoActiveEggPanel(pooledPoints: state.pooledPoints),

                // ② ここから下は従来どおり余白付きのカード群。
                Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 育成枠3スロット（アクティブ強調 / S6）。
                      Text('育成枠', style: AppType.bodyStrong),
                      const SizedBox(height: AppSpace.md),
                      IncubatorSlots(
                        state: state,
                        onSelectSlot: (egg) => _openDetail(context, ref, egg),
                      ),
                      const SizedBox(height: AppSpace.xl),

                      // 保管枠グリッド。
                      Text('保管庫', style: AppType.bodyStrong),
                      const SizedBox(height: AppSpace.md),
                      // 保管枠アップセル（無料上限に近づいたら表示。プレミアムは非表示）。
                      _StorageUpsell(storageCount: state.storage.length),
                      StorageGrid(
                        state: state,
                        onSelect: (egg) => _openDetail(context, ref, egg),
                      ),
                      const SizedBox(height: AppSpace.xl),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _openDetail(BuildContext context, WidgetRef ref, Egg egg) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => EggDetailSheet(
        egg: egg,
        state: state,
        onSetActive: () => _runEggAction(
          context,
          () => ref.read(eggsControllerProvider.notifier).setActive(egg.id),
        ),
        onMoveToStorage: () => _runEggAction(
          context,
          () => ref.read(eggsControllerProvider.notifier).moveToStorage(egg.id),
        ),
        onMoveToIncubator: (slot) => _runEggAction(
          context,
          () => ref
              .read(eggsControllerProvider.notifier)
              .moveToIncubator(egg.id, slot),
        ),
        onHatch: () => _hatch(context, ref, egg),
      ),
    );
  }

  /// 枠操作（セット/戻す/切替）の共通実行。完了で詳細シートを閉じ、失敗は握って
  /// トーストで知らせる（リポジトリが満杯/競合/不正状態で例外を投げても未処理にしない）。
  Future<void> _runEggAction(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      await action();
      navigator.pop();
    } on StorageFullException {
      // 保管枠が上限（無料20/プレミアム200 は 0010 で実際に強制）。満杯は事実なので
      // 具体的に案内する（孵化 or プレミアム拡張）。上部の保管枠アップセルから課金導線へ。
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('保管庫がいっぱいです。卵を孵化させるか、プレミアムで枠を増やせます。'),
        ),
      );
    } catch (_) {
      navigator.pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('この操作はできませんでした。もう一度お試しください。')),
      );
    }
  }

  Future<void> _hatch(BuildContext context, WidgetRef ref, Egg egg) async {
    Navigator.of(context).pop(); // 詳細シートを閉じる
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final navigator = Navigator.of(context, rootNavigator: true);

    HatchResult? result;
    try {
      result = await ref.read(eggsControllerProvider.notifier).hatch(egg.id);
    } catch (_) {
      // エラー: ptを消費せずリトライ可能（二重孵化しない / §5-2）。
      messenger.showSnackBar(
        const SnackBar(content: Text('孵化に失敗しました。もう一度お試しください。')),
      );
      return;
    }

    // オフライン: 孵化確定はオンラインのみ（S8）。
    if (result == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('孵化はオンラインで確定します。接続したら確定されます。')),
      );
      return;
    }

    if (!context.mounted) return;
    final hatched = result;

    // ファネル: 孵化（コアループの山場 / PRD §5-5）。生データ（pt等）は載せず、
    // レアリティ・色違いのカテゴリ値のみ（PII/生データ非送信 / OBSERVABILITY_SETUP.md）。
    final analytics = ref.read(analyticsProvider);
    analytics.capture(
      AnalyticsEvents.eggHatched,
      properties: {
        AnalyticsProps.mofiRarity: hatched.species.rarity.wire,
        AnalyticsProps.isShiny: hatched.isShiny,
      },
    );
    if (hatched.isShiny) {
      // 色違いは専用集計（グロースの種 / S13）。
      analytics.capture(AnalyticsEvents.shinyHatched);
    }
    if (hatched.isNewDexEntry) {
      // ファネル: 図鑑への新規登録（コレクション進捗 / PRD §5-5）。
      analytics.capture(
        AnalyticsEvents.dexRegistered,
        properties: {AnalyticsProps.mofiRarity: hatched.species.rarity.wire},
      );
    }

    // 孵化演出オーバーレイ（操作ロック / スキップ可）。
    await navigator.push<void>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => HatchOverlay(
          result: hatched,
          onClose: () => navigator.maybePop(),
          onGoToDex: () {
            navigator.maybePop();
            router.go(AppTab.collection.path);
          },
          onShare: (imageBytes) async {
            // S13 グロースの種: 結果カードのキャプチャ画像 + 文面をSNSへ共有。
            // 画像生成・共有はサービスに委譲（プラグイン依存の隔離 / ベストエフォート）。
            final text = buildHatchShareText(hatched);
            final ok = await ref.read(hatchShareServiceProvider).shareHatch(
                  text: text,
                  subject: buildHatchShareSubject(hatched),
                  imageBytes: imageBytes,
                );
            // 失敗/未対応時のフォールバック: 文面をクリップボードへコピーしトースト通知
            // （拡散の起点を完全には失わせない / プラットフォーム未対応時の分岐）。
            if (!ok) {
              await Clipboard.setData(ClipboardData(text: text));
              messenger.showSnackBar(
                const SnackBar(
                  content: Text('シェア用のテキストをコピーしました。'),
                ),
              );
            }
          },
        ),
      ),
    );
  }
}

/// アクティブ卵の主役パネル（孵化進捗 + 孵化ボタン）。
/// たまごタブの主役ステージ（画面上部・左右いっぱい）。
///
/// なぜ従来の角丸カード（旧 `_ActiveEggPanel`・このコミットで削除）と別物にしたか:
///   1. 角丸カードだと左右に余白が残り「四角で囲われて」見える（オーナー指摘）
///   2. 砂色の円台（[NestRing] の既定）を風景の上に出すと**貼り紙のように浮く**
///      → [NestRing.showBase] = false にして、卵と藁の巣を草に直接置き、影だけ残す
///
/// 上下の境目は**コード側**で処理する（画像に単色帯を持たせない）。
/// 初版は「上端を単色にした画像」を発注したが、それは空と雲まで消してしまい
/// 絵が暗く平板になった（2026-08-19 オーナー指摘「もっと明るいのをイメージしていた」
/// 「雲がないのはあえてか」）。**明るい空のある絵をそのまま使い、
/// 境目だけアプリ側のグラデーションで溶かす**のが正しい分担。
/// この作りなら、将来「雲を流す」ときも雲だけの透過画像を重ねれば済む。
///
/// 画像が読めない場合は何も描かず、従来どおりの単色地になる（フォールバック）。
class _EggStage extends StatelessWidget {
  const _EggStage({
    required this.egg,
    required this.state,
    required this.onTap,
  });

  final Egg egg;
  final EggsState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final params = state.params;
    final stage = egg.stage(params);
    final rarity = RarityVisuals.ofEgg(egg.rarity);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    // 高さを幅だけで決めると、幅の広い端末（タブレット・横向き）でステージが
    // 画面を埋め尽くし、下の「育成枠」「保管庫」が押し出されて**到達不能**になる。
    // 既存のウィジェットテスト（800x600）がこれを検出した。画面高でも頭打ちにする。
    final stageHeight = math.min(w * 1.02, size.height * 0.5);

    return Semantics(
      button: true,
      container: true,
      label: '育成中の卵の詳細を開く',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: double.infinity,
          // 正方形に近い比率。背景画像（1:1）を切り取り過ぎない。
          // ただし画面高の半分を超えない（上のコメント参照）。
          height: stageHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                'assets/images/bg/home_stage.jpg',
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                filterQuality: FilterQuality.medium,
                // 表示解像度でデコードする（フルサイズのテクスチャを常駐させない）。
                cacheWidth: (w * dpr).round(),
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
              ),
              // 上端: AppBar 側の地色へ溶かす（画面の途中から急に絵が始まらない）。
              // 下端: 下のカード群の地色へ溶かす（角で切れた板に見えない）。
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.bg,
                        Color(0x00FBF6EA),
                        Color(0x00FBF6EA),
                        AppColors.bg,
                      ],
                      // 上は浅く（明るい青空をクリームで濁らせない）、
                      // 下は厚めに（下のカード群へ自然に着地させる）。
                      stops: [0.0, 0.10, 0.86, 1.0],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.lg,
                  vertical: AppSpace.lg,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 文字は必ず淡い座布団の上に置く。青空や草の上に直接置くと
                    // コントラストが足りず読めない（モックが白い吹き出しを使っている
                    // のは装飾ではなく可読性の担保）。
                    _StageChip(
                      child: Text(
                        egg.canHatch(params)
                            ? 'まもなく孵化'
                            : '孵化まであと ${egg.remaining(params)}pt',
                        style: AppType.title,
                      ),
                    ),
                    const SizedBox(height: AppSpace.md),
                    NestRing(
                      diameter: 180,
                      glow: egg.isNearHatch(params) ? rarity.glow : null,
                      // 風景の上なので砂色の円台は出さない（影だけ残す）。
                      showBase: false,
                      child: EggSubject(
                        rarity: egg.rarity,
                        stage: stage,
                        animated: true,
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    _StageChip(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GrowthProgressBar(value: egg.progress(params)),
                          const SizedBox(height: AppSpace.sm),
                          Text(
                            '${stage.label}・'
                            '${(egg.progress(params) * 100).round()}%',
                            style: AppType.numLabel,
                          ),
                        ],
                      ),
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

/// 保管枠アップセル（無料上限に近づいたらペイウォールへ誘導）。
///
/// 表示条件: クライアント非プレミアム かつ 保管数が無料上限の8割以上。
/// しきい値・上限は [StorageLimits]（SSOT）を参照しハードコードしない。
/// 注意（信頼境界）: ここはあくまで導線。実際の保管枠ガード（200解放）はサーバー検証が正。
/// ステージ上の文字を必ず読めるようにする座布団。
///
/// 背景が明るい青空や鮮やかな草なので、濃い文字を直に置くとコントラストが足りない。
/// クリーム地を半透明で敷いて、文字は従来どおりの地の上に乗せる。
/// モックが吹き出しを使っているのは装飾ではなく、この可読性の担保。
class _StageChip extends StatelessWidget {
  const _StageChip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.bg.withValues(alpha: 0.88),
        borderRadius: AppRadius.lgR,
      ),
      child: child,
    );
  }
}

class _StorageUpsell extends ConsumerWidget {
  const _StorageUpsell({required this.storageCount});
  final int storageCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPremium = ref.watch(isPremiumProvider);
    if (isPremium) return const SizedBox.shrink();

    const freeLimit = StorageLimits.freeStorageSlots;
    // 上限の8割（= freeLimit * 4 / 5）に達したら訴求。マジックナンバーを避け整数演算。
    const threshold = (freeLimit * 4) ~/ 5;
    if (storageCount < threshold) return const SizedBox.shrink();

    final atLimit = storageCount >= freeLimit;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: const BoxDecoration(
          color: AppColors.primarySoft,
          borderRadius: AppRadius.lgR,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.workspace_premium_rounded,
                  color: AppColors.primaryDeep,
                  size: 20,
                ),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    atLimit ? '保管庫がいっぱいです' : '保管庫の空きが少なくなっています',
                    style: AppType.bodyStrong,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              'プレミアムなら保管枠が '
              '${StorageLimits.freeStorageSlots} → ${StorageLimits.premiumStorageSlots} に。'
              'たっぷり集められます。',
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpace.md),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => context.push(
                  PaywallScreen.pathWithSource(PaywallSource.eggsStorage),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primaryDeep,
                ),
                child: const Text('プレミアムを見る'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// アクティブ卵が無い（空枠誘導 / §5-2 空状態）。
class _NoActiveEggPanel extends StatelessWidget {
  const _NoActiveEggPanel({required this.pooledPoints});
  final int pooledPoints;

  @override
  Widget build(BuildContext context) {
    return NestPanel(
      diameter: 160,
      subject: const EmptyNestEgg(),
      caption: Text('育てる卵を選ぼう', style: AppType.title),
      footer: Text(
        pooledPoints > 0
            ? '$pooledPoints pt ためてあるよ。卵をセットすると使えます。'
            : '保管庫の卵を育成枠にセットしてください。',
        style: AppType.caption,
        textAlign: TextAlign.center,
      ),
    );
  }
}

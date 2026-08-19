import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/env.dart';
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
import '../../../core/widgets/world_stage.dart';
import '../../collection/domain/mofi_models.dart';
import '../../paywall/presentation/paywall_screen.dart';
import '../data/hatch_share_service.dart';
import '../domain/egg_models.dart';
import 'eggs_controller.dart';
import 'egg_visuals.dart';
import 'pending_hatch_provider.dart';
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
    // 孵化したばかりでまだ図鑑へ送っていない Mofi（あればステージに残す）。
    final pending = ref.watch(pendingHatchProvider);

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
                // ① 育成枠はステージの上に戻した。ステージが画面最上部だと
                //    イラストが上端に寄って小さく見えるため（オーナー指摘）。
                //    上に枠を置くことでステージが画面の中心近くに来る。
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.lg,
                    AppSpace.lg,
                    AppSpace.lg,
                    0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('育成枠', style: AppType.bodyStrong),
                      const SizedBox(height: AppSpace.md),
                      IncubatorSlots(
                        state: state,
                        onSelectSlot: (egg) => _openDetail(context, ref, egg),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpace.lg),

                // ② 主役ステージ。孵化直後の Mofi がいればそれを優先して置く
                //    （育てた子を眺める間を作る / オーナー提案 2026-08-19）。
                if (pending != null)
                  _HatchedStage(
                    result: pending,
                    stage: 1,
                    onSendToDex: () =>
                        ref.read(pendingHatchProvider.notifier).state = null,
                  )
                else if (active != null)
                  _EggStage(
                    egg: active,
                    state: state,
                    onTap: () => _openDetail(context, ref, active),
                    onPreviewHatch: () => _previewHatch(context),
                  )
                else
                  _NoActiveEggPanel(pooledPoints: state.pooledPoints),

                // ③ 以降は従来どおり余白付きのカード群。
                Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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

  /// 【お試しビルド専用】孵化演出だけを再生する。
  ///
  /// 実際の孵化は行わない（サーバーも残高も触らない）。オーナーが実機で
  /// 「孵化したときにどう見えるか」を確認するためだけの経路。
  /// `Env.previewStages` が false のとき、この呼び出し元のボタン自体が描画されない。
  void _previewHatch(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    const species = MofiSpecies(
      id: 'dragon_01',
      family: MofiFamily.dragon,
      rarity: MofiRarity.ssr,
      name: 'ドラゴン（見本）',
      sortOrder: 0,
    );
    navigator.push<void>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.transparent,
        pageBuilder: (_, __, ___) => HatchOverlay(
          result: const HatchResult(
            species: species,
            isShiny: true,
            isNewDexEntry: true,
            fromEggId: 'preview',
          ),
          onClose: () => navigator.maybePop(),
          onGoToDex: () => navigator.maybePop(),
          onShare: (_) async {},
        ),
      ),
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
        onSetActive: () {
          _clearPendingHatch(ref);
          unawaited(_runEggAction(
            context,
            () => ref.read(eggsControllerProvider.notifier).setActive(egg.id),
          ));
        },
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
  /// 次の卵を育て始めたら、残していた Mofi は自動で図鑑へ送る
  /// （ボタンを押し忘れても先へ進める。オーナー提案の「自動で図鑑に行く」）。
  void _clearPendingHatch(WidgetRef ref) =>
      ref.read(pendingHatchProvider.notifier).state = null;

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

    // 演出のあともステージに残して眺められるようにする（オーナー提案 2026-08-19）。
    // 図鑑への登録は孵化時にサーバーが済ませているので、これは表示のための状態。
    ref.read(pendingHatchProvider.notifier).state = hatched;

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

/// たまごタブの主役ステージ（左右いっぱい）。
///
/// なぜ従来の角丸カード（旧 `_ActiveEggPanel`・削除済み）と別物にしたか:
///   1. 角丸カードだと左右に余白が残り「四角で囲われて」見える
///   2. 砂色の円台（[NestRing] の既定）を風景の上に出すと**貼り紙のように浮く**
///      → [NestRing.showBase] = false にして卵を草に直接置き、影だけ残す
///
/// 上下の境目は**コード側**で溶かす（画像に単色帯を焼き込まない）。
/// この分担なら、将来「雲を流す」ときも雲だけの透過画像を重ねれば済む。
///
/// 画像が読めない場合は何も描かず、従来どおりの単色地になる（フォールバック）。
class _EggStage extends StatefulWidget {
  const _EggStage({
    required this.egg,
    required this.state,
    required this.onTap,
    required this.onPreviewHatch,
  });

  final Egg egg;
  final EggsState state;
  final VoidCallback onTap;

  /// 【お試しビルド専用】孵化演出だけを再生する（実際には孵化させない）。
  final VoidCallback onPreviewHatch;

  @override
  State<_EggStage> createState() => _EggStageState();
}

class _EggStageState extends State<_EggStage> {
  /// 【お試しビルド専用】表示だけ差し替える成長段階。null = 実データどおり。
  double? _previewProgress;

  /// 【お試しビルド専用】卵の代わりに置く Mofi。null = 卵を表示。
  int? _previewMofi;

  /// 【お試しビルド専用】背景の寄り。既定は寄り（1.45）、引きは 1.0。
  double _zoom = 1.45;

  @override
  Widget build(BuildContext context) {
    final params = widget.state.params;
    final progress = _previewProgress ?? widget.egg.progress(params);
    final stage = _stageFor(progress);
    final rarity = RarityVisuals.ofEgg(widget.egg.rarity);

    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    // 背景が「スマホに対してすごく小さく見える」との指摘を受け、画面高に対する
    // 取り分を増やした（0.50 → 0.58）。幅の広い端末で下の内容が押し出されない
    // よう上限は維持する。
    final stageHeight = math.min(w * 1.15, size.height * 0.58);
    // 巣の直径はステージの高さから決める。固定値だと低い画面ではみ出す。
    final ringDiameter = ((stageHeight - 180) / 1.12).clamp(96.0, 210.0);

    final mofi = _previewMofi == null
        ? null
        : _PreviewMofi.all[_previewMofi! % _PreviewMofi.all.length];

    return Semantics(
      button: true,
      container: true,
      label: '育成中の卵の詳細を開く',
      child: GestureDetector(
        onTap: widget.onTap,
        child: SizedBox(
          width: double.infinity,
          height: stageHeight,
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(child: WorldStageBackground(zoom: _zoom)),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.lg,
                    vertical: AppSpace.lg,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 文字は必ず淡い座布団の上に置く（空や草の上だと読めない）。
                      StageChip(
                        child: Text(
                          mofi != null
                              ? '${mofi.label}（見本）'
                              : widget.egg.canHatch(params)
                                  ? 'まもなく孵化'
                                  : '孵化まであと '
                                      '${widget.egg.remaining(params)}pt',
                          style: AppType.title,
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      NestRing(
                        diameter: ringDiameter,
                        glow: widget.egg.isNearHatch(params)
                            ? rarity.glow
                            : null,
                        // 風景の上なので砂色の円台は出さない（影だけ残す）。
                        showBase: false,
                        child: mofi != null
                            ? MofiSubject(
                                speciesId: mofi.speciesId,
                                family: mofi.family,
                                rarity: MofiRarity.rare,
                              )
                            : EggSubject(
                                rarity: widget.egg.rarity,
                                stage: stage,
                                animated: true,
                              ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      if (mofi == null)
                        StageChip(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GrowthProgressBar(value: progress),
                              const SizedBox(height: AppSpace.sm),
                              Text(
                                '${stage.label}・${(progress * 100).round()}%',
                                style: AppType.numLabel,
                              ),
                            ],
                          ),
                        ),
                      if (Env.previewStages) ...[
                        const SizedBox(height: AppSpace.sm),
                        _PreviewStageBar(
                          onSelect: (p) => setState(() {
                            _previewProgress = p;
                            _previewMofi = null;
                          }),
                          onReset: () => setState(() {
                            _previewProgress = null;
                            _previewMofi = null;
                          }),
                          onHatch: widget.onPreviewHatch,
                          onCycleMofi: () => setState(
                            () => _previewMofi = (_previewMofi ?? -1) + 1,
                          ),
                          onToggleZoom: () => setState(
                            () => _zoom = _zoom > 1.2 ? 1.0 : 1.45,
                          ),
                          zoomedIn: _zoom > 1.2,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 進捗 → 見た目の段階。`EggSubject` は段階から進捗へ戻す作りなので、
  /// お試し表示ではこちらで段階を決めて渡す。
  EggGrowthStage _stageFor(double p) {
    if (p >= 0.95) return EggGrowthStage.ready;
    if (p >= 0.6) return EggGrowthStage.crack2;
    if (p >= 0.3) return EggGrowthStage.crack1;
    return EggGrowthStage.intact;
  }
}

/// 【お試しビルド専用】「孵化した Mofi がこの背景の上でどう見えるか」の見本。
///
/// 現状のアプリに **Mofi を背景の上に出す画面は存在しない**（Mofi が出るのは
/// 図鑑と孵化演出の中だけ）。「相棒として世界に置く」のは新機能で、作るかどうかを
/// 決めるには**まず実物の見え方**が要る。種族でシルエットの大きさが違う
/// （スライムは丸く小さい／ドラゴンは縦に長い）ので4種族を比べられるようにする。
class _PreviewMofi {
  const _PreviewMofi(this.speciesId, this.family, this.label);

  final String speciesId;
  final MofiFamily family;
  final String label;

  static const all = <_PreviewMofi>[
    _PreviewMofi('slime_01', MofiFamily.slime, 'スライム'),
    _PreviewMofi('critter_01', MofiFamily.critter, '小動物'),
    _PreviewMofi('dragon_01', MofiFamily.dragon, 'ドラゴン'),
    _PreviewMofi('beast_01', MofiFamily.beast, '獣'),
  ];
}

/// 【お試しビルド専用】見た目を手で切り替える操作列。
///
/// 本番のポイントを貯めないと「ヒビ割れ」「孵化直前」に到達できず、実機で
/// 見た目を確認できないために用意した。`Env.previewStages` が true のときだけ
/// 描画され、そのフラグは `ios-build.yml` の入力（既定 false）でしか立たない。
/// **ストア提出ビルドには入らない。**
class _PreviewStageBar extends StatelessWidget {
  const _PreviewStageBar({
    required this.onSelect,
    required this.onReset,
    required this.onHatch,
    required this.onCycleMofi,
    required this.onToggleZoom,
    required this.zoomedIn,
  });

  final ValueChanged<double> onSelect;
  final VoidCallback onReset;
  final VoidCallback onHatch;
  final VoidCallback onCycleMofi;
  final VoidCallback onToggleZoom;
  final bool zoomedIn;

  @override
  Widget build(BuildContext context) {
    Widget btn(String label, VoidCallback onPressed) => GestureDetector(
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.bg.withValues(alpha: 0.92),
              borderRadius: AppRadius.smR,
              border: Border.all(color: AppColors.nestBark),
            ),
            child: Text(label, style: AppType.caption),
          ),
        );

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      runSpacing: 4,
      children: [
        btn('ヒビ前', () => onSelect(0.1)),
        btn('ヒビ小', () => onSelect(0.35)),
        btn('ヒビ大', () => onSelect(0.7)),
        btn('孵化直前', () => onSelect(0.97)),
        btn('孵化演出', onHatch),
        btn('Mofi切替', onCycleMofi),
        btn(zoomedIn ? '背景を引く' : '背景を寄せる', onToggleZoom),
        btn('実データ', onReset),
      ],
    );
  }
}



/// 孵化した直後の Mofi をステージに置いておく画面（オーナー提案 2026-08-19）。
///
/// 従来は孵化演出が終わると Mofi は即座に図鑑へ行き、たまごタブには「空の巣」
/// だけが残った。**育てた子を眺める間が1秒も無い**。コレクション型のいちばん
/// 嬉しい瞬間が、演出の数秒で消えていた。
///
/// ここで「図鑑に送る」を押すか、次の卵を育て始めるまで、世界の風景の上に残す。
/// 図鑑への登録自体は孵化時にサーバーが済ませているので、押し忘れても失われない
/// （このボタンは**表示を終える**ためのもので、データを動かすものではない）。
class _HatchedStage extends StatelessWidget {
  const _HatchedStage({
    required this.result,
    required this.stage,
    required this.onSendToDex,
  });

  final HatchResult result;

  /// 進化段階（1=ベビー / 2=アダルト）。C の実装で実データが入る。
  final int stage;

  /// 「図鑑に送る」＝この表示を終える。
  final VoidCallback onSendToDex;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final stageHeight = math.min(size.width * 1.15, size.height * 0.58);
    final ringDiameter = ((stageHeight - 180) / 1.12).clamp(96.0, 210.0);
    final rarity = RarityVisuals.ofMofi(result.species.rarity);

    return SizedBox(
      width: double.infinity,
      height: stageHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const Positioned.fill(child: WorldStageBackground()),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.lg,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                StageChip(
                  child: Text(
                    result.isShiny
                        ? '✨ ${result.species.name}'
                        : result.species.name,
                    style: AppType.title,
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                NestRing(
                  diameter: ringDiameter,
                  glow: result.isShiny ? rarity.glow : rarity.main,
                  // 風景の上なので砂色の円台は出さない（影だけ残す）。
                  showBase: false,
                  child: MofiSubject(
                    speciesId: result.species.id,
                    family: result.species.family,
                    rarity: result.species.rarity,
                    stage: stage,
                    isShiny: result.isShiny,
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                StageChip(
                  child: GestureDetector(
                    onTap: onSendToDex,
                    child: Text(
                      '図鑑に送る',
                      style: AppType.bodyStrong.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 保管枠アップセル（無料上限に近づいたらペイウォールへ誘導）。
///
/// 表示条件: クライアント非プレミアム かつ 保管数が無料上限の8割以上。
/// しきい値・上限は [StorageLimits]（SSOT）を参照しハードコードしない。
/// 注意（信頼境界）: ここはあくまで導線。実際の保管枠ガード（200解放）はサーバー検証が正。
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

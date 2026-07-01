import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/iap/iap_models.dart';
import '../../../core/iap/iap_providers.dart';
import '../../../core/iap/iap_service.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/observability_providers.dart';
import '../../../core/sync/connectivity_provider.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/nest_panel.dart';
import '../../../core/widgets/state_views.dart';
import 'paywall_controller.dart';

/// ペイウォール画面（プレミアム購入 / DESIGN_SYSTEM 準拠・PRICING §1,§4）。
///
/// 5状態（DoD / ARCHITECTURE §0-3）:
///   * ローディング: offerings 取得中 → 巣リング型スケルトン。
///   * エラー: 取得失敗 → ErrorView + リトライ（offeringsProvider 再取得）。
///   * 空: 提示プランなし（未設定/商品未取得）→ EmptyState（診断付き案内）。
///   * ハッピー: 月額/年額カード + 特典 + 購入/復元/管理導線。
///   * オフライン: 上端バー + 購入/復元ボタンのグレーアウト（理由表示）。
///
/// 表示の鉄則:
///   * 価格は **StoreProduct.priceString（ストア実額）** を表示（ハードコード禁止）。
///   * トライアル文言は **資格 eligible のときだけ**（PlanOffer.showTrialBadge / iap-setup）。
///   * 特典は **実装済みのものだけ**（PremiumBenefits.active / 詳細分析は宣伝しない）。
class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});

  static const String routeName = 'paywall';
  static const String routePath = '/paywall';

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  @override
  void initState() {
    super.initState();
    // ファネル: ペイウォール表示（課金ファネルの入口 / PRD §5-5）。
    // 入口に依らず1度だけ発火（呼び出し側で重複発火させない）。
    ref.read(analyticsProvider).capture(AnalyticsEvents.paywallViewed);
  }

  @override
  Widget build(BuildContext context) {
    final offeringsAsync = ref.watch(offeringsProvider);
    final isOnline = ref.watch(isOnlineProvider);
    // 既にプレミアムなら「加入済み」を反映（購入直後の即時UI / 補助情報）。
    final isPremium = ref.watch(isPremiumProvider);

    // 購入/復元の結果を監視し、SnackBar で通知（成功時は画面を閉じる）。
    ref.listen<PaywallActionState>(paywallControllerProvider, (prev, next) {
      final result = next.lastResult;
      if (result == null || next.isBusy) return;
      _handleResult(context, ref, result);
    });

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('プレミアム')),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (!isOnline) const OfflineBar(),
            Expanded(
              child: offeringsAsync.when(
                loading: () =>
                    const Center(child: NestSkeleton(label: 'プランを読み込んでいます')),
                error: (e, _) => ErrorView(
                  message: 'プランの読み込みに失敗しました。通信環境を確認してもう一度お試しください。',
                  onRetry: () =>
                      ref.read(paywallControllerProvider.notifier).retryOfferings(),
                ),
                data: (offerings) => offerings.isEmpty
                    ? _EmptyOfferings(
                        onRetry: () => ref
                            .read(paywallControllerProvider.notifier)
                            .retryOfferings(),
                      )
                    : _PaywallBody(
                        offerings: offerings,
                        isOnline: isOnline,
                        isAlreadyPremium: isPremium,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 購入/復元結果のユーザー通知（5分岐 / iap-setup エラーハンドリング）。
  void _handleResult(BuildContext context, WidgetRef ref, IapResult result) {
    final messenger = ScaffoldMessenger.of(context);
    switch (result.outcome) {
      case IapPurchaseOutcome.success:
        messenger.showSnackBar(
          const SnackBar(content: Text('プレミアムへようこそ。特典が解放されました。')),
        );
        // 成功時は1つ戻る（呼び出し元へ）。
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      case IapPurchaseOutcome.cancelled:
        // ユーザー操作のキャンセルはエラー表示しない（無言）。
        break;
      case IapPurchaseOutcome.pending:
        messenger.showSnackBar(
          SnackBar(content: Text(result.message ?? 'お支払いの承認待ちです。')),
        );
      case IapPurchaseOutcome.nothingToRestore:
        messenger.showSnackBar(
          SnackBar(content: Text(result.message ?? '復元できる購入が見つかりませんでした。')),
        );
      case IapPurchaseOutcome.failed:
        // 診断コードを併記（スクショ1枚で原因特定 / iap-setup）。
        final diag = result.diagnosticCode;
        final msg = result.message ?? '処理に失敗しました。もう一度お試しください。';
        messenger.showSnackBar(
          SnackBar(content: Text(diag == null ? msg : '$msg（$diag）')),
        );
    }
  }
}

/// プラン提示なし（未設定/商品未取得）の空状態。
class _EmptyOfferings extends StatelessWidget {
  const _EmptyOfferings({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.workspace_premium_outlined,
      message: 'プランを準備中です',
      subMessage: 'もう少しお待ちください。時間をおいて再度お試しください。',
      ctaLabel: '再読み込み',
      onCta: onRetry,
    );
  }
}

class _PaywallBody extends ConsumerStatefulWidget {
  const _PaywallBody({
    required this.offerings,
    required this.isOnline,
    required this.isAlreadyPremium,
  });

  final IapOfferings offerings;
  final bool isOnline;
  final bool isAlreadyPremium;

  @override
  ConsumerState<_PaywallBody> createState() => _PaywallBodyState();
}

class _PaywallBodyState extends ConsumerState<_PaywallBody> {
  /// 選択中のプラン。既定は年額（おすすめ / PRICING §1-3 アンカリング）。
  BillingPeriod _selected = BillingPeriod.annual;

  @override
  Widget build(BuildContext context) {
    final offerings = widget.offerings;
    final action = ref.watch(paywallControllerProvider);
    final monthly = offerings.monthly;
    final annual = offerings.annual;

    // 年額の割安訴求（ストア実額から算出。価格未取得なら null=訴求しない）。
    final savings = (monthly != null && annual != null)
        ? AnnualSavings.compute(
            monthlyAmount: monthly.priceAmount,
            annualAmount: annual.priceAmount,
          )
        : null;

    final selectedPlan =
        _selected == BillingPeriod.annual ? annual : monthly;

    return ListView(
      padding: const EdgeInsets.all(AppSpace.lg),
      children: [
        // ヘッダ（巣リングの世界観を踏襲）。
        NestPanel(
          diameter: 120,
          subject: const Icon(
            Icons.workspace_premium_rounded,
            color: AppColors.primary,
          ),
          caption: Text('Moffyプレミアム', style: AppType.title),
          footer: Text(
            'コレクションを本気で楽しむあなたへ。',
            style: AppType.caption,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: AppSpace.xl),

        // 既にプレミアムなら案内（重複購入防止）。
        if (widget.isAlreadyPremium) ...[
          const _AlreadyPremiumCard(),
          const SizedBox(height: AppSpace.xl),
        ],

        // 特典リスト（実装済みのみ / PremiumBenefits.active）。
        _BenefitsCard(benefits: PremiumBenefits.active),
        const SizedBox(height: AppSpace.xl),

        // プラン選択（月額/年額）。
        Text('プランを選ぶ', style: AppType.bodyStrong),
        const SizedBox(height: AppSpace.md),
        if (annual != null)
          _PlanCard(
            plan: annual,
            selected: _selected == BillingPeriod.annual,
            recommended: true,
            savings: savings,
            onTap: () => setState(() => _selected = BillingPeriod.annual),
          ),
        if (annual != null && monthly != null)
          const SizedBox(height: AppSpace.md),
        if (monthly != null)
          _PlanCard(
            plan: monthly,
            selected: _selected == BillingPeriod.monthly,
            recommended: false,
            savings: null,
            onTap: () => setState(() => _selected = BillingPeriod.monthly),
          ),
        const SizedBox(height: AppSpace.xl),

        // 購入ボタン（オフライン/進行中はグレーアウト）。
        PrimaryButton(
          label: _purchaseLabel(selectedPlan),
          onPressed: (!widget.isOnline ||
                  action.isBusy ||
                  selectedPlan == null ||
                  widget.isAlreadyPremium)
              ? null
              : () => ref
                  .read(paywallControllerProvider.notifier)
                  .purchase(selectedPlan),
        ),
        if (!widget.isOnline) ...[
          const SizedBox(height: AppSpace.sm),
          Text(
            'オフラインです。購入はオンラインでのみ可能です。',
            style: AppType.caption.copyWith(color: AppColors.offline),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: AppSpace.md),

        // 自動更新・解約の注記（PRICING §1-1 / 3.1.2 必須表記）。
        _SubscriptionNotice(plan: selectedPlan),
        const SizedBox(height: AppSpace.lg),

        // 復元 / サブスク管理（解約はストアから）。
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: (!widget.isOnline || action.isBusy)
                    ? null
                    : () => ref
                        .read(paywallControllerProvider.notifier)
                        .restore(),
                child: const Text('購入を復元'),
              ),
            ),
            Expanded(
              child: TextButton(
                onPressed: () => _openManagement(context),
                child: const Text('サブスクの管理'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.xl),
      ],
    );
  }

  String _purchaseLabel(PlanOffer? plan) {
    if (plan == null) return '購入する';
    if (plan.showTrialBadge) {
      final label = plan.trialPeriodLabel ?? '無料';
      return '$label 無料ではじめる';
    }
    return 'プレミアムにする';
  }

  /// ストアの定期購読管理画面を開く（解約導線 / アプリ内では解約不可）。
  Future<void> _openManagement(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final url = await ref.read(paywallControllerProvider.notifier).managementUrl();
    if (url != null) {
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text('管理画面を開けませんでした。端末の設定アプリからサブスクをご確認ください。')),
        );
      }
      return;
    }
    // URL 未取得（未購入/未設定）→ ストア別の案内（解約手段の明示 / 審査要件）。
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          '解約・管理は端末のストア設定（App Store / Google Play の定期購読）から行えます。',
        ),
      ),
    );
  }
}

/// 既にプレミアム加入済みの案内。
class _AlreadyPremiumCard extends StatelessWidget {
  const _AlreadyPremiumCard();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(
        children: [
          const Icon(Icons.verified_rounded, color: AppColors.success),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              'プレミアムに加入中です。特典をお楽しみください。',
              style: AppType.bodyStrong,
            ),
          ),
        ],
      ),
    );
  }
}

/// 特典リストカード（実装済み特典のみ。アイコンは Material / 絵文字不使用）。
class _BenefitsCard extends StatelessWidget {
  const _BenefitsCard({required this.benefits});
  final List<PremiumBenefit> benefits;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('プレミアム特典', style: AppType.title),
          const SizedBox(height: AppSpace.lg),
          for (final b in benefits) ...[
            _BenefitRow(benefit: b),
            if (b != benefits.last) const SizedBox(height: AppSpace.lg),
          ],
        ],
      ),
    );
  }
}

class _BenefitRow extends StatelessWidget {
  const _BenefitRow({required this.benefit});
  final PremiumBenefit benefit;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(_iconFor(benefit.kind), color: AppColors.primary, size: 22),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(benefit.title, style: AppType.bodyStrong),
              const SizedBox(height: AppSpace.xs),
              Text(benefit.description, style: AppType.caption),
            ],
          ),
        ),
      ],
    );
  }

  IconData _iconFor(PremiumBenefitKind kind) {
    switch (kind) {
      case PremiumBenefitKind.storage:
        return Icons.inventory_2_outlined;
      case PremiumBenefitKind.exclusiveMofi:
        return Icons.auto_awesome_outlined;
      case PremiumBenefitKind.premiumEgg:
        return Icons.egg_outlined;
      case PremiumBenefitKind.adFree:
        return Icons.block_outlined;
    }
  }
}

/// プラン1件のカード（ストア実額を主役表示 / 年額は割安訴求 + トライアル条件表示）。
class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.plan,
    required this.selected,
    required this.recommended,
    required this.savings,
    required this.onTap,
  });

  final PlanOffer plan;
  final bool selected;
  final bool recommended;
  final AnnualSavings? savings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final periodLabel =
        plan.period == BillingPeriod.annual ? '年額' : '月額';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: AppRadius.lgR,
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // ラジオ的な選択表現。
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? AppColors.primary : AppColors.textDisabled,
                ),
                const SizedBox(width: AppSpace.md),
                Text(periodLabel, style: AppType.bodyStrong),
                const Spacer(),
                if (recommended)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md,
                      vertical: AppSpace.xs,
                    ),
                    decoration: const BoxDecoration(
                      color: AppColors.primarySoft,
                      borderRadius: AppRadius.pillR,
                    ),
                    child: Text(
                      'おすすめ',
                      style: AppType.caption
                          .copyWith(color: AppColors.primaryDeep),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            // 実額（主役 / Baloo 数字 ではなく価格文字列はストア値そのまま）。
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                // ストア実額は priceString をそのまま（通貨記号込み）。主役強調。
                Text(plan.priceString, style: AppType.numHero),
                const SizedBox(width: AppSpace.xs),
                Text(
                  plan.period == BillingPeriod.annual ? '/年' : '/月',
                  style: AppType.caption,
                ),
              ],
            ),
            // 年額の従属表示（月あたり換算・割引%。3.1.2c: 実額より目立たせない）。
            if (plan.period == BillingPeriod.annual && savings != null) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                '月あたり約 ${_perMonthLabel(savings!, plan.currencyCode)}'
                '・約${savings!.discountPercent}%お得',
                style: AppType.caption.copyWith(color: AppColors.successDeep),
              ),
            ],
            // トライアル文言: 資格 eligible のときだけ表示（iap-setup / リジェクト回避）。
            if (plan.showTrialBadge) ...[
              const SizedBox(height: AppSpace.sm),
              Row(
                children: [
                  const Icon(
                    Icons.card_giftcard_rounded,
                    size: 16,
                    color: AppColors.successDeep,
                  ),
                  const SizedBox(width: AppSpace.xs),
                  Text(
                    '${plan.trialPeriodLabel ?? ''}無料トライアルつき',
                    style:
                        AppType.caption.copyWith(color: AppColors.successDeep),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 月あたり換算の簡易表示（記号は通貨コードに依存しないため概数表記）。
  /// 厳密なローカライズ記号付き表示はストア値（priceString）が主役のため、
  /// ここは「約N」の概数（数値）に留める（誤認防止・3.1.2c の従属表示）。
  String _perMonthLabel(AnnualSavings s, String currency) {
    final amount = s.perMonthAmount;
    // 整数なら小数点を出さない。
    final num shown = amount == amount.roundToDouble() ? amount.round() : amount;
    // 日本円は「円」で表示（英略号 JPY の露出を避ける）。他通貨はコードにフォールバック。
    if (currency == 'JPY') return '$shown円';
    return '$shown $currency';
  }
}

/// 自動更新・解約の注記（PRICING §1-1 / Apple 3.1.2・必須表記）。
class _SubscriptionNotice extends StatelessWidget {
  const _SubscriptionNotice({required this.plan});
  final PlanOffer? plan;

  @override
  Widget build(BuildContext context) {
    final price = plan?.priceString ?? '';
    final period = plan?.period == BillingPeriod.annual ? '年' : '月';
    final trialPrefix = (plan?.showTrialBadge ?? false)
        ? '無料トライアル終了後、'
        : '';
    return Text(
      '$trialPrefix$price/$period で自動更新されます。'
      'いつでもキャンセル可能です。解約は各ストアの定期購読管理から行えます。'
      '期間終了の24時間前までに解約しない限り自動更新されます。',
      style: AppType.caption.copyWith(color: AppColors.textSecondary),
    );
  }
}

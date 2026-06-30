import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/navigation/app_tab.dart';
import '../../../core/observability/analytics_events.dart';
import '../../../core/observability/observability_providers.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/common_widgets.dart';
import '../../../core/widgets/egg_art.dart';
import '../../../core/widgets/nest_panel.dart';

/// 歓迎画面（=最初の卵プレゼント / SCREEN_FLOWS §1 OB3）。
///
/// オンボーディング完了直後・ホームに入る前に一度だけ表示する「橋渡し」画面。
/// 目的は初回ユーザーの「使い方が分からない」を解消すること：
///   1. これからあなたが育てる **最初の卵** を主役として見せる（巣リング＋微発光）。
///   2. コアループ（減らす→ポイント→卵が育つ→孵化）を 1→2→3 で言葉にする。
///   3. CTA でホームへ。ホーム初回ロードで warmup（+200pt と最初の卵）が付与され、
///      この画面で見せた卵が「はじまりのボーナス」として実体化する（home_controller）。
///
/// 状態は持たない（表示は1回・経路で担保）。オンボーディングは初回のみ表示されるため、
/// `_finish()` からこの画面に来るのも初回のみ。別フラグは不要。
class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  static const String routePath = '/welcome';
  static const String routeName = 'welcome';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // スクロール領域（小さい端末でも溢れない）。
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: AppSpace.lg),
                      // 主役: 最初の卵（実イラスト）を巣リングに乗せて微発光。
                      NestRing(
                        diameter: 200,
                        glow: RarityToken.common.glow,
                        child: const EggArt(rarity: RarityToken.common),
                      ),
                      const SizedBox(height: AppSpace.xl),
                      Text(
                        'ようこそ、Moffyへ',
                        style: AppType.display,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpace.md),
                      Text(
                        'これがあなたの最初の卵。\n'
                        'SNSを見ない時間で、いっしょに育てていきましょう。',
                        style: AppType.body,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpace.xxl),
                      // コアループを 1→2→3 で説明（「使い方が分からない」対策の核）。
                      const _HowToStep(
                        index: 1,
                        icon: Icons.timer_outlined,
                        text: 'SNSを減らすと、その時間がポイントになります。',
                      ),
                      const SizedBox(height: AppSpace.md),
                      const _HowToStep(
                        index: 2,
                        icon: Icons.egg_rounded,
                        text: 'ポイントがたまると、卵が少しずつ育ちます。',
                      ),
                      const SizedBox(height: AppSpace.md),
                      const _HowToStep(
                        index: 3,
                        icon: Icons.auto_awesome_rounded,
                        text: '育ちきると、Mofiが生まれて図鑑に加わります。',
                      ),
                      const SizedBox(height: AppSpace.lg),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              PrimaryButton(
                label: '最初の卵を受け取る',
                icon: Icons.egg_rounded,
                onPressed: () {
                  // ファネル: 歓迎完了＝ホーム到達（warmup 付与の直前）。
                  ref
                      .read(analyticsProvider)
                      .capture(AnalyticsEvents.welcomeCompleted);
                  context.go(AppTab.home.path);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// コアループ説明の 1ステップ（番号付きの巣色チップ + アイコン + 文）。
class _HowToStep extends StatelessWidget {
  const _HowToStep({
    required this.index,
    required this.icon,
    required this.text,
  });

  final int index;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.lgR,
        boxShadow: AppElevation.card,
      ),
      child: Row(
        children: [
          // 番号バッジ（巣の砂色 + 主役オレンジの数字 / Baloo 2）。
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.surfaceNest,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: AppType.numLabel.copyWith(color: AppColors.primaryDeep),
            ),
          ),
          const SizedBox(width: AppSpace.md),
          Icon(icon, color: AppColors.primary, size: AppSpace.tabIcon),
          const SizedBox(width: AppSpace.md),
          Expanded(child: Text(text, style: AppType.body)),
        ],
      ),
    );
  }
}

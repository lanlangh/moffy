import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'nest_panel.dart';

/// 5状態（ローディング / エラー / 空 / オフライン）の共通表現。
/// DESIGN_SYSTEM §7・SCREEN_FLOWS §7 の統一ルールに準拠。
/// ハッピーパスは各画面が自前で描画する。

/// 巣リング型のシマー（ローディング / SCREEN_FLOWS §7「待ち時間も世界観に」）。
/// 中央汎用スピナーを全画面で多用しない、という禁止事項に沿う。
class NestSkeleton extends StatefulWidget {
  const NestSkeleton({super.key, this.diameter = 160, this.label});

  final double diameter;
  final String? label;

  @override
  State<NestSkeleton> createState() => _NestSkeletonState();
}

class _NestSkeletonState extends State<NestSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RotationTransition(
          turns: _c,
          child: NestRing(
            diameter: widget.diameter,
            child: const Icon(
              Icons.egg_outlined,
              color: AppColors.textDisabled,
            ),
          ),
        ),
        if (widget.label != null) ...[
          const SizedBox(height: AppSpace.md),
          Text(widget.label!, style: AppType.caption),
        ],
      ],
    );
  }
}

/// エラー表示（局所バナー or 中央）。リトライ必須。
/// 全画面を真っ赤にしない・ユーザーを責めない（DESIGN_SYSTEM §8）。
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = 'もう一度',
    this.compact = false,
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;

  /// true なら局所バナー（カード内）、false なら中央配置。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          compact ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          message,
          style: AppType.body,
          textAlign: compact ? TextAlign.start : TextAlign.center,
        ),
        if (onRetry != null) ...[
          const SizedBox(height: AppSpace.md),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              shape:
                  const RoundedRectangleBorder(borderRadius: AppRadius.pillR),
            ),
            child: Text(retryLabel),
          ),
        ],
      ],
    );

    if (compact) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: AppColors.error.withValues(alpha: 0.08),
          borderRadius: AppRadius.lgR,
        ),
        child: content,
      );
    }
    return Center(child: Padding(padding: const EdgeInsets.all(AppSpace.xl), child: content));
  }
}

/// 空状態（EmptyState / DESIGN_SYSTEM §7）。巣リング + 1行コピー + CTA1つ。
/// 「データがありません」だけの素っ気ない表示を禁止する。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.subMessage,
    this.ctaLabel,
    this.onCta,
    this.icon = Icons.hourglass_empty_rounded,
  });

  final String message;
  final String? subMessage;
  final String? ctaLabel;
  final VoidCallback? onCta;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 「空の巣」表現（署名要素を空状態でも反復）
            NestRing(
              diameter: 120,
              child: Icon(icon, color: AppColors.textDisabled),
            ),
            const SizedBox(height: AppSpace.xl),
            Text(message, style: AppType.title, textAlign: TextAlign.center),
            if (subMessage != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                subMessage!,
                style: AppType.caption,
                textAlign: TextAlign.center,
              ),
            ],
            if (ctaLabel != null && onCta != null) ...[
              const SizedBox(height: AppSpace.xl),
              ElevatedButton(onPressed: onCta, child: Text(ctaLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

/// オフライン上端バー（SCREEN_FLOWS §7）。細い state.offline バー。
class OfflineBar extends StatelessWidget {
  const OfflineBar({
    super.key,
    this.message = 'オフライン・あとで同期します',
  });

  final String message;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.offline,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpace.xs,
            horizontal: AppSpace.lg,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.cloud_off_rounded,
                size: 14,
                color: AppColors.onPrimary,
              ),
              const SizedBox(width: AppSpace.xs),
              Text(
                message,
                style: AppType.caption.copyWith(color: AppColors.onPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/state_views.dart';
import '../../domain/home_state.dart';

/// 「今日のSNS削減」カード（SCREEN_FLOWS §2）。
/// 状態に応じてハッピー / ウォームアップ / マイナス日 / 権限なし を出し分ける。
class ReductionCard extends StatelessWidget {
  const ReductionCard({
    super.key,
    required this.state,
    required this.onRequestPermission,
  });

  final HomeState state;
  final VoidCallback onRequestPermission;

  @override
  Widget build(BuildContext context) {
    // 権限なし: 削減カードのみフォールバック（卵/通貨は通常表示 / §5-1）。
    if (state.isPermissionMissing) {
      return AppCard(
        child: ErrorView(
          message: '時間をはかるには「使用状況へのアクセス」の許可が必要です。'
              '許可すると今日の削減ポイントが計算されます。',
          retryLabel: '許可する',
          onRetry: onRequestPermission,
          compact: true,
        ),
      );
    }

    // ウォームアップ期（Day1〜2）: 削減数値を出さずプレースホルダ（S1）。
    if (state.isWarmup) {
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今日のSNS削減', style: AppType.bodyStrong),
            const SizedBox(height: AppSpace.sm),
            // 日本語文なので数字用フォント(Baloo)ではなく見出し体(Zen Maru)を使う。
            Text('明日から計測スタート', style: AppType.title),
            const SizedBox(height: AppSpace.xs),
            Text(
              '最初の数日は初回ボーナス卵でMofiを育てよう。'
              '基準値は7日分たまると確定します。',
              style: AppType.caption,
            ),
          ],
        ),
      );
    }

    // マイナス日（S2）: 責めない・赤一色にしない（warm.apricot 地）。
    if (state.isOverBaseline) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: AppColors.primarySoft.withValues(alpha: 0.5),
          borderRadius: AppRadius.lgR,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('今日のSNS削減', style: AppType.bodyStrong),
            const SizedBox(height: AppSpace.sm),
            Text('+0pt', style: AppType.numHero),
            const SizedBox(height: AppSpace.xs),
            Text(
              '今日は少し多めだったみたい。明日はMofiのために少し減らそう。',
              style: AppType.caption,
            ),
          ],
        ),
      );
    }

    // ハッピーパス: 削減プラス。grow.green の主役数字（Baloo）。
    final reduction = state.reductionMinutes;
    final pt = state.provisionalPoints;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('今日のSNS削減', style: AppType.bodyStrong),
              if (state.baseline.isProvisional) const _ProvisionalLabel(),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            _formatDuration(reduction),
            style: AppType.numHero.copyWith(color: AppColors.success),
          ),
          const SizedBox(height: AppSpace.xs),
          Row(
            children: [
              Text('今日の獲得 ', style: AppType.caption),
              Text('+$pt pt', style: AppType.numLabel),
              if (state.yesterdayMinutes != null) ...[
                const SizedBox(width: AppSpace.md),
                Text(
                  _yesterdayCompare(state),
                  style: AppType.caption,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h > 0) return '+$h時間$m分';
    return '+$m分';
  }

  String _yesterdayCompare(HomeState state) {
    final today = state.todayUsage?.totalMinutes ?? 0;
    final y = state.yesterdayMinutes!;
    final diff = y - today;
    if (diff > 0) return '昨日より$diff分減';
    if (diff < 0) return '昨日より${-diff}分増';
    return '昨日と同じ';
  }
}

class _ProvisionalLabel extends StatelessWidget {
  const _ProvisionalLabel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warn.withValues(alpha: 0.18),
        borderRadius: AppRadius.smR,
      ),
      child: Text(
        '暫定（7日分で確定）',
        style: AppType.caption.copyWith(color: AppColors.warn),
      ),
    );
  }
}

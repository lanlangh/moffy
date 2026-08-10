import 'package:flutter/material.dart';

import '../../../../core/constants/economy.dart';
import '../../../../core/theme/tokens.dart';
import '../../../../core/usage/usage_models.dart';

/// 対象4アプリ別の時間チップ（SCREEN_FLOWS §2-5）。
/// 各アプリ（TikTok/Instagram/YouTube/X）の利用分を表示。0分も正常表示（§5-1）。
///
/// ⚠️ **アプリ別の内訳が取れるのは Android だけ**。iOS の Screen Time
/// （FamilyControls）はプライバシー保護のため不透明トークンでしかアプリを扱えず、
/// 個別アプリを識別できない（docs/IOS_SCREENTIME.md）。iOS の利用時間は
/// `ios.screentime` という合成バケット1本に集約されるため、ここに渡しても
/// 全アプリが「0分」として並ぶ＝**削減できているのに0分と表示する嘘**になる。
/// 呼び出し側の分岐だけに頼ると再発するので、ウィジェット自身にも契約を持たせて
/// [UsageMode.exactMinutes] 以外では何も描かない。
class AppUsageChips extends StatelessWidget {
  const AppUsageChips({
    super.key,
    required this.perAppMinutes,
    required this.mode,
  });

  /// パッケージ名 -> 利用分。
  final Map<String, int> perAppMinutes;

  /// 計測モード。[UsageMode.exactMinutes]（Android）以外では内訳を描かない。
  final UsageMode mode;

  @override
  Widget build(BuildContext context) {
    if (mode != UsageMode.exactMinutes) {
      // iOS 等: アプリ別内訳が存在しない。呼び出し側が分岐を忘れても嘘を出さない。
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        for (final def in AppConstants.defaultAndroidTargets)
          _Chip(
            label: def.label,
            minutes: perAppMinutes[def.packageName] ?? 0,
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.minutes});

  final String label;
  final int minutes;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: AppRadius.pillR,
        boxShadow: AppElevation.card,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // SVGアイコンは後続でアセット差し替え。MVPはラベル先頭文字の代替表示。
          // 先頭文字アバターは装飾（フル名は隣の Text が読み上げる）→ 読み上げから除外。
          ExcludeSemantics(
            child: CircleAvatar(
              radius: 10,
              backgroundColor: AppColors.surfaceNest,
              child: Text(
                label.characters.first,
                style: AppType.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(width: AppSpace.xs),
          Text('$label ', style: AppType.caption),
          // 削減カード（○時間○分）と表記を統一。日本語混じりなので本文太字で描く
          // （数字用フォント Baloo は日本語グリフを持たず字化けするため）。
          Text(_format(minutes), style: AppType.bodyStrong),
        ],
      ),
    );
  }

  String _format(int m) {
    if (m >= 60) return '${m ~/ 60}時間${m % 60}分';
    return '$m分';
  }
}

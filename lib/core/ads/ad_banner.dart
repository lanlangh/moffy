import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../iap/iap_providers.dart';
import '../iap/server_entitlement.dart';
import 'ads.dart';

/// 画面下部に出す**無料ユーザー向けバナー広告**（PRICING §2 の「広告」境界）。
///
/// 表示条件:
///   * プレミアム（[isPremiumProvider]）なら **非表示**（＝有料特典「広告削除」の実体）。
///   * Web / デスクトップは [AdBannerView] 側が自動で no-op（何も表示しない）。
///   * モバイル無料ユーザーにのみ AdMob バナーを描画（読み込み前は高さ0）。
///
/// プレミアム判定は表示用の [isPremiumProvider]（server || client）を使う。広告の
/// 出し分けは体験の問題であり、改ざん耐性が要る確定ガードではないため表示側で十分。
class AdBanner extends ConsumerWidget {
  const AdBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPremium = ref.watch(isPremiumProvider);
    // プレミアム判定が未確定(loading)の間は保守的に非表示にし、プレミアムへ広告を
    // 要求/表示しない。Noop/RevenueCat どちらのストリームも即値を流すため、無料ユーザーで
    // 広告が永久に出ない事故は起きない（settle 後に表示される）。
    final resolving = ref.watch(premiumStatusProvider).isLoading ||
        ref.watch(serverPremiumProvider).isLoading;
    if (isPremium || resolving) return const SizedBox.shrink();
    return const AdBannerView();
  }
}

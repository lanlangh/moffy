import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../iap/iap_models.dart';
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
    final clientStatus = ref.watch(premiumStatusProvider);
    final serverStatus = ref.watch(serverPremiumProvider);

    // プレミアム判定が未確定(loading)の間は保守的に非表示にし、プレミアムへ広告を
    // 要求/表示しない。Noop/RevenueCat どちらのストリームも即値を流すため、無料ユーザーで
    // 広告が永久に出ない事故は起きない（settle 後に表示される）。
    final resolving = clientStatus.isLoading || serverStatus.isLoading;

    // サーバー判定が不明(未設定/取得失敗/タイムアウト = null)で、かつクライアント側も
    // 取得に失敗している([PremiumSource.none]) ときは「無課金だと確認できていない」。
    // ここで広告を出すと**課金済みユーザーにバナーが出る**ため、確定するまで非表示に
    // 倒す（fail-closed）。両方が同時に落ちるのは劣悪ネットワーク下で相関するため、
    // 理論上の穴ではなく実際に起こりうる。
    //   * [PremiumSource.mock] は RevenueCat 未設定＝そもそも課金しようがないので対象外
    //     （ここまで塞ぐと無料ユーザーに広告が出なくなる）。
    final unconfirmed = serverStatus.valueOrNull == null &&
        clientStatus.valueOrNull?.source == PremiumSource.none;

    if (isPremium || resolving || unconfirmed) return const SizedBox.shrink();
    return const AdBannerView();
  }
}

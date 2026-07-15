/// 広告のプラットフォーム実装（**モバイル(Android/iOS)向け・AdMob**）。
///
/// `ads.dart` の条件付き export で `dart.library.io` が true のとき使われる。
/// Android/iOS 以外（デスクトップ・CIのDart VM 等）では実際には広告を出さず
/// no-op に倒す（`_adsSupported` ガード）＝安全に素通りする。
library;

import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../observability/log.dart';
import 'ad_config.dart';

/// 無料プランで**実際に広告が表示される**プラットフォームか（UIの「広告オフ」訴求の出し分け用）。
/// **iOS v1.0 は広告なし（CEO裁定 2026-07-15）**＝iOS では AdMob を初期化も表示もしないため false。
/// AdMob 自体は Android/iOS 対応だが、ここで iOS を除外し Android のみ true にする
/// （ATT/トラッキング申告を避け審査を簡素化。iOS 広告は v1.1 で ATT 実装とともに検討）。
/// Web/デスクトップは `ads_platform_stub.dart` 側が false を返す（AdMob 非対応）。
bool get freeTierAdsActive => Platform.isAndroid;

/// 広告を初期化/表示するプラットフォームか（内部ガード）。実際に広告を出す可否と同一のため
/// [freeTierAdsActive] を単一情報源として参照する（同じ条件を二重定義しない）。
bool get _adsSupported => freeTierAdsActive;

/// AdMob SDK を初期化（モバイルのみ）。失敗してもアプリは止めない（広告が出ないだけ）。
Future<void> initAds() async {
  if (!_adsSupported) return;
  try {
    await MobileAds.instance.initialize();
  } catch (e) {
    // 初期化失敗でもアプリは止めない（広告が出ないだけ）。原因は残す。
    Log.d('AdMob init failed: $e');
  }
}

/// 画面下部のバナー広告。プレミアム判定は呼び出し側（[AdBanner]）で行うため、
/// ここは「無料ユーザーに実際の広告を描画する」責務のみを持つ。
/// 読み込み完了までは高さ0で、広告が来たら下からせり上がる（未対応/未ロードは非表示）。
class AdBannerView extends StatefulWidget {
  const AdBannerView({super.key});

  @override
  State<AdBannerView> createState() => _AdBannerViewState();
}

class _AdBannerViewState extends State<AdBannerView> {
  BannerAd? _ad;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    if (_adsSupported) _load();
  }

  void _load() {
    final ad = BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          _ad = null; // 破棄済み参照を残さない（dispose() 側の二重 dispose を避ける）。
        },
      ),
    )..load();
    _ad = ad;
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (!_adsSupported || !_loaded || ad == null) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      height: ad.size.height.toDouble(),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: ad.size.width.toDouble(),
          height: ad.size.height.toDouble(),
          child: AdWidget(ad: ad),
        ),
      ),
    );
  }
}

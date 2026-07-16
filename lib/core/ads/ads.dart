/// 広告モジュールの公開窓口（プラットフォーム実装を条件付きで切り替える）。
///
/// - Web / 非対応環境（`dart.library.io` が false）… `ads_platform_stub.dart`（no-op）。
/// - モバイル等（`dart.library.io` が true）……………… `ads_platform_io.dart`（AdMob）。
///
/// これにより **Web ビルドは google_mobile_ads を一切 import せず**、Web プレビューが
/// 壊れない。公開する API は `initAds()` / `AdBannerView` / `freeTierAdsActive`
/// （無料プランで実際に広告が出るプラットフォームか＝Android/iOS で true・Web は false）。
/// プレミアム判定によるオン/オフは [AdBanner]（ad_banner.dart）が担う。
library;

export 'ads_platform_stub.dart'
    if (dart.library.io) 'ads_platform_io.dart';

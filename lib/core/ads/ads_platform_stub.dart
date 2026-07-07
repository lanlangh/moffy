/// 広告のプラットフォーム実装（**Web / 非対応環境向けスタブ**）。
///
/// AdMob（google_mobile_ads）は Web 非対応のため、Web ビルドではこのスタブが使われる
/// （`ads.dart` の条件付き export・`dart.library.io` が false のとき）。
/// これにより Web プレビュービルドが google_mobile_ads に一切触れず壊れない。
library;

import 'package:flutter/widgets.dart';

/// 広告SDK初期化（スタブ＝何もしない）。
Future<void> initAds() async {}

/// バナー広告（スタブ＝何も表示しない）。
class AdBannerView extends StatelessWidget {
  const AdBannerView({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

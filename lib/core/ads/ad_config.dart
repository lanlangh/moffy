/// AdMob の広告ユニット / アプリID（学習・テスト用の設定）。
///
/// 現在は **Google 公式の「テスト広告ユニットID」** を使用している。
///   * AdMob アカウント不要で常にテスト広告が出る。
///   * 自分でタップしても規約違反（不正クリック）にならない安全な値。
/// 本番で収益化するときは、AdMob 管理画面で作成した **実際のユニットID** に差し替える
/// （下記 TODO）。アプリID（AndroidManifest.xml / ios/Runner/Info.plist の
/// APPLICATION_ID / GADApplicationIdentifier）も同様にテスト値 → 実値へ。
///
/// 注意: 本ファイルは **モバイル(io)実装からのみ import される**（Web は import しない）。
library;

import 'dart:io' show Platform;

abstract final class AdConfig {
  // Google 公式テスト用バナー広告ユニットID（プラットフォーム別）。
  // TODO(本番収益化): AdMob で作成した実ユニットIDに差し替える。
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/6300978111';
  static const _testBannerIos = 'ca-app-pub-3940256099942544/2934735716';

  /// 現在プラットフォームのバナー広告ユニットID。
  static String get bannerUnitId =>
      Platform.isIOS ? _testBannerIos : _testBannerAndroid;
}

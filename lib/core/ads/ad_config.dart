/// AdMob の広告ユニットID（無料プランのバナー広告 / core/ads）。
///
/// 安全装置（自分の広告を誤タップ＝規約違反の防止）:
///   * 既定は **Google 公式テスト広告ユニットID**（AdMob アカウント不要・常にテスト広告・
///     自分でタップしても安全）。**開発・プレビュー・内部テストは常にこれ**。
///   * **本番公開ビルドだけ** `--dart-define=ADMOB_USE_PROD_ADS=true` で実広告ユニットに
///     切り替える（`build-aab.yml` の workflow 入力 `prod_ads=true` で注入 / 公開直前のみ）。
///   * AdMob アプリID（AndroidManifest.xml の APPLICATION_ID）は実値だが、既定のテスト
///     ユニットと組み合わせる限り出るのはテスト広告のみ（アプリID単体では配信されない）ため、
///     内部テストでも安全。実広告の実配信は「本番フラグ＋AdMob 審査承認後（一般公開後）」。
///
/// **Android/iOS とも無料プランは広告あり**（オーナー裁定 2026-07-16）。iOS は非パーソナライズ
/// 広告のみ（ATT なし・IDFA トラッキングなし）。iOS の実バナーユニットは [_prodBannerIos]
/// （⚠️要オーナー作成：AdMob で iOS アプリ＋バナーユニットを作成し実IDへ差し替え）。
///
/// 注意: 本ファイルは **モバイル(io)実装からのみ import される**（Web は import しない）。
library;

import 'dart:io' show Platform;

abstract final class AdConfig {
  // Google 公式テスト用バナー広告ユニットID（開発/プレビュー/内部テスト用・自クリック安全）。
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/6300978111';
  static const _testBannerIos = 'ca-app-pub-3940256099942544/2934735716';

  // 本番 AdMob のバナー広告ユニットID（Android・公開値 / 合同会社Lan の AdMob アプリ）。
  static const _prodBannerAndroid = 'ca-app-pub-5063966757462588/1615380283';

  // 本番 AdMob のバナー広告ユニットID（iOS・公開値 / 合同会社Lan の AdMob iOS アプリ）。
  //   実広告の実配信は AdMob 審査承認後（公開後）。それまでは useProdAds=true でも配信されない
  //   （＝Apple審査中はバナー非表示で問題なし・Android と同じ運用）。
  static const _prodBannerIos = 'ca-app-pub-5063966757462588/2390554686';

  /// 本番公開ビルドだけ true にして実広告を出す（`--dart-define=ADMOB_USE_PROD_ADS=true`）。
  /// 未指定（開発・プレビュー・内部テスト）は false＝テスト広告のまま（自クリック規約違反の防止）。
  static const bool useProdAds =
      bool.fromEnvironment('ADMOB_USE_PROD_ADS', defaultValue: false);

  /// 現在プラットフォームのバナー広告ユニットID。
  static String get bannerUnitId {
    if (Platform.isIOS) return useProdAds ? _prodBannerIos : _testBannerIos;
    return useProdAds ? _prodBannerAndroid : _testBannerAndroid;
  }
}

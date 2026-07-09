import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/ads/ad_config.dart';

/// AdMob 広告ユニットIDの安全既定テスト。
///
/// 鉄則（自分の広告を誤タップ＝規約違反の防止）: `ADMOB_USE_PROD_ADS` を注入しない限り、
/// 実広告ユニットを使わず **Google 公式テスト広告ユニット**（publisher=3940256099942544）を
/// 返す。これで「うっかり実広告を既定で出荷／開発中にクリック」を防ぐ（実広告は本番公開
/// ビルドの `--dart-define=ADMOB_USE_PROD_ADS=true` のときだけ）。
void main() {
  test('本番フラグ未指定（既定）はテスト広告ユニットを返す', () {
    expect(AdConfig.useProdAds, isFalse); // テスト実行では未注入＝false
    // Google 公式テスト publisher ID（テスト広告ユニット）であることを担保。
    expect(AdConfig.bannerUnitId, contains('ca-app-pub-3940256099942544'));
    // 本番 publisher（実広告）が既定で漏れ出ていないこと。
    expect(AdConfig.bannerUnitId, isNot(contains('5063966757462588')));
  });
}

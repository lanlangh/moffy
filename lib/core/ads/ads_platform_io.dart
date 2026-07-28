/// 広告のプラットフォーム実装（**モバイル(Android/iOS)向け・AdMob**）。
///
/// `ads.dart` の条件付き export で `dart.library.io` が true のとき使われる。
/// Android/iOS 以外（デスクトップ・CIのDart VM 等）では実際には広告を出さず
/// no-op に倒す（`_adsSupported` ガード）＝安全に素通りする。
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../observability/log.dart';
import 'ad_config.dart';

/// 無料プランで**実際に広告が表示される**プラットフォームか（UIの「広告オフ」訴求の出し分け用）。
/// **Android/iOS とも無料プランは AdMob バナー広告を表示**（オーナー裁定 2026-07-16・iOSも広告あり）。
/// iOS は **ATT を求めず非パーソナライズ広告のみ**（IDFA をトラッキング目的で使わない）＝審査の
/// トラッキング申告を避けつつ広告収益を得る。パーソナライズ（ATT）は将来 v1.1 で検討。
/// Web/デスクトップは `ads_platform_stub.dart` 側が false を返す（AdMob 非対応）。
bool get freeTierAdsActive => Platform.isAndroid || Platform.isIOS;

/// 広告を初期化/表示するプラットフォームか（内部ガード）。実際に広告を出す可否と同一のため
/// [freeTierAdsActive] を単一情報源として参照する（同じ条件を二重定義しない）。
bool get _adsSupported => freeTierAdsActive;

/// AdMob SDK を初期化（モバイルのみ）。失敗してもアプリは止めない（広告が出ないだけ）。
Future<void> initAds() async {
  if (!_adsSupported) return;
  try {
    await MobileAds.instance.initialize();
  } catch (e, st) {
    // 初期化失敗でもアプリは止めない（広告が出ないだけ）。
    // ⚠️ ここは Log.e にしても本番に残らない。main() は `unawaited(initAds())` を
    // 先頭で呼ぶのに対し、`Log.crashReporterSink`(Sentry転送) の登録は main 後半
    // なので、初期化が早期に失敗すると sink が未設定で握りつぶされる。
    // 実務上は「AdMob管理画面の広告リクエストが0のまま」で検知できるため、
    // ここは開発時のログに留める。
    Log.d('AdMob init failed: $e\n$st');
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
  /// 読み込み失敗時のリトライ間隔（指数バックオフ・この回数で打ち切り）。
  ///
  /// [AdBannerView] はアプリのシェル（bottom_nav_scaffold）に常駐するため、リトライが
  /// ないと「起動直後の1回目が失敗したら、そのセッション中ずっと広告が出ない」状態になる
  /// （AdMob の配信制限が解除された直後などに「承認されたのに出ない」と誤診する原因）。
  /// 一方で無限リトライは AdMob へのリクエスト濫発（規約・パフォーマンス両面で悪い）に
  /// なるため上限を設ける。ここで諦めても次回起動でまた試すので実害は小さい。
  static const _retryDelays = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];

  BannerAd? _ad;
  bool _loaded = false;
  Timer? _retryTimer;
  int _retryCount = 0;

  @override
  void initState() {
    super.initState();
    if (_adsSupported) _load();
  }

  void _load() {
    final ad = BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: AdSize.banner,
      // iOS は ATT を求めないため非パーソナライズ広告を明示（IDFA をトラッキング目的で使わない）。
      // Android は従来どおり（同意のある範囲でパーソナライズ）。
      request: AdRequest(nonPersonalizedAds: Platform.isIOS ? true : null),
      listener: BannerAdListener(
        onAdLoaded: (_) {
          _retryCount = 0; // 成功したらバックオフを初期状態に戻す。
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          _ad = null; // 破棄済み参照を残さない（dispose() 側の二重 dispose を避ける）。
          _scheduleRetry(error);
        },
      ),
    )..load();
    _ad = ad;
  }

  /// 読み込み失敗をバックオフで再試行する。上限に達したら諦め、そのときだけ本番にも残す。
  void _scheduleRetry(LoadAdError error) {
    // 破棄済みの State では何もしない（タイマーも張らない）。プレミアム購入で
    // [AdBanner] がこのウィジェットをツリーから外した直後の失敗もここで止まる。
    if (!mounted) return;

    if (_retryCount >= _retryDelays.length) {
      // ⚠️ ここを Log.e にしてはいけない。広告の読み込み失敗は「在庫なし(no fill)」を
      // 含む**正常系**で、AdMob が配信制限中なら無料ユーザーの全セッションで発火する。
      // Log.e は本番で Sentry へ送られるため、正常系のイベントで無料枠(月5千件)を
      // 使い切り、**本物のクラッシュが監視から落ちる**。
      // 広告が出ない原因の調査は Sentry ではなく **AdMob管理画面のリクエスト数/
      // 表示回数/一致率** で行う（そちらが一次情報）。
      Log.d('AdMob banner load failed (code=${error.code}): ${error.message}'
          ' / gave up after $_retryCount retries');
      return;
    }

    final delay = _retryDelays[_retryCount];
    _retryCount++;
    // 途中の失敗は開発時のみ（本番のノイズにしない）。
    Log.d(
      'AdMob banner load failed (code=${error.code}): ${error.message}'
      ' / retry $_retryCount in ${delay.inSeconds}s',
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (!mounted) return; // dispose 済みの State で発火させない。
      _load();
    });
  }

  @override
  void dispose() {
    // 破棄後にリトライが発火しないよう必ず止める（プレミアム購入でこのウィジェットが
    // 外れたときもここを通る＝広告非表示ユーザーに無駄なリクエストを出さない）。
    _retryTimer?.cancel();
    _retryTimer = null;
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

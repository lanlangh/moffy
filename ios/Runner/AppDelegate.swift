import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// チャネル/ハンドラを生存させるための強参照（解放されるとハンドラが外れる）。
  private var usageChannel: FlutterMethodChannel?
  private var screenTimeHandler: AnyObject?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // ⚠️ iOS 26 / Xcode 26 クラッシュ回避（RevenueCat 公式 known-issue・Apple 側バグ）。
    //   Xcode 26 でビルドしたアプリが iOS 26 実機で、URLSessionConfiguration を使う SDK
    //   （RevenueCat 等）の最初のネットワーク呼び出し時に EXC_BREAKPOINT で即クラッシュする。
    //   Network フレームワークの TLS を起動最初期に「温める」ことで回避できる。RevenueCat の
    //   Purchases.configure / getCustomerInfo（＝Dart から Flutter 起動後に呼ばれる）より前の
    //   この地点で必ず実行する。Apple の恒久修正が入るまでの回避策。
    //   参考: revenuecat.com/docs/known-store-issues/xcode-26/app-crash-urlsessionconfiguration
    _ = nw_tls_create_options()
    // UIScene 環境では plugin / channel 登録は didInitializeImplicitFlutterEngine で行う。
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // 利用統計（iOS=スクリーンタイム）チャネルを実装エンジンの messenger に配線する。
    // チャネル名は Dart 側 AppConstants.usageChannel と厳密一致させること。
    // messenger() は非 Optional（any FlutterBinaryMessenger）を返す。
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(
      name: "com.moffy/usage_stats",
      binaryMessenger: messenger
    )

    if #available(iOS 16.0, *) {
      let handler = ScreenTimeHandler()
      screenTimeHandler = handler
      channel.setMethodCallHandler { call, result in
        handler.handle(call, result)
      }
      // 認証済み＋選択済みなら起動時に監視を再開（拡張のスケジュール維持・冪等）。
      handler.restartMonitoringIfPossible()
    } else {
      // iOS 16 未満（deployment target=16.0 のため通常到達しない）。
      channel.setMethodCallHandler { _, result in result(FlutterMethodNotImplemented) }
    }
    usageChannel = channel
  }
}

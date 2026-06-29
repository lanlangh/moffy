import Flutter
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

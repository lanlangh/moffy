import DeviceActivity
import FamilyControls
import Flutter
import ManagedSettings
import SwiftUI
import UIKit

/// iOS スクリーンタイム（FamilyControls / DeviceActivity）の MethodChannel ハンドラ。
///
/// チャネル名・メソッド名・引数キー・戻り値形状は Dart `IOSUsageProvider` と厳密一致させる
/// （チャネル名 = AppConstants.usageChannel = "com.moffy/usage_stats"）。
///
/// 役割:
///   * checkPermission / requestPermission … FamilyControls authorization。
///   * presentAppPicker / hasSelection … 対象アプリ選択（FamilyActivityPicker）。
///   * startMonitoring … DeviceActivity の日次スケジュール＋しきい値イベント登録。
///   * queryDailyUsage / queryRangeUsage … 拡張が App Group に記録した到達しきい値の読み出し。
///
/// 注意: Moffy は **アプリをブロック（シールド）しない**。利用しきい値を観測して報酬に換える
/// だけなので ManagedSettingsStore は使わない（ManagedSettings は ApplicationToken 等の型解決の
/// ためだけに import する）。
@available(iOS 16.0, *)
final class ScreenTimeHandler: NSObject {

  /// 選択（FamilyActivitySelection）の保存キー（App Group 共有 UserDefaults）。
  private static let selectionKey = "moffy.familyActivitySelection"

  /// ピッカー結果を返すための保留 result（多重提示防止にも使う）。
  private var pendingPickerResult: FlutterResult?

  // MARK: - MethodChannel ディスパッチ

  func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "checkPermission":
      result(statusString(AuthorizationCenter.shared.authorizationStatus))
    case "requestPermission":
      requestPermission(result)
    case "hasSelection":
      result(hasSelection())
    case "presentAppPicker":
      presentAppPicker(result)
    case "startMonitoring":
      startMonitoring(with: loadSelection())
      result(nil)
    case "queryDailyUsage":
      queryDailyUsage(call, result)
    case "queryRangeUsage":
      queryRangeUsage(call, result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 起動時に「認証済み＋選択済み」なら監視を再開する（拡張のスケジュール維持・冪等）。
  func restartMonitoringIfPossible() {
    let status = AuthorizationCenter.shared.authorizationStatus
    guard status == .approved else { return }
    guard hasSelection() else { return }
    startMonitoring(with: loadSelection())
  }

  // MARK: - 認証

  /// AuthorizationStatus → Dart 契約文字列。
  /// `.denied` は OS 設定での解除が必要なため permanently_denied に倒す。
  private func statusString(_ s: AuthorizationStatus) -> String {
    // AuthorizationStatus はこの SDK では notDetermined / denied / approved の3ケース。
    // 将来ケース（例: approvedWithDataAccess）は @unknown default が安全側(denied)で吸収。
    switch s {
    case .approved:
      return "granted"
    case .denied:
      return "permanently_denied" // 一度拒否すると再要求シートは出ない → OS設定誘導
    case .notDetermined:
      return "denied" // 未要求 → 再要求可
    @unknown default:
      return "denied"
    }
  }

  private func requestPermission(_ result: @escaping FlutterResult) {
    Task {
      do {
        try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
      } catch {
        NSLog("Moffy: requestAuthorization failed: \(error.localizedDescription)")
      }
      let s = AuthorizationCenter.shared.authorizationStatus
      await MainActor.run { result(self.statusString(s)) }
    }
  }

  // MARK: - 対象アプリ選択（FamilyActivityPicker）

  private func hasSelection() -> Bool {
    let s = loadSelection()
    return !(s.applicationTokens.isEmpty
      && s.categoryTokens.isEmpty
      && s.webDomainTokens.isEmpty)
  }

  private func loadSelection() -> FamilyActivitySelection {
    guard let data = ScreenTimeShared.defaults?.data(forKey: Self.selectionKey) else {
      return FamilyActivitySelection()
    }
    return (try? JSONDecoder().decode(FamilyActivitySelection.self, from: data))
      ?? FamilyActivitySelection()
  }

  private func saveSelection(_ selection: FamilyActivitySelection) {
    guard let data = try? JSONEncoder().encode(selection) else { return }
    ScreenTimeShared.defaults?.set(data, forKey: Self.selectionKey)
  }

  private func selectionCount(_ s: FamilyActivitySelection) -> Int {
    s.applicationTokens.count + s.categoryTokens.count + s.webDomainTokens.count
  }

  private func presentAppPicker(_ result: @escaping FlutterResult) {
    // 未認証だとピッカーが空になる。Dart オンボは requestPermission を先に呼ぶ契約だが、
    // 念のため未認証は selected:false で即返す。
    let status = AuthorizationCenter.shared.authorizationStatus
    guard status == .approved else {
      result(["selected": false, "count": 0])
      return
    }
    // 二重提示防止。
    if pendingPickerResult != nil {
      result(["selected": hasSelection(), "count": selectionCount(loadSelection())])
      return
    }
    guard let presenter = Self.currentFlutterViewController() else {
      result(FlutterError(
        code: "platform_error",
        message: "FlutterViewController unavailable",
        details: nil))
      return
    }

    pendingPickerResult = result
    let initial = loadSelection()
    let view = ScreenTimePickerView(
      initialSelection: initial,
      onDone: { [weak self, weak presenter] updated in
        guard let self else { return }
        self.saveSelection(updated)
        self.startMonitoring(with: updated)
        presenter?.dismiss(animated: true) {
          self.finishPicker(selected: self.selectionCount(updated) > 0,
                            count: self.selectionCount(updated))
        }
      },
      onCancel: { [weak self, weak presenter] in
        guard let self else { return }
        presenter?.dismiss(animated: true) {
          let cur = self.loadSelection()
          self.finishPicker(selected: self.selectionCount(cur) > 0,
                            count: self.selectionCount(cur))
        }
      }
    )
    let host = UIHostingController(rootView: view)
    host.modalPresentationStyle = .formSheet
    host.isModalInPresentation = true // スワイプ閉じを禁止 → 必ず Done/Cancel で result を返す
    presenter.present(host, animated: true)
  }

  private func finishPicker(selected: Bool, count: Int) {
    guard let result = pendingPickerResult else { return }
    pendingPickerResult = nil
    result(["selected": selected, "count": count])
  }

  // MARK: - DeviceActivity 監視

  private func startMonitoring(with selection: FamilyActivitySelection) {
    let center = DeviceActivityCenter()
    // 選択が空なら監視しても意味がない（＋空 selection で startMonitoring が throw し得る）。
    guard selectionCount(selection) > 0 else {
      center.stopMonitoring([ScreenTimeShared.activityName])
      return
    }

    // 終日・毎日繰り返し（23:59:59 まで取り、深夜の1分デッドゾーンを無くす）。
    let schedule = DeviceActivitySchedule(
      intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
      intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
      repeats: true
    )

    var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
    for minutes in ScreenTimeShared.thresholdMinutes {
      events[ScreenTimeShared.eventName(forMinutes: minutes)] = DeviceActivityEvent(
        applications: selection.applicationTokens,
        categories: selection.categoryTokens,
        webDomains: selection.webDomainTokens,
        threshold: DateComponents(minute: minutes)
      )
    }

    center.stopMonitoring([ScreenTimeShared.activityName]) // クリーン再開
    do {
      try center.startMonitoring(
        ScreenTimeShared.activityName,
        during: schedule,
        events: events)
    } catch {
      NSLog("Moffy: startMonitoring failed: \(error.localizedDescription)")
    }
  }

  // MARK: - 利用クエリ（拡張が記録した到達しきい値の読み出し）

  private func queryDailyUsage(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let dateMs = (args["dateMs"] as? NSNumber)?.doubleValue
    else {
      result(FlutterError(code: "platform_error", message: "dateMs missing", details: nil))
      return
    }
    let date = Date(timeIntervalSince1970: dateMs / 1000.0)
    result(["minutes": ScreenTimeShared.reachedMinutes(for: date)])
  }

  private func queryRangeUsage(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let startMs = (args["startMs"] as? NSNumber)?.doubleValue,
      let endMs = (args["endMs"] as? NSNumber)?.doubleValue
    else {
      result(FlutterError(code: "platform_error", message: "range missing", details: nil))
      return
    }
    let cal = Calendar.current
    var day = cal.startOfDay(for: Date(timeIntervalSince1970: startMs / 1000.0))
    let end = cal.startOfDay(for: Date(timeIntervalSince1970: endMs / 1000.0))

    var out: [[String: Any]] = []
    var guardCount = 0
    while day <= end && guardCount < 400 {
      let minutes = ScreenTimeShared.reachedMinutes(for: day)
      // 記録のある日のみ返す（欠損日は除外 / S11）。Dart 側でも minutes<=0 を除外する。
      if minutes > 0 {
        out.append([
          "dateMs": Int(day.timeIntervalSince1970 * 1000),
          "minutes": minutes,
        ])
      }
      guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
      guardCount += 1
    }
    result(out)
  }

  // MARK: - FlutterViewController 取得（UIScene 対応・実行時に取得）

  /// 現在の FlutterViewController を Scene 経由で堅牢に取得する。
  /// 起動時にキャッシュせず、呼び出しのたびに取得する（Scene 再接続で差し替わるため）。
  static func currentFlutterViewController() -> FlutterViewController? {
    // クラスは @available(iOS 16) なので keyWindow(iOS15+) を直接使える。
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    let keyWindow = scene?.keyWindow ?? scene?.windows.first(where: { $0.isKeyWindow })

    var root = keyWindow?.rootViewController
    while let presented = root?.presentedViewController { root = presented }
    if let fvc = root as? FlutterViewController { return fvc }
    return keyWindow?.rootViewController as? FlutterViewController
  }
}

// MARK: - SwiftUI ピッカーラッパ

/// FamilyActivityPicker（SwiftUI）を Done/Cancel 付きで包む。
@available(iOS 16.0, *)
private struct ScreenTimePickerView: View {
  @State private var selection: FamilyActivitySelection
  let onDone: (FamilyActivitySelection) -> Void
  let onCancel: () -> Void

  init(
    initialSelection: FamilyActivitySelection,
    onDone: @escaping (FamilyActivitySelection) -> Void,
    onCancel: @escaping () -> Void
  ) {
    _selection = State(initialValue: initialSelection)
    self.onDone = onDone
    self.onCancel = onCancel
  }

  var body: some View {
    NavigationStack {
      FamilyActivityPicker(
        headerText: "Moffyで見守るアプリを選ぶ",
        footerText: "選んだアプリの利用時間だけを見ます。アプリの中身や閲覧内容は一切見ません。",
        selection: $selection
      )
      .navigationTitle("対象アプリ")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("キャンセル") { onCancel() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("完了") { onDone(selection) }
        }
      }
    }
  }
}

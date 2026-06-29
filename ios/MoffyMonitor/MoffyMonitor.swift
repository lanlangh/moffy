import DeviceActivity
import Foundation

/// DeviceActivityMonitor 拡張の principal class（Info.plist の NSExtensionPrincipalClass =
/// `$(PRODUCT_MODULE_NAME).MoffyMonitor`）。
///
/// しきい値到達コールバックで「今日到達した最大しきい値（分）」を App Group の共有
/// UserDefaults に記録する。アプリ側 ScreenTimeHandler がそれを近似利用分として読む。
///
/// 制約: 拡張は実行メモリ ~6MB・実行時間が厳しい。処理は UserDefaults 書き込みのみに保つ
/// （重い処理は jetsam されコールバックが失われる）。共有ロジックは ScreenTimeShared.swift
/// （両ターゲットにコンパイル）に集約。
class MoffyMonitor: DeviceActivityMonitor {
  override func intervalDidStart(for activity: DeviceActivityName) {
    super.intervalDidStart(for: activity)
    // 本当の日替わり/初回だけ今日の記録を 0 に。アプリ起動/再選択での監視再開でも
    // intervalDidStart は再発火し得るため、無条件リセットだと今日の到達分を消してしまう。
    ScreenTimeShared.resetDayIfRolledOver()
  }

  override func intervalDidEnd(for activity: DeviceActivityName) {
    super.intervalDidEnd(for: activity)
  }

  override func eventDidReachThreshold(
    _ event: DeviceActivityEvent.Name,
    activity: DeviceActivityName
  ) {
    super.eventDidReachThreshold(event, activity: activity)
    let minutes = ScreenTimeShared.minutes(fromEventName: event)
    if minutes > 0 {
      ScreenTimeShared.recordReached(minutes: minutes)
    }
  }
}

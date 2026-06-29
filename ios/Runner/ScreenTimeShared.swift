import DeviceActivity
import Foundation

/// アプリ（Runner）と監視拡張（MoffyMonitor）で共有する定数・ヘルパ。
///
/// このファイルは **両ターゲットにコンパイル**される（configure_screentime.rb が
/// Runner と MoffyMonitor の両方の Sources に追加する）。拡張は実行メモリ ~6MB・
/// 実行時間が厳しいので、依存は Foundation + DeviceActivity のみに保つ（FamilyControls /
/// ManagedSettings / SwiftUI はアプリ側 ScreenTimeHandler.swift のみが import する）。
///
/// iOS の根本仕様（Android の移植ではない）:
///   * 利用「分数」は取得不可。`DeviceActivity` の **しきい値到達のみ**を観測できる。
///   * 監視拡張がしきい値到達ごとに「今日到達した最大しきい値（分）」を App Group の
///     共有 UserDefaults に記録し、アプリ側がそれを **近似利用分** として読む。
enum ScreenTimeShared {
  /// App Group（アプリ↔拡張の共有 UserDefaults）。両 .entitlements の値と一致必須。
  static let appGroupID = "group.com.moffy.app"

  /// 監視アクティビティ名。1スケジュール=1アクティビティ（同時20上限に対し安全）。
  static let activityName = DeviceActivityName("moffy.daily")

  /// しきい値（分）の階段。15分起点で細かく刻む（意思決定ログ 2026-06-19: iOSは15/30分起点）。
  /// 各値が1つの DeviceActivityEvent になるが、同一スケジュール内なので 1 アクティビティ。
  static let thresholdMinutes = [15, 30, 45, 60, 90, 120, 150, 180, 240, 300]

  /// 共有 UserDefaults。App Group 未設定/不一致だと nil（書き込みは無音 no-op）。
  static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupID) }

  /// イベント名 "threshold.<minutes>"。
  static func eventName(forMinutes minutes: Int) -> DeviceActivityEvent.Name {
    DeviceActivityEvent.Name("threshold.\(minutes)")
  }

  /// イベント名 → 分。解析不能は 0。
  static func minutes(fromEventName name: DeviceActivityEvent.Name) -> Int {
    Int(name.rawValue.replacingOccurrences(of: "threshold.", with: "")) ?? 0
  }

  // MARK: - 到達しきい値（分）の日別記録

  /// 端末ローカル暦の yyyy-MM-dd（S11: ユーザーTZの暦日）。
  private static func dayString(for date: Date) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  private static func dayKey(for date: Date) -> String {
    "moffy.maxThreshold.\(dayString(for: date))"
  }

  /// 最後にリセットした暦日（yyyy-MM-dd）を覚えるキー。日替わり判定に使う。
  private static let lastResetKey = "moffy.lastResetDay"

  /// その日に到達した最大しきい値（分）。記録なしは 0。
  static func reachedMinutes(for date: Date) -> Int {
    defaults?.integer(forKey: dayKey(for: date)) ?? 0
  }

  /// 到達しきい値（分）を「最大値で」記録する（拡張のしきい値到達コールバックから呼ぶ）。
  static func recordReached(minutes: Int, on date: Date = Date()) {
    guard let d = defaults else { return }
    let key = dayKey(for: date)
    if minutes > d.integer(forKey: key) {
      d.set(minutes, forKey: key)
    }
  }

  /// **実際に暦日が変わった時だけ**今日の記録を 0 にする。
  ///
  /// `intervalDidStart` は日替わりだけでなく、アプリ起動/再選択での監視再開（stop→start）でも
  /// 「現在アクティブなインターバル」に対して再発火し得る。無条件に 0 リセットすると、その日
  /// すでに貯めた到達分が消えて今日のポイントが失われる（レビュー HIGH 指摘）。そこで
  /// 「最後にリセットした暦日」と今日を比較し、違う時（＝本当の日替わり/初回）だけリセットする。
  static func resetDayIfRolledOver(_ date: Date = Date()) {
    guard let d = defaults else { return }
    let today = dayString(for: date)
    if d.string(forKey: lastResetKey) != today {
      d.set(0, forKey: dayKey(for: date))
      d.set(today, forKey: lastResetKey)
    }
  }
}

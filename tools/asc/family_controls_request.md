# Family Controls（配信用）エンタイトルメント 申請メモ

> 起因: iOS 1.0 リジェクト Guideline 2.5.1（Screen Time API を使うのに Family Controls
> 配信用エンタイトルメントで提出されていない）/ 2026-07-24
> 申請フォーム: https://developer.apple.com/contact/request/family-controls-distribution
> Apple公式ドキュメント: https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement

## 対象バンドルID（両方申請する / フォームは bundle ID ごと）
- 本体アプリ: `com.moffy.app`
- Screen Time 拡張(DeviceActivityMonitor): `com.moffy.app.MoffyMonitor`
  ※ Device Activity Monitor 等の Screen Time 拡張は本体と別に申請が要る場合がある。
    フォームの案内に従い、拡張分も含めて申請すること。

## 承認までの目安
- 数営業日〜数週間（2026年時点で遅延報告あり）。正当なデジタルウェルビーイング/
  ペアレンタルコントロール用途であれば通る。承認後にビルドし直して再提出。

## フォームに貼る用途説明（英語・そのまま貼付可）

Moffy is a digital wellbeing app that helps users voluntarily reduce their own
screen time and social media usage. It is already published on Google Play
(com.moffy.app) as a digital wellbeing app.

How we use the Screen Time APIs:
- FamilyControls (FamilyActivityPicker): The user selects which of their own apps
  (for example, social media apps) they want to cut down on. Selection is entirely
  user-driven and self-directed. There is no parental/guardian managing another person.
- DeviceActivity (DeviceActivityMonitor extension, bundle id
  com.moffy.app.MoffyMonitor): We set daily time thresholds on the user-selected apps
  and detect when a threshold is reached. Only the reached threshold value is stored in
  an App Group on-device.
- We do NOT use ManagedSettings to shield, block, or restrict any apps. Moffy never
  locks or limits the device; it only measures the user's own reduction.

Purpose and user benefit:
Moffy converts the reduction in the user's own screen time into points that grow a
virtual pet and fill a collection, providing positive reinforcement for healthier
device habits. It is a self-improvement / digital wellbeing tool.

Privacy:
Selected apps are opaque tokens; we cannot identify which apps the user chose. Only
daily aggregate threshold data is used, on-device, to calculate points. No app names
or per-app data are sent to any server.

## 承認後の手順（開発側 = 私）
1. Apple から承認メールが来たら、App ID(com.moffy.app / .MoffyMonitor)に配信用
   Family Controls capability が有効化される。
2. `ios-build.yml` を `mode=testflight` `prod_ads=true` で再ビルド(build 24)。
   自動署名なので、承認済みなら配信用エンタイトルメントが署名に含まれる。
3. TestFlight 処理完了 → 新ビルドを 1.0 に紐付け → UI で「審査へ提出」(サブスク同梱)。

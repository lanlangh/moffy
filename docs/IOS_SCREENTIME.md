# iOS スクリーンタイム実装（DeviceActivity / FamilyControls）

Moffy の iOS 版コア機能。**Android の移植ではない**（OS の制約が根本的に違う）。本書は
実装の全体像・データフロー・ファイル構成・ビルド手順・**Apple ポータルでの必須準備**を記す。

> 方針: ORG_STATE 2026-06-26「iOS フル実装で出す」。FamilyControls 配布 Entitlement は
> `com.moffy.app` で承認済み。**ただし拡張の App ID（`com.moffy.app.MoffyMonitor`）には
> 別途申請が必要**（下記「Apple ポータル準備」参照）。

---

## 1. なぜ Android と違うのか（仕様差）

| | Android | iOS |
|---|---|---|
| 取得できるデータ | 利用「分数」（`UsageStatsManager`・正確値） | しきい値**到達のみ**（`DeviceActivity`・分数取得不可） |
| 対象アプリ指定 | アプリが4SNSを自動指定（パッケージ名） | **ユーザーがOSの `FamilyActivityPicker` で自分で選ぶ**（不透明トークン・Moffyから識別不可） |
| 計算モード | `exact-minutes` | `threshold-achievement`（近似分） |
| 権限 | `PACKAGE_USAGE_STATS`（設定画面誘導） | FamilyControls authorization（OSシート） |

このため iOS は **オンボーディングに分岐**が必要（対象アプリ選択 = Apple のピッカーを開く）。

**Moffy はアプリをブロック（シールド）しない。** 利用しきい値を観測して報酬（ポイント）に
換えるだけ。よって `ManagedSettings` のシールドや `ShieldConfiguration` 拡張は**使わない**
（2つ目の拡張＝2つ目の Entitlement 申請を回避）。

---

## 2. しくみ（データフロー）

```
[オンボーディング]
  requestPermission() ──► FamilyControls 認証シート
  presentAppPicker()  ──► FamilyActivityPicker（ユーザーが対象SNSを選択）
                          → 選択を App Group に保存 → DeviceActivity 監視開始

[日々（OSがバックグラウンドで）]
  ユーザーが対象アプリを使う
   └─ 累積利用が各しきい値（15/30/45/60/90/120/150/180/240/300分）に達するたび
      → MoffyMonitor 拡張の eventDidReachThreshold が発火
      → 「今日の最大到達しきい値（分）」を App Group の共有 UserDefaults に記録

[ホーム表示]
  IOSUsageProvider.fetchDailyUsage(today)  → App Group から今日の到達分を読む
  IOSUsageProvider.fetchUsageRange(過去N日) → 記録のある日の到達分を読む（baseline用）
   └─ ThresholdAchievementPointCalculator が「baseline - 近似利用分」で暫定pt算出
   └─ 確定はサーバー fn_finalize_day（既存・Android と共通）
```

到達しきい値（分）を**近似利用分**として既存の経済計算に流す（ORG_STATE 2026-06-26）。
階段は15分起点で細かく刻む（意思決定ログ 2026-06-19）。量子化誤差は MVP 許容。

---

## 3. ファイル構成

| ファイル | 役割 | コンパイル先 |
|---|---|---|
| `lib/core/usage/ios_usage_provider.dart` | Dart 実装（MethodChannel）。`UsageProvider`＋`ScreenTimeAppSelection` | Flutter |
| `lib/core/usage/usage_provider.dart` | `ScreenTimeAppSelection` capability 定義 | Flutter |
| `lib/core/usage/usage_providers.dart` | `Platform.isIOS` で `IOSUsageProvider` を返す配線 | Flutter |
| `lib/features/onboarding/.../onboarding_screen.dart` | iOS 分岐（権限文言＋アプリ選択ページ） | Flutter |
| `ios/Runner/ScreenTimeShared.swift` | 共有定数/ヘルパ（App Group・しきい値・日別記録） | **Runner＋MoffyMonitor 両方** |
| `ios/Runner/ScreenTimeHandler.swift` | アプリ側 MethodChannel ハンドラ（認証/ピッカー/監視/クエリ） | Runner |
| `ios/Runner/AppDelegate.swift` | チャネル配線（`applicationRegistrar.messenger()`） | Runner |
| `ios/Runner/Runner.entitlements` | family-controls ＋ App Group | Runner |
| `ios/MoffyMonitor/MoffyMonitor.swift` | `DeviceActivityMonitor` サブクラス（しきい値到達を記録） | MoffyMonitor |
| `ios/MoffyMonitor/Info.plist` | 拡張 Info.plist（`NSExtensionPointIdentifier=com.apple.deviceactivity.monitor-extension`） | MoffyMonitor |
| `ios/MoffyMonitor/MoffyMonitor.entitlements` | family-controls ＋ App Group | MoffyMonitor |
| `ios/tools/configure_screentime.rb` | 拡張ターゲットを pbxproj に配線（純Ruby・Linux可・冪等） | — |
| `.github/workflows/configure-ios.yml` | 上記スクリプトの無料検証（Linux） | — |
| `.github/workflows/ios-build.yml` | macOS コンパイル検証（⚠️課金・手動） | — |

MethodChannel 名 = `com.moffy/usage_stats`（`AppConstants.usageChannel`／Android と同名・実装で分岐）。

### チャネル契約（Dart ↔ Swift 厳密一致）

| メソッド | 引数 | 戻り値 |
|---|---|---|
| `checkPermission` | — | `String`: granted / denied / permanently_denied / not_applicable |
| `requestPermission` | — | `String`（同上・要求後の状態） |
| `hasSelection` | — | `bool` |
| `presentAppPicker` | — | `{selected: bool, count: int}` |
| `startMonitoring` | — | `null` |
| `queryDailyUsage` | `{dateMs: int}` | `{minutes: int}`（到達しきい値・0可） |
| `queryRangeUsage` | `{startMs: int, endMs: int}` | `[{dateMs:int, minutes:int}]`（記録日のみ） |

---

## 4. ⚠️ Apple ポータル準備（ビルド前の必須・ユーザー作業）

コードだけでは TestFlight/審査に出せない。以下は Apple Developer ポータルでの手作業：

1. **App ID を2つ用意**: `com.moffy.app`（アプリ）と `com.moffy.app.MoffyMonitor`（拡張）。
2. **App Group `group.com.moffy.app` を登録**し、上記2 App ID の両方に付与。
   - 未登録だと `UserDefaults(suiteName:)` が共有されず、アプリ↔拡張のデータが繋がらない。
3. **Family Controls（配布）を拡張の App ID にも申請・承認**:
   - アプリ側（`com.moffy.app`）は承認済み（ORG_STATE）。
   - **拡張（`com.moffy.app.MoffyMonitor`）は別 App ID なので別途申請が必要**。承認は手動審査で
     **数週間**かかることがある → 早めに申請。未承認だと配布プロファイルに entitlement が乗らず
     アップロード/起動に失敗する（開発ビルドは通るのに配布で落ちる典型）。
4. **両 App ID のプロビジョニングプロファイル**を発行（family-controls + app-group を含む）。

これらが揃うまでは `ios-build.yml`（mode=compile / `--no-codesign`）で Swift の健全性のみ確認する。

---

## 5. ビルド・検証フロー（Mac 無し前提）

| 段階 | 手段 | 課金 |
|---|---|---|
| Dart 検証 | `dart analyze`（ローカル可）/ CI の `flutter test` | 無料 |
| pbxproj 配線検証 | `gh workflow run "Configure iOS (Screen Time)"`（Linux） | 無料 |
| **iOS 実コンパイル** | `gh workflow run "iOS Build (macOS)"`（mode=compile） | **macOS=約10倍** |
| 署名/IPA/TestFlight | 上記ポータル準備後（fastlane + ASC API キー流用可） | macOS |

`configure_screentime.rb` は**コミット済み pbxproj を書き換えない運用**: ビルド時に CI で実行して
拡張ターゲットを配線する（冪等）。`ios-build.yml` がビルド前に自動実行する。

---

## 6. 既知の近似・制約（MVP 許容）

- **量子化**: 利用分は階段しきい値で近似（最大到達段）。実利用との誤差は高利用域で最大~数十分。
- **baseline は「最小しきい値(15分)以上に達した日」のみ**から算出（`queryRangeUsage` が minutes>0
  のみ返す）。Android も「対象4SNSの利用 0 分の日」は baseline から除外するため**方針は整合**。
  違いは iOS の「意味ある利用」の下限が 15 分（OS が分数を出せないため）になる点だけ。
  影響: 15分未満の軽利用日は baseline 母数（sampleDays）から外れ、baseline 平均がやや高め＝
  ポイントは**やや甘め**（30分フロアクランプ S2 で下限も担保）。報酬型のため許容（鯖の480pt上限で
  上振れも抑制）。観測日を 0 分として母数に入れる精緻化は将来検討（要・実機での `intervalDidEnd` 信頼性確認）。
- **当日の到達分は「実際の日替わり時のみ」リセット**（`resetDayIfRolledOver`）。アプリ起動/対象再選択での
  監視再開でも `intervalDidStart` は再発火し得るため、無条件リセットだと当日のポイントが消える
  （レビュー HIGH 指摘の修正済）。
- **per-app 内訳なし**: iOS は対象アプリを識別できない。合成バケット `ios.screentime` 1本に集約。
- **オンボ当日の遡及なし**: 監視開始は当日途中なので、その日の開始前利用は数えない（翌0:00から終日）。
  初日は warmup ボーナス卵で吸収（S1）。
- **しきい値到達の OS バグ余地**: 端末/iOS バージョンによっては即発火/未発火の報告あり → 実機検証必須。
- **信頼境界**: しきい値記録は端末自己申告（Android の usage_daily 同様＝H-2 受容リスク）。
  サーバー `fn_finalize_day` が 480pt/日上限・`is_finalized` 等で再検証するため新規の鯖穴は無い。

---

## 7. 検証の状態

- ✅ `dart analyze`（iOS 関連 Dart 全ファイル）= No issues。
- ✅ Apple/Flutter API 表面を Web 検証（FamilyControls/DeviceActivity/エンタイトルメント/xcodeproj/
  Flutter 3.44 AppDelegate）＝ high-confidence。
- ⬜ iOS 実コンパイル（macOS CI）＝**未実行**（課金段階・ユーザー判断待ち）。これが Swift の唯一の本検証。
- ⬜ 実機でのしきい値到達・ポイント反映＝Mac/実機が要るため後続。

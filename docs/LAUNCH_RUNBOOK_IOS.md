# Moffy iOS (App Store) 提出 runbook — オーナー手順

> v1.0 App Store 提出の実務手順。**[あなた]**=オーナーが操作 / **[私]**=Claude が用意・実行。
> 前提: Apple Developer=合同会社Lan (Team ID `JKPUV48L3V`) / ASCアプリID=`6785691850` / bundle id=`com.moffy.app` / iOSビルド=GitHub Actions `ios-build.yml`(mode=testflight・**無料**) / TestFlight に最新ビルド上げ済（見た目確認OK）。
> 参考: `docs/LAUNCH_RUNBOOK_ANDROID.md` / `docs/ASO.md`（文言・Apple版あり） / `docs/legal/STORE_DATA_SAFETY.md`（栄養ラベル）。

---

## ⚠️ STEP0：前提確認（IAPの土台・ここで詰まりやすい）[あなた]
- **有料App契約（Paid Applications Agreement）が「有効」か確認**：ASC → ビジネス → 契約/税金/口座 で **銀行口座・税務情報** を入力。**未完了だとサブスクを作れない/売れない**（最頻出のつまずき）。
- App Store Small Business Program（手数料15%）は**任意・後からでも申請可**。

## ① iOS課金：ASCでサブスク2商品を作成 [あなた]
1. ASC → Moffy → 収益化 → **サブスクリプション** → **サブスクグループ**を作成（例 `Moffy Premium`）
2. グループ内に2商品：
   - 商品ID `moffy_premium_monthly` ／ **¥480** ／ 期間=1ヶ月
   - 商品ID `moffy_premium_yearly` ／ **¥4,800** ／ 期間=1年
   （IDはAndroidと合わせると管理が楽。RevenueCat経由なので厳密一致は不要だが推奨）
3. 各商品に **無料トライアル（Introductory Offer）= 7日間**（対象=新規購読者）
4. 各商品の **表示名・説明（日本語）** を入力
5. 各商品に **審査用スクショ（課金画面）** を添付 ← **[私]が用意**
6. 状態が「提出準備完了」になればOK（アプリと一緒に審査へ）

## ② RevenueCat：iOS設定 [あなた]
1. RevenueCat → Moffyプロジェクト → Apps → **Add App（App Store）**／bundle `com.moffy.app`
2. **App用共有シークレット**：ASC → Moffy → 一般情報 → 「App用共有シークレット」を生成 → RevenueCatに貼る（またはASC APIキー連携）
3. ①の2商品を **Import** → Entitlement **`premium`** に attach → Offering **`default`** の **`$rc_monthly`/`$rc_annual`** に attach（Androidと同じ構成）
4. **iOS SDKキー `appl_...`** をコピー → 次の③で使う

## ③ ビルドにiOSキーを注入 [あなた＋私]
- **[あなた]** GitHub → リポジトリ Settings → Secrets and variables → Actions → **`REVENUECAT_IOS_KEY`** に②の `appl_...` を登録
- **[私]** `ios-build.yml` にそのキーの注入を追記（Android同様）→ **提出用ビルド（mode=testflight）**を回す
- ※このビルドで初めてiOSの課金が実際に動く（今のTestFlightビルドはキー無し＝商品が出ない＝想定どおり）

## ④ App Storeメタデータ [あなた・文言は私が用意]
- 名前／サブタイトル／キーワード／説明（`docs/ASO.md` §1-1・§3-2 のApple版）← **[私]が最終文言を渡す**
- プロモーションテキスト（170字・審査不要枠）／サポートURL／マーケティングURL

## ⑤ iOS用スクリーンショット [私が調整]
- 必須：iPhone 6.9インチ **1290×2796**。今日の5枚を **[私]** がこのサイズに調整して渡す

## ⑥ プライバシー栄養ラベル [あなた・回答は私が用意]
- ASC → App のプライバシー → `docs/legal/STORE_DATA_SAFETY.md` のApple版どおり入力（データ収集/トラッキング）

## ⑦ 審査提出 [あなた]
- バージョンにビルドを選択 → メタ・スクショ・ラベル入り → **定型回答**（下記）→ サブスク2商品も「審査へ提出」→ App本体を提出
- **定型回答**：
  - 輸出コンプライアンス（暗号化）：**いいえ**（`ITSAppUsesNonExemptEncryption: false` 設定確認 ← **[私]確認**）
  - コンテンツ著作権：自作
  - リリース：**手動リリース推奨**（承認後に公開ボタン）
  - **App Review情報（審査メモ）** に Screen Time/Family Controls の用途を明記 ← **[私]が文面用意**
- ⚠️ **サブスク再提出の儀式**：新ビルドを設定するとサブスクが「デベロッパの対応が必要」に戻ることがある。**戻った商品だけ**、ローカライズに微変更（説明文に空白追加→削除等）→保存→「審査へ提出」。

## ⚠️ 私と要相談（IAP/提出とは独立・並行で決める）
- **iOSの広告（AdMob）**：現状 Info.plist は**テスト広告ID**。App Storeにテスト広告のまま出すのは不可。→ (a) iOS AdMobアプリ/ユニットを作り実広告＋**ATT実装**、(b) iOS v1.0は広告なし/非パーソナライズ、のどちらか。**IAPを先に進めてOK**、広告は並行で決める。
- **ATT（App Tracking Transparency）**：iOSは未実装。広告IDのトラッキング可否で提出フォームの回答が変わる。

## 審査後
- 通常24〜48時間（連休前後は伸びる）。リジェクト → `rejection-rescue`（返信スレッドで用途説明＋再テスト依頼）。
- 承認 → 手動リリースで公開。公開直後24hは Sentry / レビュー欄 / 課金成功率を監視。

# iOS App Store スクリーンショット制作キット（/clear引き継ぎ用）

iOS用スクショ5枚（`docs/store/screenshots/ios/ios_01_home〜05_quests.png`・各 **1290×2796** = iPhone 14 Pro Max / 6.7"相当）の作り方。

## 方式：Codex CLI の画像生成（Images 2.0 / imagegen スキル「コンピング編集」モード）
- **私（AI）は画像を加工しない。生成もサイズ合わせも全部 Codex(GPT) 側。**
- 前提：`codex update` で **v0.144.4+**（既定モデル `gpt-5.6-sol` を動かすため。古い 0.142.0 だとモデルエラー）。
- コマンド：
  ```bash
  cd <作業ディレクトリ>
  codex exec --skip-git-repo-check -s workspace-write -i "<元画面.png>" < <prompt.txt>
  ```
  - `-i` に元アプリ画面、プロンプトは **stdin（< file）** で渡す（`-i` は可変長引数なので、プロンプトを引数に置くと画像として飲まれる）。
  - 保存先は Codex が `$CODEX_HOME/generated_images/` や別パスに置くことがある。プロンプト末尾で cwd 保存を指示しても、`C:\Users\user\AppData\Local\Temp\` や `./output/` に出る場合があるので生成後に回収する。

## 元画面
`docs/store/screenshots/_source/`（iPhone 14 Pro Max ビューポートで撮った 1290×2796 の実アプリ画面）。
- (iPhone 14 Pro Max).png = ホーム / (1)=たまご / (2)=図鑑 / (3)=色違い詳細 / (4)=クエスト
- これらは **PR #46 以前**に撮ったため「TikTokは20分まで」「広告オフ」等の古い文言が写る → **プロンプト内の「文言差し替え」指示**で #46 後の正しい文言（「SNSは合計60分まで」「保管枠アップ」）に置換して生成する（＝撮り直し不要）。

## 各プロンプト
| ファイル | 画面 | 元画面 | 文言差し替え |
|---|---|---|---|
| home_final_prompt.txt | ホーム | 既存合成(home)を微調整 | TikTok→SNS / 広告オフ→保管枠アップ |
| eggs_prompt.txt | たまご（**基準サイズ**）| (1) | なし（元々クリーン）|
| dex_prompt.txt | 図鑑 | (2) | 広告オフ→保管枠アップ |
| shiny_prompt.txt | 色違い | (3) | 広告オフ→保管枠アップ（背景）|
| quests_prompt.txt | クエスト | (4) | TikTok系3箇所→SNS 60分 |

## 共通デザイン仕様（全プロンプト共通）
- リアルiPhoneフレーム＋**傾き**＋接地影（#7A5C3E系）＋暖色グラデ背景（クリーム#FBF6EA→アプリコット#FFD7A8→ピーチ#FFC489）＋雲＋金/クリームのキラキラ。
- キャプション：丸ゴシック袋文字（濃茶#3A322B・クリーム縁取り）＋キーワード1語だけオレンジ#FF8A3D＋サブコピー(#7C7269)。
- 実UIそのまま／禁止語（アプリ名・広告・価格・無料・割引）なし／出力 1290×2796 ちょうど。

## ✅ 対応済み（2026-07-15）
1. **傾き交互 完了**：eggs_prompt.txt / shiny_prompt.txt の傾き記述を「左辺が奥／右3/4ビュー」に反転して `codex exec` → `ios_02_eggs.png` / `ios_04_shiny.png` を差し替え。シリーズは 右/左/右/左/右 に。
2. **ASCへ5枚アップロード 完了**：`tools/asc/asc_upload_screenshots.mjs`（`tools/asc/` の認証流用）で5枚を ja localization の `APP_IPHONE_67` セットへ。全枚 assetDeliveryState=COMPLETE。
   - ⚠️**教訓A（サイズ）**：ASC API の iPhone displayType は **`APP_IPHONE_67`** を使う（6.9"専用 `APP_IPHONE_69` は API 未追加＝指定エラー）。`APP_IPHONE_67` が必須6.9"枠を満たし **1290×2796 を受理**するので、1320×2868 への作り直しは不要。
   - ⚠️**教訓B（透過）**：App Store スクショは**アルファ不可**。codex 出力は 32bppArgb（RGBA）で、そのまま UL すると `IMAGE_ALPHA_NOT_ALLOWED` で拒否される → System.Drawing で白背景に不透過化して **RGB（colorType 2）** へ無損失変換してから UL する（全画素 α=255 なので見た目は不変）。

# Moffy セットアップ手順書 v1.0（第1パス縦スライス）

> 作成: 開発部署（engineer） / 対象: Android 縦スライス（利用時間取得 → ポイント算出 → ホーム表示）
> 前提: **Flutter/Dart SDK は未インストール**。本書の手順で導入してからビルドする。
> 専門用語は初出時に日本語説明。

---

## 0. このパスで動くもの / まだ動かないもの

- **動く（第1パス）**: アプリ起動 → ホーム画面表示 → 利用統計の権限チェック → 権限あればAndroidの
  `UsageStatsManager`（=アプリ別利用統計のOS API）で対象4SNSの利用分取得 → 基準値（7日平均）算出 →
  暫定ポイント計算 → ホームの5状態（ハッピー/権限なし＝エラー/ローディング/空＝卵なし/オフライン）表示。
- **まだ（後続パス）**: 卵の育成・孵化・抽選、図鑑、クエスト、Supabase同期（確定値）、課金（RevenueCat）、
  オンボーディング画面、ボトムナビ5タブ。ホームの通貨残高・アクティブ卵はサーバー未配線のため現状デフォルト値
  （0 / 卵なし＝空状態）で表示される。

---

## 1. Flutter SDK の導入

1. Flutter SDK（**3.22 以降 / Dart 3.4+**）を入手して任意のパスへ展開。
   - Windows例: `C:\src\flutter`。`flutter\bin` を PATH に追加。
2. 確認:
   ```powershell
   flutter --version
   flutter doctor
   ```
   `flutter doctor` で Android toolchain / Android Studio / 端末が緑になっていること。
3. Android SDK（API 34 推奨 / 最低 API 26）と、実機 or エミュレータを用意。
   - 利用統計（`UsageStatsManager`）は**実機推奨**（エミュレータはSNSアプリの実利用が無く0分になりがち）。

---

## 2. 依存解決とローカル設定

1. プロジェクト直下（`Moffy/`）で依存取得:
   ```powershell
   flutter pub get
   ```
2. Android のローカル設定を作成（テンプレートをコピー）:
   ```powershell
   Copy-Item android/local.properties.example android/local.properties
   ```
   `android/local.properties` を編集し、`sdk.dir` と `flutter.sdk` を自分の環境に合わせる
   （`local.properties` は端末固有・gitignore 対象）。

### 2-1. Supabase 設定（任意 / 第1パスは未設定でも起動可）

- 第1パスは利用取得とホーム表示が中心で、Supabase 未設定でも**オフライン専用モード**で起動する。
- 同期を試す場合のみ、ビルド時に環境変数を渡す（**秘密鍵は埋め込まない / 信頼境界**）:
  ```powershell
  flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co `
              --dart-define=SUPABASE_ANON_KEY=eyJ...
  ```
- `SUPABASE_ANON_KEY` は RLS 前提で公開可能な anon key のみ。`service_role` キーは**絶対にクライアントへ入れない**。
- DBは `supabase/migrations/0001_init.sql` を Supabase プロジェクトに適用しておく。

---

## 3. ビルドと起動（実機）

1. 実機を USB 接続（開発者モード + USBデバッグ ON）。`flutter devices` で認識を確認。
2. 起動:
   ```powershell
   flutter run -d <deviceId>
   ```
3. リリースAPK（PoC配布用 / デバッグ署名）:
   ```powershell
   flutter build apk --debug
   ```
   ※ リリース署名（keystore）は出荷前に `android/key.properties` + `app/build.gradle.kts` の
   `signingConfigs` を設定（後続パス）。

---

## 4. 利用統計の権限付与（実機での手動操作）

`PACKAGE_USAGE_STATS`（=「使用状況へのアクセス」特別権限）は通常の権限ダイアログでは取れず、
**ユーザーがOS設定で手動ON**する必要がある（ARCHITECTURE §4-2）。

1. アプリ起動直後のホームに「許可する」導線が出る（権限なしフォールバック）。
2. 「許可する」タップ → OS設定「使用状況へのアクセス」画面が開く（`AndroidUsageProvider.requestPermission`）。
3. 一覧から **Moffy** を選び、アクセスを **ON**。
4. アプリへ戻る → ホームを pull-to-refresh（下に引っ張る）すると再チェックされ、利用時間が表示される。
   - 戻っても反映されない場合: もう一度 pull-to-refresh、またはアプリ再起動。

---

## 5. PoC（実数値）検証手順へのリンク

実機で「利用分が正確に取れるか・基準値ロジック・480上限・30分クランプ」等を検証する手順は
**`docs/ARCHITECTURE.md` §4「Android 利用時間取得 PoC 検証手順書」** を参照
（§4-3 Platform Channel 設計 / §4-4 検証項目 / §4-5 フォールバック）。

検証で確認する主な数値（ARCHITECTURE §4-4 と一致）:
- 取得精度（ストップウォッチ比 誤差±2分以内/日）
- `INTERVAL_BEST` vs `INTERVAL_DAILY` の差（現状コードは `INTERVAL_BEST` を採用 / `UsageStatsHandler.aggregate`）
- 対象4アプリの実パッケージ名が取得できるか（TikTokは地域差に注意）
- 30分クランプで低利用ユーザーが0pt詰みしないか
- 480pt上限を超えないか

---

## 6. コード生成・静的解析（任意）

- 静的解析:
  ```powershell
  flutter analyze
  dart run custom_lint   # Riverpod 用ルール
  ```
- 本パスは Riverpod の手書き `AsyncNotifier` を採用しており、**build_runner によるコード生成は不要**で
  ビルドできる。`@riverpod` のコード生成へ移行する場合は:
  ```powershell
  dart run build_runner build --delete-conflicting-outputs
  ```

---

## 7. フォントについて（注意）

- `google_fonts` は実行時にフォント（Zen Maru Gothic / Noto Sans JP / Baloo 2）を取得する。
  初回はネットワークが必要。**オフライン安定・審査対策のため、出荷前に `assets/fonts/` へ同梱**し
  `pubspec.yaml` の `fonts:` 宣言へ切り替えること（後続パス）。

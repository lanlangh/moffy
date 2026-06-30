# ORG_STATE（=組織の状態ファイル / Moffy）

> プロジェクトルートの単一の状態置き場。AI 8 部署がセッションを跨いで「いま何をしているか」を思い出すための場所。
> `/app-dev-org:kickoff` が作成し、`/app-dev-org:weekly-brief` と各部署が更新する。

## ▶ RESUME / 現在地（2026-06-30・/clear後はここから読む）
- **🧭 即・次アクション（2トラック並行）**:
  - **【iOS】Screen Timeフル実装→TestFlight配信(build 15)まで到達済**。実機テストで判明した重大バグ2件を本日(06-30)修正: ①匿名サインイン未実装→`main.dart`に`signInAnonymously()`追加(build 15) ②**新規ユーザーに`profiles`行が作られない(`handle_new_user`トリガー未実装)＝「空の巣」「クエスト読み込み失敗」の真因**→マイグレーション`0006`(トリガー+既存backfill+`quest_definitions`5件seed)を**本番DBに適用済✅検証OK**。+`quest_definitions`空も解消。詳細は下記🍎/意思決定ログ。**🔴 いま=ユーザーがbuild 15を「削除→再インストール」(クリーンな新規匿名ユーザーで初回体験)して再テスト→「卵(はじまりのボーナス+200pt)が出るか/クエスト5件が出るか」の報告待ち**。
  - **【iOSビジュアル/UX】** 卵=暫定ベクター描画`lib/core/widgets/egg_art.dart`に刷新済(陰影/斑点/つや/ヒビ)。**本番イラスト品質にするには**ユーザーが`egg_common_0/1/2.png`(透過PNG/卵だけ/1024)生成→私が`Image.asset`差替(仕様=`docs/ART_ASSETS.md`/置場`assets/images/`未pubspec登録)。オンボ文言は平易化済。⬜残: 歓迎画面(旧OB3=最初の卵プレゼント)新設・ホーム初回文言・空巣状態・(任意)Mofiキャラ画像。**見た目/UX変更は次のXcode26署名リビルドでまとめて反映**(都度有料ビルドを避けバッチ)。コンセプト/アセット参照画像=リポジトリ直下に`ChatGPT Image 2026年6月19日 *.png`5枚＋UUID名PNG(`0f2a3be5-...png`/`94e6fbdb-...png`等)＝いずれも複数アセットを1枚にまとめた「参照シート」(git未追跡)。**そのままは使えない→卵/キャラの個別透過PNGが別途必要**(Globで発見可)。
  - **【Android】署名AAB完成済→ユーザー操作待ち(私は進めない)**: `C:\Users\user\Downloads\Moffy-AAB\app-release.aab`(再ビルド=`gh workflow run "Build AAB"`)→Play内部テストにUL＋SA`tsuzuru-play-publisher@tsuzuru-497609`に「ストアでの表示の管理」権限付与→サブスク2商品(`moffy_premium_monthly`¥480/`moffy_premium_yearly`¥4800/7日トライアル)作成→RevenueCat紐付け。
  - **🔑 運用キー(全てGitHub Secret・.p8等はgitignore)**: iOS署名=ASC**Adminロール必須**(`Moffy CI`/KEY_ID=`SVU9YZ67XQ`/ISSUER=`9752db09-58b4-45c6-a7f0-684c3adcc333`/.p8=`secrets/AuthKey_SVU9YZ67XQ.p8`)→Secret `ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_P8_BASE64`(旧`Claude MCP`=`C52K3L4Q5S`はApp Managerで署名Export不可)。Supabase=`SUPABASE_URL`(`https://iktpuxgxsaejwtocqnzk.supabase.co`)/`SUPABASE_ANON_KEY`(`sb_publishable_9jMya-72hqwLnNlgW8VV_A_SlWHiZZ0`)。Team ID=`JKPUV48L3V`。ASCアプリID=`6785691850`。DB=Secret`SUPABASE_DB_URL`。
  - **🛠 iOSビルドの要点**: **Xcode 26(iOS26 SDK必須=Appleアップロード要件)+sentry_flutter 9.x(8.xはXcode26不可)+CocoaPods(SPM無効化)**。`ios-build.yml` mode=`compile`/`release`(署名IPA)/`testflight`(IPA+altoolアップロード)・ビルド番号=`github.run_number`自動。DB適用=`DB Apply 0006`等のワークフロー。`Configure iOS`(Linux無料)でpbxproj配線検証。⚠️ユーザー=アプリ開発初心者/Mac無し/費用敏感(macOSビルドは有料・都度確認)。
- **進捗**: MVPクライアント一式＋経済バックエンド(`supabase/migrations/0001〜0005`)完成。**CI=123テスト緑**(GitHub Actions)。経済セキュリティは**5ラウンドのクロスレビューで収束＝GO**(C-1/C-2/C-3/H-1/H4-1/G-1〜3/M-2/M4-1封鎖済、残H-2は受容)。**🟢ライブDB検証完了**: Supabase本番(`moffy-prod`/Tokyo/別アカウント)に`0001〜0005`適用＋抽選分布(§4)全PASS＋§3権限グリッド/列GRANT/H4-1ランタイム実証 全PASS(2026-06-25)。価格(`pricing.dart`)・法務(`docs/legal/`)・ASO(`docs/ASO.md`)・オーナー手順書あり。**観測(Sentry/PostHog)配線=完了**(PR#1)。**RevenueCat Webhook→entitlements配線=完了**(PR#2・Edge Function＋クライアント合成server権威・Codex(別モデル)+Claude-QAクロスレビューGO)。**CI=123テスト緑・analyze No issues**。
- **次の一手(2026-06-26・課金/認証フェーズ)**: **✅署名付きAABビルド成功(`build-aab.yml`手動実行・GitHub Actions)**→ 🔴いま=Play内部テストにアップロード→サブスク作成解禁。経緯: サブスク作成にはアプリのビルド(AAB)を1回トラックにアップロード必須(Google仕様・公式確認)。**クラウドビルド=7回の修正で成功**(①AGP8.5→8.9.1②Gradle8.7→8.11.1③shrinkResources off④Kotlin1.9.24→2.2.0⑤root build.gradleでsubprojects Kotlin languageVersion=2.0底上げ[sentry_flutter1.6衝突回避・configureEach遅延])。Android雛形欠落も補完(gradle-wrapper.jar/gradlew[+x,LF/.gitattributes]/mipmapアイコン)。署名鍵=openssl PKCS12(`C:\Users\user\secrets\moffy-upload-keystore.p12`・リポジトリ外)＋Secret(`ANDROID_KEYSTORE_BASE64`/`_PASSWORD`/`ANDROID_KEY_ALIAS`)。**成果物**: AAB(Play用)＋APK(プレビュー用)を artifact 出力。**ビューア=appetize.io**(実機/Web不可[dart:io使用]のためブラウザ実機エミュ)。次: ①AAB→内部テストUL②サブスク`moffy_premium_monthly`(¥480)/`moffy_premium_yearly`(¥4800)＋7日トライアル作成(API形状=`regionsVersion.version=2022/01`をクエリ・要"ストアでの表示の管理"権限反映)③RevenueCat商品紐付け④実キー`--dart-define`ビルド＋サンドボックス購入⑤スクショ・データ安全性・審査提出。残: 法務URL欄・Apple小規模事業者(iOS/v1.1)。
- **⚠️ユーザーは「アプリ開発初心者」**: 専門用語は都度かみ砕いて説明する。SA=サービスアカウント(ロボット用アカウント)等。画面スクショで1ステップずつ案内する運用。
- **RevenueCat進捗(2026-06-26)**: Project「Moffy」(ID`proj7f8f291e`)作成・Platform=Flutter・Google Play App追加(`com.moffy.app`)・SA JSON接続済(`moffy-play-sa.json`=TSUZURU既存SA再利用)。「Credentials need attention」(SA権限反映待ち)・Pub/Sub API有効化済(Editorロール/Connect to Googleは任意・後回し)。Webhook/SDKキー/商品紐付けは後続。
- **🍎 iOS方針=フル実装で出す(2026-06-26ユーザー決定・日本市場iOS重視)**: Apple Developer=Manabu Osawa・**合同会社Lan(Team ID=`JKPUV48L3V`)**。**2026-06-29ポータル実査＋整備＝完了**: 当初Identifiersに`com.moffy.app`未登録だった(既存はlifenote/tsuzuru/viralumeのみ)が、ユーザーが当セッションで整備完了: ✅App Group `group.com.moffy.app`作成／✅App ID `com.moffy.app`(App Groups＋Family Controls Dev/Dist)作成・グループ紐づけ／✅App ID `com.moffy.app.MoffyMonitor`(同上)作成・グループ紐づけ。**✅Family Controls (Distribution)=「Assigned」=アカウントに承認済み→配布申請(数週間待ち)不要**(Capability Requestsタブで確認)。**=iOS署名ビルドのポータル前提は全て充足**。残るはCI署名設定→TestFlight。**ユーザーはMac無し**→iOSビルドはクラウドmacOS(GitHub Actions・10倍消費/少額費用注意)。
  - ✅ **iOS土台完了**: `ios/`雛形=`scaffold-ios.yml`(Linux/flutter create)で生成・commit済。bundle id=`com.moffy.app`に統一済。`.gitattributes`でiOSソースLF固定済(macOS CRLF対策)。
  - ✅ **核心=Screen Timeフル実装 完了(2026-06-29・コード)**。設計=`docs/IOS_SCREENTIME.md`。**重要な仕様差(Androidの移植ではない)を反映済**: ①iOSは分数取得不可→DeviceActivityの**しきい値到達(15/30/45/60/90/120/150/180/240/300分)を近似利用分**として扱う②対象アプリは不透明トークンで識別不可→ユーザーが`FamilyActivityPicker`で選ぶ→**iOSオンボーディング分岐を実装**③`threshold-achievement`モードで既存計算器に流す。**シールド(アプリブロック)はしない**=報酬型・観測のみ(2つ目の拡張/申請を回避)。
  - **実装ファイル**: Dart=`lib/core/usage/ios_usage_provider.dart`(新規`IOSUsageProvider`+`usage_provider.dart`の`ScreenTimeAppSelection` capability)/`usage_providers.dart`(`Platform.isIOS`配線)/`onboarding_screen.dart`(iOS分岐)/`test/ios_usage_provider_test.dart`。ネイティブ=`ios/Runner/{ScreenTimeShared,ScreenTimeHandler}.swift`+`AppDelegate.swift`(チャネル配線=`applicationRegistrar.messenger()`)+`Runner.entitlements`、`ios/MoffyMonitor/`(拡張`DeviceActivityMonitor`+Info.plist`NSExtensionPointIdentifier=com.apple.deviceactivity.monitor-extension`+entitlements)。拡張ターゲットのpbxproj配線=`ios/tools/configure_screentime.rb`(純Ruby/Linux可・冪等・自己検証付き)。CI=`configure-ios.yml`(Linux無料検証)/`ios-build.yml`(macOS課金・手動コンパイル検証)。チャネル名=`com.moffy/usage_stats`。
  - ✅ **API表面=Web検証(high-confidence)済＋クロスレビュー(Claude-QA独立3観点)=GO_WITH_FIXES→指摘反映済**: 🔴CRITICAL(configure_screentime.rbのパス二重化→ビルド不能)を修正(全ref=main_group/SRCROOT相対+File.exist?検証+埋め込みphase検証)。🟠HIGH(起動毎の`intervalDidStart`再発火で当日記録が0クリア→今日のpt消失)を修正(`resetDayIfRolledOver`=実日替わりのみリセット)。medium/lowも反映(dead code除去/23:59:59デッドゾーン/baseline近似はAndroid整合でdoc明記)。**⚠️限界開示=今回はCodex(別モデル)不在のClaude-QA代替。残る唯一の未検証=Swift実コンパイル(Mac必須)＝`ios-build.yml`が本検証**。
  - ✅ **配線検証(無料/Linux)=完了**: `Configure iOS`緑。拡張ターゲット作成・PlugIns署名埋め込み・entitlements・参照解決・冪等を実証。configureステップはmacOSでも通過。
  - ✅ **macOSコンパイル=成功(2026-06-29)**: Screen Time Swift全ファイルがiOS18 SDKで通過＝本検証クリア。到達まで解消した既存衝突(Screen Time無関係): `dependency_overrides: device_info_plus 12.3.0`(12.4.0の`isiOSAppOnVision`回避)／**Flutter SPM無効化=CocoaPods統一**(`sentry_flutter 8.x`はSPM非対応で`SentryBinaryImageCache.image`不整合・posthogも元々Pods)／Xcode**16.x**固定(latest=26.3は2024年代プラグインを壊す)／`Embed App Extensions`を`Thin Binary`前へ移動(`Cycle inside Runner`回避)／自Swift修正(`messenger()`非Optional・`AuthorizationStatus`に`.approvedWithDataAccess`無し)。`ios-build.yml`に全反映。配線検証(`Configure iOS`/Linux)も緑。
  - ✅ **Appleポータル準備=完了(2026-06-29)**: App Group `group.com.moffy.app`／App ID `com.moffy.app`＋`com.moffy.app.MoffyMonitor`(両方 App Groups＋Family Controls Dev/Dist・グループ紐づけ済)／**Family Controls(Distribution)=Assigned=承認済(申請不要)**。Team ID=`JKPUV48L3V`。
  - ✅ **CI署名=完成・署名IPA生成成功(2026-06-30・マイルストーン1完了)**: `ios-build.yml` mode=compile/release/testflight。`xcodebuild archive`+`-exportArchive`＋`-allowProvisioningUpdates`＋ASC APIキー。ExportOptions=app-store-connect/automatic。`mode=release`で**`moffy.ipa`(33MB)生成成功**(artifact `moffy-ios-ipa`)。配布証明書・Runner/MoffyMonitor両プロファイル自動生成・Family Controls配布・拡張埋め込み・クラウド署名 全OK。**ASC APIキー=Adminロール必須**(`Moffy CI`/Key ID=`SVU9YZ67XQ`/Issuer=9752db09-...333・Secret登録済。旧`Claude MCP`=`C52K3L4Q5S`はApp ManagerでExport不可だった)。教訓: ①コマンドラインで`CODE_SIGN_IDENTITY`を渡すとAutomatic署名と競合→渡さない ②Exportのクラウド署名はAdminロール必須。.p8=`secrets/AuthKey_SVU9YZ67XQ.p8`(gitignore済)。
  - ✅ **TestFlightアップロード成功(2026-06-30)**: `mode=testflight`で `VERIFY/UPLOAD SUCCEEDED`。Xcode 26(iOS26 SDK・Appleのアップロード必須要件)＋sentry_flutter 9.x(8.xはXcode26不可)へ移行して達成。device_info_plus上書きは撤去(Xcode26では自然解決版が通る)。ASCアプリレコード`com.moffy.app`作成済。
  - ✅ **実機インストール成功(2026-06-30)**: ビルドVALID→内部テストグループ`Internal`(自動配信ON)→TestFlightアプリでMoffy起動。
  - 🟥 **初回UXが「全く使い方が分からない」(オーナーFB)→product-designer監査実施**。**最有力原因=テストビルドがバックエンド未接続**: `ios-build.yml`が`--dart-define`未指定→`Env.hasSupabase=false`→**Mock/オフライン=warmup卵が生成されず祝福も出ず"空の巣"ホーム**。加えて設計書`SCREEN_FLOWS §1`の「最初の卵プレゼント」歓迎画面が**未実装**(オンボ完了→無言でホーム直行)、専門用語(pt/基準値/計測)未説明、iOSピッカーが唐突。
  - ✅ **A. バックエンド接続=完了**: `--dart-define=SUPABASE_URL`/`SUPABASE_ANON_KEY`をios-build.ymlに注入(Secret登録済・URL=`https://iktpuxgxsaejwtocqnzk.supabase.co`/anon=`sb_publishable_...`。app_config読取をcurl 200で検証済)。ビルド番号は`github.run_number`で自動採番(重複回避)。**接続版TestFlightアップロード成功**(Apple処理後インストールで本物の初回体験=warmup卵+祝福が出る)。
  - 🟥→✅ **重大バグ修正2: profiles行が作られない(2026-06-30・真の根本原因)**: 新規(匿名)ユーザーに`public.profiles`行が一切作られていなかった(0001はコメントで「匿名認証で行が作られ」と想定も、`auth.users`の`handle_new_user`トリガー未実装。`fn_claim_warmup`はUPDATEのみで行を作らない)。→profiles無し→warmup(卵/pt)失敗(空の巣)＆`fn_sync_quests`が`profile_not_found(P0002)`で例外(クエスト読み込み失敗)。加えて`quest_definitions`が空(seed未投入)。**`0006_profile_autocreate_and_quest_seed.sql`**=①`handle_new_user`トリガー②既存ユーザーbackfill③quest 5件seed(冪等)。**`DB Apply 0006`ワークフローで本番適用✅検証OK(2026-06-30: quest_defs=5/profiles=users=1でbackfill確認/トリガー有効)**。アプリ再ビルド不要(DB側修正)。ユーザーは**build 15で削除→再インストール(=新規匿名ユーザーでクリーンに初回体験)**して再テスト。
  - 🟥→✅ **重大バグ修正1: 匿名サインイン未実装(2026-06-30)**: アプリが`signInAnonymously()`を一度も呼んでおらず(コメントだけ)、Supabaseセッション無し→`auth.uid()`=null→**warmup卵作成もクエスト(`fn_sync_quests`)も`unauthorized(28000)`で失敗**=「空の巣」「クエスト画面エラー」の真因。`main.dart`の`Supabase.initialize`後に`currentSession==null`なら`signInAnonymously()`を追加(端末ごと匿名1人・永続)。**接続版が初めて機能する**。✅**TestFlight build 15 にアップロード済(匿名認証+新卵+改善文言)**。※build 14=接続済みだが認証修正前(空巣/クエストエラー)・build 1=未接続Mock。ユーザーはbuild 15処理完了後に更新して再テスト。
  - 🟧 **B. UX/ビジュアル改善(進行中)**: ✅オンボ文言平易化(OB2/権限/iOSピッカー＋未選択時ボタン)。✅**卵を暫定ベクター描画に刷新**(`lib/core/widgets/egg_art.dart`=陰影/斑点/つや/成長ヒビ/SSRきらめき。`active_egg_panel`の`Icons.egg_rounded`を置換)。✅**本番アセット仕様書`docs/ART_ASSETS.md`**(卵12=レア4×段階3/Mofi30/UI・透過PNG1024。置き場`assets/images/`)→**ユーザーがまず`egg_common_0/1/2.png`生成→Image.asset差替**。⬜残: 歓迎画面(旧OB3)新設・ホーム初回文言・空巣状態。**コンセプト**=直下`ChatGPT Image 2026-06-19 *.png`5枚(やわらか3D風kawaii・巣の卵・Mofi3系統)。
  - 📌 **ビジュアル/UX変更は次回のXcode26署名リビルドでまとめて反映→再テスト**(毎変更ごとの有料ビルドを避けバッチ)。
  - 🔴 **その後**: 実機E2E(しきい値到達→ポイント反映)→ストア提出準備。
  - ⚠️ Mac無し→反復ごとmacOS CIビルド(10倍消費)で重い→**クラウドMac検討余地**。コード実装フェーズは完了済(無料)、残るビルド/署名フェーズが有料。
- **DB決定(2026-06-25確定・完了)**: **Moffy専用の別Supabaseアカウントで継続**(ユーザー選択・プロジェクト`moffy-prod`作成済/Tokyo/匿名認証ON)。接続はGitHub Secret `SUPABASE_DB_URL`(**Session pooler/IPv4** — GitHub ActionsはIPv4のためDirect/IPv6不可)。検証ワークフロー: `DB Verify`(クリーンDBブートストラップ=migrations+分布+権限)/`DB Permission Check`(既存ライブDBへ§3だけ再実行可)。
- **環境メモ(重要)**: ①ローカル`flutter`は企業**WDACでブロック**→検証は**GitHub Actions CI**(private repo **`lanlangh/moffy`**)。`dart analyze`はローカル可。②**Codex**(別モデルレビュー)は大レビュー約1回ごとに**レート制限**・数時間でリセット→不在時はClaude-QAサブエージェントで代替(限界開示する)。③Flutter SDK=`C:\Users\user\flutter`(PATH=`C:\Users\user\flutter\bin`)。④コード生成(build_runner)未使用。
- **組織**: 8部署エージェント+14スキル+7コマンドは`.claude/`に導入済み(/clearしても残る)。本ファイルが組織メモリ。`spawn_task`は使わない運用。

## プロダクト概要
- **一文定義**: 「SNSを見すぎてしまう18〜35歳」が「スマホ時間を減らせない課題」を「削減した時間でかわいいキャラ(Mofi)が育つ収集ゲーム化」で解決する
- **配信先**: **Androidファースト → iOS追従**（=決定理由: iOSは利用分数を数値取得できず、Androidは`UsageStatsManager`で正確取得できるため、コア経済をAndroidで実数値検証してからiOSへ移植）
- **収益モデル**: 無料 + プレミアムサブスク（=¥480/月想定。限定Mofi・プレミアム卵・詳細分析・広告削除・保管枠増加）

## 現フェーズ
- [x] アイデア検証 → [x] 設計 → [x] コア開発（クライアント＋経済バックエンド**ライブDB検証済**＋観測配線） → [ ] 課金・認証 ←**いまここ**（RevenueCat Webhook＋法務記入＋実接続スモーク） → [ ] テスト → [ ] 提出準備 → [ ] 審査中 → [ ] 公開済み（=運用）

## 今サイクルのフォーカス（=設計サイクル・完了）
1. ✅ **【企画】不足仕様の確定とPRD化** → `docs/PRD.md`（S1〜S14決定・抽選確率表・受け入れ条件）
2. ✅ **【開発】アーキ確定 + DBスキーマ + PoC手順** → `docs/ARCHITECTURE.md` / `supabase/migrations/0001_init.sql`
3. ✅ **【デザイン】トークン + 画面フロー** → `docs/DESIGN_SYSTEM.md` / `docs/SCREEN_FLOWS.md`（署名要素「巣リング」、量産顔回避）

## コア開発の進捗
- ✅ **第1パス（縦スライス）** — 利用取得→pt→ホーム表示。`pubspec.yaml`/テーマ(巣リング)/経済SSOT/OS抽象+Android `UsageStatsManager`(Kotlin)/ホーム5状態/`test/point_calculator_test.dart`/`docs/SETUP.md`
- ✅ **ビルド検証** — Flutter 3.44.2/Dart 3.12.2 を `C:\Users\user\flutter` に導入。`flutter pub get`成功(167パッケージ)、`flutter analyze`=**No issues found!**、`flutter test`=**10/10 pass**。エラー3+警告/info修正済み（failure.dartのsuper呼び出し・tokens.dartのlibrary位置・raw型・非推奨anonKey→publishableKey 等）。※APK/実機起動は**Android SDK(JDK/Gradle)未導入**のため別途必要
- ✅ **第2aパス** — ナビ5タブシェル・オンボーディング(権限付与)・卵(3枠/保管/成長段階)・孵化演出(色違いキラリ+シェアCTA)・図鑑(達成率/フィルタ/シルエット)。`analyze`緑・テスト32
- ✅ **第2bパス** — クエスト(デイリー/ウィークリー/報酬)・ストリーク(倍率・基礎ptのみ)・プロフィール/メニュー・アカウント連携導線(S10)・通知設定(S9)・退会導線(S12)・同期エンジン(sync_queue/競合解決S8)。`analyze`緑・**テスト68/68**
- ✅ **サーバーRPC実装** — `supabase/migrations/0002_economy_rpcs.sql`（`fn_finalize_day`/`fn_apply_growth`/`fn_hatch_egg`/`fn_grant_quest_reward`/`fn_spend_currency`/`fn_delete_account`）。全て`security definer`+`search_path=''`+冪等、確率/しきい値は`app_config`/`drop_tables`から読む（直書きなし）。クライアント本配線(Supabase時RPC/未設定時モック)。`docs/BACKEND_SETUP.md`・`supabase/tests/distribution_check.sql`。Flutter **72/72緑**
- ✅ **ライブ検証完了(2026-06-25)** — Supabase本番`moffy-prod`に`0001〜0005`適用成功。`distribution_check`(§4抽選分布・色違い率0.0197・SR個体均等・drop_tables合計=1.0)全PASS。`permission_check`(§3 RPC権限グリッド15関数/列GRANTホワイトリスト/H4-1ランタイム=is_finalized偽造INSERT 42501拒否)全PASS。`.github/workflows/{db-verify,db-permission-check}.yml`＋`supabase/tests/permission_check.sql`
- 🟧 **QA独立レビュー(docs/REVIEW_0002_economy.md) = NO-GO(条件付き)** — Critical0/High3+Medium1。確定OK: 信頼境界・権限revoke/grant・型整合(quest_id)・FK cascade(退会孤児なし)・抽選ロジックとtestの整合。差し戻し必須:
  - F-01(High) ウォームアップ自動付与(Day1=200/Day2=300pt+初回ボーナス卵)が0002に未実装 → S1初日体験が不成立
  - F-02(High) ストリーク倍率off-by-one(継続加算前のstreakで倍率→3日目×1.0になる)
  - F-03(High) 退会が即時物理削除でS12/スkeマ(deleted_at)と不一致 → **【CEO裁定】即時論理削除(deleted_at)＋30日後に物理パージへ統一**
  - F-04(Medium) quest報酬の残高更新がget diagnostics非対称で台帳とズレ得る → finalize_dayと同じ初回ガードに揃える
  - ※Codexヘッドレスがハングし利用不可のため、別モデルでなくClaude-QAによる静的レビューで代替(限界開示)
- ✅ **差し戻し修正(F-01〜F-04)実装完了** — F-01 `fn_claim_warmup`(0003_warmup_grants.sql,生涯1回冪等+starter卵)/F-02 ストリーク倍率を`streak_multiplier(streak+1)`に修正/F-03 退会=論理削除`deleted_at`+RLS`deleted_at is null`+`fn_purge_deleted_accounts`(service_role専用,pg_cron)/F-04 quest報酬を初回ガードに統一。`dart analyze`=No issues
- 🔴 **環境問題: `flutter`がWDAC(企業管理ポリシー)でブロック【原因確定】** — `dart.exe`が`dartvm.exe`をロード時に "did not meet the **Enterprise** signing level requirements" で拒否(CodeIntegrity 3033/3077)。企業WDACがEnforce(カーネル/ユーザー=2)。06-23頃にMDM/GPOでポリシー更新・強制適用されたためセッション途中から発生。Google署名のFlutter SDKは要求署名レベル未達。
  - **解除は管理者/IT権限が必要**(WDAC許可ルール追加・署名レベル変更・無効化は admin+ポリシー再コンパイル+再起動)。回避は不可・不適切。パス移動(Program Files)も署名問題のため無効。
  - **検証手段**: `dart analyze`=非フォークのため可。`flutter test`はWDACで不可 → **CIで解決済み**。
  - F-01配線UI(claimWarmup呼出箇所)も後続
- ✅ **CI構築・検証ギャップ解消** — git初期化→**private GitHub repo `lanlangh/moffy`** へpush。`.github/workflows/ci.yml`(ubuntu, Flutter 3.44.2)で `pub get`/`analyze`/`test` を自動実行。**CI実行=analyze No issues + テスト全パス(最新112件)**。以後ローカルWDACに依存せずクラウドで緑を担保。コード生成は未使用のためbuild_runner不要。`purchases_flutter`もCIで解決・通過。
- ✅ **ライブ検証(SQL経済適用+分布+権限)完了** — 上記2026-06-25で実施。残るのは統合シナリオ(孵化/受取/退会/同時操作)の実RPC叩き=アプリ実接続スモーク段で実施。
- ✅ **価格・IAP設計(財務)** — `docs/PRICING.md`・`lib/core/constants/pricing.dart`(SSOT)。**月額¥480 / 年額¥4,800(約17%OFF,おすすめ) / 7日無料トライアル**。無料↔プレミアム境界=保管枠20↔200・広告無料のみ・限定Mofi/プレミアム卵はプレミアム・育成3枠はプラン非依存・詳細分析v1.1(課金画面で宣伝しない)。RevenueCat: offering`default`→monthly/annual→entitlement`premium`(サーバー検証が正)。Apple小規模事業者プログラム(30→15%)はlaunch前申請。`dart analyze`緑

- ✅ **法務3文書＋ストア審査対応(法務)** — `docs/legal/{privacy_policy,terms_of_service,tokushoho}.md` + `docs/legal/STORE_DATA_SAFETY.md`(Playデータ安全性/App Store栄養ラベル/景表法チェック)。確定価格・3rdパーティ実名(Supabase/RevenueCat/Sentry/PostHog,広告なし)・S12退会を反映。**最重要=`PACKAGE_USAGE_STATS`の利用目的をプラポリ/データ安全性/Console権限宣言の3点で一致**。会社固有情報は`【要記入】`プレースホルダ。`dart analyze`緑(legal_links.dartはコメントのみ)
- ✅ **法務文書の事業者情報=記入完了(2026-06-25)** — 公開事業者=**合同会社Lan(代表/運営統括/個人情報保護責任者=大澤 学・所在地=東京都新宿区西新宿3-3-13 西新宿水間ビル2F・窓口=info@lan-corp.com)**(ユーザー確認済)。プラポリ/利用規約/特商法/`legal_links.dart`(support/deletion=info@lan-corp.com)に反映・push済。特商法の電話=**開示請求方式(番号非掲載)**、管轄=本店所在地を管轄する地裁、対応OS=Android。運用アカウント/電話番号は非掲載(方針)。情報源=隣の`tsuzuru`フォルダ(別アプリ・読取のみ)。
  - ✅ **公開用クリーン化完了** — 公開3文書(privacy/terms/tokushoho)から内部注記/AI免責を除去、最終更新日=2026年6月25日。`docs/legal/README.md`に内部リマインダ保全。`STORE_DATA_SAFETY.md`は内部用。
  - ✅ **Notion公開＋URL配線完了(2026-06-25)** — ユーザーがNotion公開ページ3点を作成(TSUZURUと同一`mud-nectarine-0f9.notion.site`ワークスペース)。3URLとも未ログインで公開アクセス可をcurl(200)＋Jina(全文取得)で実証。`legal_links.dart`(privacy/terms/tokushoho)＋`docs/ASO.md`に反映済・push済。`?source=copy_link`除去。
    - privacy=`.../Moffy-...805f` / terms=`.../Moffy-...809d` / tokushoho=`.../Moffy-...80a8`
  - ⬜ **残**: ①ストア提出時のプライバシーURL欄に上記privacy URLを設定(掲載と完全一致=審査要件) ②法人番号(任意) ③提出前に内容改訂したら3文書の最終更新日を揃えて更新。

- 🔒 **セキュリティ監査(CEO)＋修正0004** — Supabase RLS監査で3件の穴を発見・修正(`0004_security_hardening.sql`)。**G-1**:`baselines`のRLS未有効→有効化+select-own(漏洩穴)。**G-2**:`profiles`全列更新可→列GRANTで`display_name/timezone`のみ許可(gem/point/pooled/deleted_at/is_linked除外＝**課金通貨の直接改ざん防止**)。**G-3**:`eggs`全列更新可→`slot_index/location/is_active`のみ許可(growth_points/hatched_into除外＝即孵化チート防止)。definer関数は所有者権限で全列書込継続。**残存リスク**:usage_daily自己申告(OS時間はサーバー検証不能・480pt上限+anomalyで緩和)。db-verify.ymlも0004適用に更新。**QA再点検＋第三者レビュー要**(Codexはヘッドレスでハングし不可→Claude-QA代替を都度開示)

- 🟥 **Codexクロスレビュー成功(gpt-5.5)＝2件の重大穴を新規検出(Claude-QA見逃し)** — クロスモデルレビューが機能した:
  - **C-1(Critical) クエスト報酬偽造**: `user_quests`はクライアントが`is_completed=true`行を直接作成可(insert/update列無制限) → `fn_grant_quest_reward`が`is_completed`を信用しpt/ジェム/卵付与 → プレミアム通貨の無限偽造
  - **H-1(High) 再孵化**: G-3で`location`更新許可 → 孵化済み卵を`incubating`に戻す+growth維持 → `fn_hatch_egg`(location='hatched'のみ拒否)で再孵化し放題=図鑑無限増殖
  - Codex検証OK: baselines/profiles/eggs列ロック・definer整合・冪等・他人読取なし。
  - 0005で C-1元経路/H-1 を修正 → **Codex再レビュー: H-1完全クローズ✅・C-1元経路クローズ。但し新規2件検出**:
    - **C-2(Critical/新規)**: `quest_condition_met('app_under')`が**fail-open**(usage行無し=0分扱いで0<targetが真)＋クライアントが`user_quests`を任意INSERT可 → データ無し日でクエスト捏造し報酬取得。要: 条件をfail-closed化＋クエスト生成をサーバー専管(client INSERT剥奪)
    - **M-2(Medium/新規)**: 孵化済み全UPDATE拒否トリガーが`hatched_into ON DELETE SET NULL`カスケード(退会パージ)を巻き込み失敗。要: 「location が hatched から変わる時のみ拒否」に精緻化
  - ✅ **0005でC-2/M-2修正・CEO直接コード検証でクローズ確認** — C-2: `quest_condition_met`のapp_under/reduce_totalを**fail-closed**(usage行が存在し`is_finalized=true`の時のみ達成。行無し/未確定→未達)＋`user_quests`のクライアントINSERT剥奪＋サーバー専管`fn_sync_quests`で冪等生成。M-2: トリガーを`old.location='hatched' and new.location is distinct from old.location`に精緻化(復活のみ拒否・hatched_into=nullカスケード許可)。CI=118テスト緑。
  - ⚠️ **Codex 3巡目はレート制限でハング(停止済)** → C-2/M-2はCEO直接コード検証で確認(対象が小さく要件明確)。**完全に独立な3巡目Codex確認は制限解除後に再実行推奨**＋ライブSQL Editor実行でも裏取り。
  - **Codex 3巡目(制限解除後)**: C-2/M-2とも**CLOSED確認**✅。但し**新規C-3(High)検出**: `hatch_count`偽装 — 0004で`location`更新をクライアント許可したため、未孵化卵を直接`location='hatched'`に書き換え可(トリガーはhatchedから出る変更のみ拒否)→`quest_condition_met('hatch_count')`が`fn_hatch_egg`非経由の偽hatchを計数。fn_sync_questsは健全(timezone可変は低リスク)。
  - ✅ **C-3修正・CEO直接コード検証でクローズ** — eggsトリガーに `new.location='hatched' and old.location is distinct from 'hatched' and new.hatched_into is null → raise` 追加。fn_hatch_eggはhatched_into同時setで通過、クライアント直接hatched化(hatched_into NULL)は拒否＝`location='hatched'`計数が信頼可能に。
  - ⚠️ **Codex 4巡目はまた制限でハング(停止済)** — Codexは大きいレビュー約1回ごとに制限到達。C-3はCEO直接検証で確認。**注意**: Codexは毎回新規issueを検出してきた実績(2巡目C-1/H-1→3巡目C-3)があるため、制限解除後に**クリーンな最終ラウンド**を1回回す価値あり。
  - **Claude-QAサブエージェント4巡目(Codex制限のため代替)**: C-3 CLOSED確認✅。但し**新規H4-1(High)検出**: `usage_daily.is_finalized`をクライアントが直接true化可(0004列GRANTがusage_dailyに未適用) → fn_finalize_day非経由で「0分・確定」行をINSERT→`app_under`クエストのジェム/卵/pt偽造(480上限外)。C-2 fail-closed修正の前提が破れていた。関連Medium: is_anomaly改ざん/pooled無限累積。
  - ✅ **H4-1/M4-1修正(CI 118緑)** — `usage_daily`列GRANT(client書込はuser_id/usage_date/total_minutes/per_app_minutes/source_modeのみ、is_finalized/is_anomaly除外)＋`fn_finalize_day`が`is_anomaly`をサーバー算出(total_minutes>daily_minutes_max=1440)。client同期から is_anomaly 除去。M4-2(pooled上限)/L4-1は後続明記。→ round-5確認中
  - ✅ **round-5(Claude-QA確認ラウンド)＝収束/GO** — H4-1/M4-1 CLOSED確定。**新規Critical 0/High 0/Medium 0**(Low1件のみ・実害なし)。全クライアント書込可能列から報酬/通貨/図鑑/プレミアムへの新経路を能動探索→発見なし。
  - **【経済セキュリティ・エピック完了】封鎖済: C-1/C-2/C-3/H-1/H4-1/G-1/G-2/G-3/M-2/M4-1。残る構造リスク=H-2(reduction自己申告・480上限+anomalyサーバー算出で緩和)＋低リスクtimezone窓のみ＝MVP健全。
  - **残る念押し(任意)**: ①Codex制限解除後に別モデルで最終1ラウンド ②ライブDBで「is_finalized付きPOSTが42501拒否」実機確認(出荷前)。M4-2(pooled上限)/L4-1は後続。
  - **経済信頼境界の現状**: is_completed偽装/クエスト捏造/無データ日報酬/無限再孵化/通貨直書き/プレミアム偽装/hatch_count偽装(修正中)を封鎖。残る構造的リスクは**H-2(usage自己申告・480pt上限+anomaly+is_finalized+クエスト固定数で緩和)**のみ。

- ✅ **ASO・ストア掲載文一式(マーケ)** — `docs/ASO.md`。App名=「Moffy - SNS減らして卵を育てる」/ サブ「スマホ時間でかわいいキャラを収集」、キーワード(名前と非重複・約97字)、フル説明文、スクショ6枚コピー(1枚目=「見ない時間が、ごほうびになる」)、リリースノート、運用メモ。**詳細分析(v1.1)は全文言・スクショから除外**、広告削除は控えめ、スクショ内価格表記禁止(2.3.7)、サブスク表記明示(3.1.2)。法務URL3点は`【要記入】`(ユーザー記入＆ホスティング後に差込)。

## 確定価格（法務=特商法/サブスク表記用）
- 月額 ¥480/月(自動更新) / 年額 ¥4,800/年(自動更新・月あたり¥400・約17%OFF) / 7日無料→以後自動更新 / 解約は各ストアの定期購読管理(アプリ内不可) / 期間終了24h前まで未解約で自動更新
- ⬜ **残り** — fn_finalize_dayのクライアント配線+Drift永続化、課金(RevenueCat→entitlements Webhook)、iOS実装、イラストアセット、APK実機ビルド(Android SDK)
- ✅ **課金(RevenueCat)実装** — `lib/core/iap/`(抽象+RevenueCat実装+Noopフォールバック)・`lib/features/paywall/`(5状態,価格はStoreProduct値,トライアルはELIGIBLE時のみ,復元/管理リンク)・導線(メニューCTA/保管枠アップセル)・`docs/IAP_SETUP.md`。キーは--dart-define注入。`dart analyze`緑。**サーバー側TODO**: Webhook→Supabase entitlements反映/`Purchases.logIn`/レビュアーバイパス。**ユーザー突合**: RC商品ID/entitlement/公開SDKキーを既存3アプリと混同せずMoffy実値に(SSOT=pricing.dartのRevenueCatIds)。実購入はサンドボックス実機検証必須
- ✅ **F-01ウォームアップUI配線・色違いシェア(share_plus)・UI磨き** — `warmup_tracker`+`claimWarmupIfNeeded`トリガー+`warmup_celebration`(S1祝福/5状態)、孵化色違いの実シェア(フォールバック付)。CI=**118テスト全パス**・analyze緑
- ✅ **観測(Sentry/PostHog)配線(開発→QA GO→PR#1マージ)** — `lib/core/observability/`に抽象+Noopフォールバック(`analytics`/`crash_reporter`、iapレール同形)。`Env`に`SENTRY_DSN`/`POSTHOG_API_KEY`/`POSTHOG_HOST`(--dart-define)。`main.dart`=`SentryFlutter.init(appRunner:)`ラップ(DSN無→素のrunApp分岐)/PostHogキー有時のみ初期化。`Log.e`→本番時に関数ポインタフックでSentry転送(循環依存回避)。ファネルイベントSSOT(`analytics_events.dart`)。**PII配慮: sendDefaultPii=false・利用分数/確定pt/金額/氏名/メール送信なし・匿名IDのみ**。pkg=`sentry_flutter ^8.9.0`/`posthog_flutter ^4.0.1`(CIのpub getで解決確認済)。`docs/OBSERVABILITY_SETUP.md`。**CI=123テスト緑・analyze No issues**。QAクロスレビュー(Codexハング→Claude-QA代替・限界開示)=GO(条件①PostHog API型②paywall_viewed単発③Stateful化非破壊→いずれもCI緑で確定)。**ユーザー作業=後でDSN/APIキーを--dart-defineで注入**。
  - ✅ **イベント発火 全配線完了** — `day_finalized`/`quest_claimed`もPR#2で有効化(PII安全・カテゴリのみ)。計測完全性確保。
- ✅ **提出前ゲート監査(launch-checklist)実施＋純コード問題2件修正(2026-06-25・CI=123緑)** — クライアントは**ライブSupabase配線済み**(`Supabase*Repository`が`fn_hatch_egg`/`fn_claim_warmup`/`fn_delete_account`/`eggs`等を実呼び出し・`Env.hasSupabase`で切替、モックは未設定時PoCフォールバック)。退会=`fn_delete_account`実配線済(S12)。**修正①**:メニュー法務リンク4点(privacy/terms/特商法/問い合わせ)が`onTap:null`グレーアウト→`url_launcher`で実URL配線(`menu_screen.dart`)。**修正②**:アカウント連携が未実装で「準備中」throwの行き止まり→`kAccountLinkingEnabled`(`feature_flags.dart`,`bool.fromEnvironment`既定false)でv1.0非表示化＋匿名運用(機種変で復元不可)の明示に置換(2.1対策)。再有効化は`--dart-define=ENABLE_ACCOUNT_LINKING=true`。
  - ⬜ **監査の残(ユーザー作業・詳細手順送付済)**: ②ストアにサブスク商品(`moffy_premium_monthly`/`moffy_premium_yearly`/¥480/¥4800/7日無料)→RevenueCat設定(entitlement`premium`/offering`default`/Webhook=既設URL+Authヘッダ=WEBHOOK_AUTH)③公開SDKキー取得④実キーで`--dart-define`ビルド＋ライブDBスモーク(要ビルド可能環境)⑤サンドボックス購入テスト⑥Sentry DSN/PostHog APIキー投入⑦デモアカウント(user_idを渡せば`REVIEWER_APP_USER_IDS`設定)＋審査メモ＋スクショ＋提出時プラポリURL設定。契約Active確認。
- ✅ **RevenueCat Webhook→Supabase entitlements配線(開発→クロスレビュー→PR#2マージ)** — `supabase/functions/revenuecat-webhook/index.ts`(Edge Function/Deno): Authヘッダ定数時間比較・冪等upsert(イベント時刻で後勝ち防止)・レビュアーバイパス(§6-4/H-1修正でexpires_at=null無期限化)・FK/非UUID/空app_user_idガード・service_role RLSバイパス。クライアント: `IapService.logIn`(RC App User ID=Supabase user_id紐づけ)・`serverPremiumProvider`(RLS select-own)・`isPremiumProvider`(表示=server‖client)/`isPremiumConfirmedProvider`(確定ガード=serverのみ・現状未使用は意図的)に分離。`docs/IAP_SETUP.md §6`実装済更新。**クロスレビュー: Codex(別モデル)=GO/セキュリティ脆弱性なし、Claude-QA=GO条件付き→H-1(審査ブロッカー=reviewerバイパス失効無効化)/M-1(init失敗時error伝播)修正済・M-2(確定provider未使用)はコメント明記**。CI=123緑。
  - ✅ **Edge Functionデプロイ＋認証境界ライブ検証完了(2026-06-25)** — `moffy-prod`(ref=`iktpuxgxsaejwtocqnzk`)へデプロイ。URL=`https://iktpuxgxsaejwtocqnzk.functions.supabase.co/revenuecat-webhook`。`REVENUECAT_WEBHOOK_AUTH`設定済(SUPABASE_URL/SERVICE_ROLE_KEYはEdge runtime自動注入=手動不可、IAP_SETUP §6修正済)。本番URLで認証なしPOST=401/偽トークン=401/GET=405を実機確認(fail-closed)。デプロイは別アカウント403回避でPersonal Access Token(`$env:SUPABASE_ACCESS_TOKEN`)経由。
  - ⬜ **残(ユーザー)**: ①RevenueCatダッシュボードでWebhook URL＋Authヘッダ(=REVENUECAT_WEBHOOK_AUTHと完全一致)設定＋商品/entitlement/offering突合(要ASC/Playサブスク商品)②`REVIEWER_APP_USER_IDS`(審査直前・任意)③サンドボックス購入で`entitlements.is_premium`反映確認。
- ✅ **ライブ検証ハーネス=実行済み** — `db-verify.yml`(0001→0005適用+分布+権限)/`db-permission-check.yml`(既存DBへ§3再実行)。Secret `SUPABASE_DB_URL`=Session pooler URI設定済。2026-06-25に両方緑。以後は`gh workflow run "DB Permission Check"`でいつでも権限再監査可
- ⬜ **残(要外部リソース)**: iOS実装(DeviceActivity/ThresholdAchievement・要Mac)・イラストアセット統合(要素材)・APK実機ビルド(Android SDK)・課金ライブ(要RC実値/Webhook)
- ⚠️ 企画要確定: quest_definitionsのseed内容 / 法務URL・mailto宛先 / アカウント連携の出現トリガー

## 並行で回せる未着手ゲート
- **B【法務】** 法務3文書 + Play データ安全性（`PACKAGE_USAGE_STATS`目的明示・S12整合）
- **C【財務】** 価格・IAP設計（¥480/月・年額・ユニットエコノミクス）
- **D【QA】** 設計＋第1パスコードのCodexクロスレビュー

## 意思決定ログ（=新しいものを上に。日付 / 決定 / 理由）
| 日付 | 決定 | 理由 |
|---|---|---|
| 2026-06-30 | 【開発】iOS署名/配布: ASC Adminキー(`SVU9YZ67XQ`)で自動プロビジョニング→署名IPA→**TestFlightアップロード成功**。ビルドは**Xcode 26(iOS26 SDK)必須**(Appleのアップロード要件)＋**sentry_flutter 9.x**(8.xはXcode26非対応)＋CocoaPods。 | Exportのクラウド署名はAdminロール必須(App Manager不可)。AppleがiOS26 SDKビルドを強制(18.5 SDKはvalidation 409)。8.x→9.xはconst廃止等あるが当方使用API(init/captureException(hint)/captureMessage/Hint.withMap)は無改変でCI緑。device_info_plus上書きはXcode26で不要化し撤去 |
| 2026-06-29 | 【CEO/QA】iOS Screen Timeをフル実装→Web検証(high-conf)→Claude-QA独立3観点クロスレビュー(GO_WITH_FIXES)反映→**macOS実コンパイル成功**(既存依存衝突=device_info_plus/sentry SPM/Xcode版/build cycleを解消後)。**シールド(アプリブロック)はしない=報酬型・観測のみ** | iOSは分数取得不可の別設計でMac無し→「実装前にAPI検証・実装後に別観点レビュー・実コンパイルで最終確証」で誤りを潰す(書いた本人が検品しない鉄則)。シールド回避で2つ目の拡張/Entitlement申請を不要に。依存衝突はAndroidに無関係(iOS初ビルドで露呈) |
| 2026-06-29 | 【開発】iOS依存整合: `device_info_plus`を`dependency_overrides`で12.3.0固定＋Flutter SPM無効化(CocoaPods)＋Xcode16固定 | sentry_flutter 8.xはSPM非対応・device_info_plus 12.4.0は新SDK必須で同一Xcode両立不可。shipped済observability/IAPコードを無改変で通す最小チャーン策(sentryメジャー更新を回避) |
| 2026-06-25 | 【CEO】DB=Moffy専用の別Supabaseアカウント。CI接続は**Session pooler(IPv4)**を使う(Direct=IPv6はGitHub Actionsから不可) | 会社プロダクトとして所有分離＋無料枠を別枠確保。pooler選択はCIのIPv4制約への対応 |
| 2026-06-25 | 【CEO/QA】観測配線をmainマージ前にCI緑＋QAクロスレビュー(Codexハング→Claude-QA代替・限界開示)で**条件付きGO→CIで条件確定**してから出荷 | 書いた本人(engineer)以外がレビューする鉄則。パッケージ解決/API整合はCIでしか確定できないため一旦ブランチ→PR→CIで実証 |
| 2026-06-19 | 【CEO】プレミアム詳細分析(曜日/時間帯/SNS別/月次/予測)は**v1.1送り**。MVPプレミアムは**広告削除＋保管枠増加＋限定Mofi＋プレミアム卵**で構成。無料の今日/今週分析はMVPに含む | MVPはコア(収集ループ)に集中。詳細分析は実データが貯まるiOS追従期に価値。課金動機は体験系特典で先行確保 |
| 2026-06-19 | 【企画】S14 ストリーク倍率は**基礎ポイントのみ**に適用（クエスト報酬・ジェム・卵には掛けない） | 報酬全般に倍率が乗ると経済破綻＆プレミアム動機消失。コア行動「毎日削減」だけを増幅 |
| 2026-06-19 | 【企画】S12 退会・データ削除を**アプリ内導線＋アプリ外窓口**で実装、サブスク解約はストア側と明示、30日以内に物理削除 | Apple5.1.1(v)/Google要件で必須。無いと確実リジェクト。法務プラポリと整合 |
| 2026-06-19 | 【企画】S11 日付境界は**ユーザーのローカルTZの0:00**、確定の正は**サーバー時刻＋登録TZ**。7日平均は本日除く直近7日・欠損日除外 | 生活実感とのズレ防止＋改ざん耐性の両立 |
| 2026-06-19 | 【企画】S10 アカウント方式は**匿名認証ファースト→任意で Apple(iOS必須)/Google/メール連携** | サインアップ障壁が最大の離脱点。匿名で即コアループ→価値実感後に連携。機種変リスクは導線＋明示で担保 |
| 2026-06-19 | 【企画】S8 SSOT分離: 利用生データ=端末(Drift)、ポイント・成長・通貨=サーバー(Supabase)。競合は鯖確定値優先だが**減算上書きはしない**、通貨消費はオフライン不可 | ゲーム経済の二重取得/消失を防ぎ、オフライン体験と整合性を両立 |
| 2026-06-19 | 【企画】S13/S5 色違い率=**一律2.0%(1/50)**、抽選順序=卵レア(確定)→Mofiレア(§4確率表)→個体均等→色違い独立判定。MVPは15種×2色=図鑑30 | ポケモン文化準拠の希少性＋シェアの種。4段入れ子抽選を数値で固定し開発の自己流実装を防ぐ |
| 2026-06-19 | 【企画】S4 ポイント上限=**480pt/日**、不正対策はサーバー時刻を日付境界の正とし当日分のみ確定（遡及不可）＋異常値ガード | ゲーム内通貨に実害なく過剰防御不要だが、日付境界=鯖時刻の原則だけは将来のランキング土台として固める |
| 2026-06-19 | 【企画】S1 初日問題は**ウォームアップ方式**: Day1-2は初回ボーナス卵(200/300pt自動付与で孵化保証)、Day3-6は暫定基準、Day7で7日平均確定。基準値下限30分クランプ | 「初日に何も起きない」が最大離脱要因。7日待たせず即コアループ体験。優等生が0ptで詰むのも防ぐ |
| 2026-06-19 | 【企画】S2 削減量マイナス日も**ポイント0止まり・卵成長は減らさない**（ストリークのみ途切れ） | 罰で卵が縮む喪失感は離脱・星1直結。罰より復帰しやすさが継続率を上げる |
| 2026-06-19 | 【企画】S3 ポイント対象は**対象4SNSの合計**（TikTok/Instagram/YouTube/X）。全アプリ合計は不採用、対象カスタマイズはv1.1+ | 全アプリだと地図・仕事まで罰してアプリ主張とズレる。狙ったSNSを減らす体験を明確化 |
| 2026-06-19 | 【企画】S6/S7 育成は**アクティブ1枠にのみ加点**（3枠は切替スロット、成長pt保持）。ジェム無料入手は**ウィークリー/図鑑/ストリークのマイルストーン報酬**に限定（広告報酬なし） | 同時山分けは伝わらない。ジェム希少性を保ちプレミアム動機を維持 |
| 2026-06-19 | 【企画】不足仕様S1〜S14を決め切り **docs/PRD.md** を新規作成（一文定義/コアループ/確定仕様/抽選確率表/受け入れ条件/やらないこと） | デザイン・開発への引き継ぎ仕様。受け入れ条件を満たせば各機能「完成」の定義 |
| 2026-06-19 | iOSのポイントは**段階しきい値で近似**（しきい値は**15/30分起点**の細かい刻み） | 60分起点は粗すぎて削減量の連続性が出ない。15/30分から刻むことで「削減量に応じた加点」を体験的に近似 |
| 2026-06-19 | **Androidファースト**でMVP、iOSは追従（v1.1） | iOSは利用分数を数値取得不可。Androidで正確データを使い経済バランスを先行検証する方が最小リスク |
| 2026-06-19 | ポイント計算を`exact-minutes`(Android)/`threshold-achievement`(iOS)の**2モードで抽象化** | OS差を`UsageProvider`/`PointCalculator`に閉じ込め、iOS追従時の再設計を防ぐ（SSOT原則） |
| 2026-06-19 | iOSの利用時間「表示」は`DeviceActivityReport`、数値抽出のグレー手法は**不採用** | App Group/ネット送信が遮断される正規仕様に従い、審査・将来互換リスクを回避 |
| 2026-06-19 | 技術: Flutter / Riverpod / Feature-First / Supabase / Drift / RevenueCat / Sentry / PostHog | 要件指定 + MVP標準レール（課金・計測・監視・レビュー依頼・法務） |

## リスク / 注視事項
- **iOS Screen Time制約**（最重要）: 分数を数値取得不可。`FamilyControls`配布Entitlementは**Apple承認制** → iOS着手前に早期申請が必要（T1〜T3 / 審査R1）
- **Screen Time系のFlutterプラグインが未成熟**: `DeviceActivityMonitor`/`Report`拡張はSwift自作（App Extensionは Flutter不可）
- **経済バランスが机上値**: 基準180分・成長100/250/500pt・ストリーク×2.0・ドロップ率は仮。Androidで実数値検証して調整
- **審査**: 抽選確率の開示義務(3.1.1) / サブスク表示(3.1.2) / 退会・削除導線(5.1.1) / プライバシー申告一致(5.1) / 日本課金の特商法
- **実機PoC未実施**: `UsageStatsManager`の取得精度・対象4アプリの実パッケージ名は机上のまま。経済値(基準/抽選/480pt/30分クランプ)確定前に実機実測が必要
- **`PACKAGE_USAGE_STATS`は機微権限**: Playデータ安全性フォーム＋プラポリで利用目的の明示が必要（法務と整合）
- **サーバーRPCは未実装**: `fn_finalize_day`/`fn_hatch_egg`等はシグネチャのみ。コア経済の心臓部、実装後に確率分布の単体テスト検証必須

## 数字メモ（=分かる範囲で。未計測は「未計測」と書く）
- DAU / 主要ファネル通過率 / 課金 CVR / クラッシュ率 / 月次コスト: **すべて未計測（開発前）**

## 次のマイルストーン
- 目標日: 未定 / 内容: **Androidでコアループ実機デモ**（利用時間取得 → ポイント → 卵成長 → 孵化 → 図鑑登録）

## 運用ルール
- **`spawn_task`禁止**: 各部署エージェントは、本ORG_STATEで追跡中の作業を`spawn_task`（背景タスクチップ）で起票しないこと。後続作業は「コア開発の残り」へ追記し、このセッションで一本化管理する（派生セッション乱立の防止）。
- **作業所有権**: fn_finalize_dayのクライアント配線・孵化のクライアント↔サーバー契約は本orgセッションが所有（2026-06-22 ユーザー合意で一本化）。

## アカウント / 前提
- App Store Connect / Google Play Console: **法人名義で取得済み**（=Playbook Phase 1の契約・アカウントは前倒し完了）
- ASC操作はASC MCP（`asc-mcp/`）を使用 → 初期設定 `node asc-mcp/merge-settings.cjs` 後にClaude Code再起動で有効化（iOS/v1.1段で。⚠️asc-mcpはSA鍵直書きの注意あり）
- **Google Play操作=`gpc-mcp/`(ドロップイン型MCP/Android Publisher API v3)＝2026-06-26有効化済み**。サブスク/オファー/商品/レビュー操作。鍵はパス渡し(secure)。QA=GO(セキュリティ健全)。
  - **有効化完了**: `merge-settings.cjs`実行で`.claude/gpc/`配置＋npm install済、`.claude/settings.local.json`の`mcpServers['google-play']`登録済(env: `GOOGLE_PLAY_SA_JSON_PATH=C:\Users\user\secrets\moffy-play-sa.json` / `GOOGLE_PLAY_PACKAGE_NAME=com.moffy.app`)。
  - 鍵=**TSUZURU既存SA `tsuzuru-play-publisher@tsuzuru-497609`を再利用**(Desktop`TSUZURUキー系\tsuzuru-play-service-account.json`を`C:\Users\user\secrets\moffy-play-sa.json`へコピー=リポジトリ外)。**事前検証OK**: 認証成功＋Moffyサブスク一覧GET=HTTP204(権限エラー無し・商品ゼロ=クリーン)。
  - **実API検証(2026-06-26・直接スクリプトで)＝書き込み形状/権限が判明**: ①MCPサーバ単体は正常(handshake→9ツール応答確認)だが**Claude CodeがセッションでMCP未ロード**(再起動/承認の反映問題)→ブロック回避のため**認証済みAPIを直接叩く方式で進行中**。②サブスク作成は`regionsVersion.version=2022/01`を**クエリ必須**(body不可)→`gpc_create_subscription`に既定付与する修正をpush済(コミット履歴)＋`.claude/gpc/`ランタイムコピーも更新。③**書き込みは「ストアでの表示の管理(Manage store presence)」権限が必須**=現SAは読み取り専用で作成が**403 PERMISSION_DENIED**(「注文と定期購入の管理」だけでは不足)。
  - **🔴 現在のブロッカー(ユーザー作業)**: Play Console→ユーザーと権限→SA `tsuzuru-play-publisher@tsuzuru-497609`→アプリ権限にMoffy(com.moffy.app)含める＋**「ストアでの表示の管理」をON**→適用。反映後に書き込み403が解消。
  - **▶ 権限付与後の一手(私が直接スクリプトで実行可・再起動不要)**: 作成再テスト→OKなら本番作成: `moffy_premium_monthly`(¥480/P1M)・`moffy_premium_yearly`(¥4800/P1Y)＋基本プラン(JP/`price{currencyCode:JPY,units:"480",nanos:0}`)＋7日トライアルoffer(P7D/free)→`:activate`で有効化。価格・地域・regionsVersion=`2022/01`。

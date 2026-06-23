# ORG_STATE（=組織の状態ファイル / Moffy）

> プロジェクトルートの単一の状態置き場。AI 8 部署がセッションを跨いで「いま何をしているか」を思い出すための場所。
> `/app-dev-org:kickoff` が作成し、`/app-dev-org:weekly-brief` と各部署が更新する。

## プロダクト概要
- **一文定義**: 「SNSを見すぎてしまう18〜35歳」が「スマホ時間を減らせない課題」を「削減した時間でかわいいキャラ(Mofi)が育つ収集ゲーム化」で解決する
- **配信先**: **Androidファースト → iOS追従**（=決定理由: iOSは利用分数を数値取得できず、Androidは`UsageStatsManager`で正確取得できるため、コア経済をAndroidで実数値検証してからiOSへ移植）
- **収益モデル**: 無料 + プレミアムサブスク（=¥480/月想定。限定Mofi・プレミアム卵・詳細分析・広告削除・保管枠増加）

## 現フェーズ
- [x] アイデア検証 → [x] 設計 → [ ] コア開発 ←**いまここ（第1パス完了）** → [ ] 課金・認証 → [ ] テスト → [ ] 提出準備 → [ ] 審査中 → [ ] 公開済み（=運用）

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
- 🔴 **ライブ未検証** — Supabaseプロジェクト不在のためSQL未実行。要: SupabaseプロジェクトでDB push→権限確認→分布検証
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
- ✅ **CI構築・検証ギャップ解消** — git初期化→**private GitHub repo `lanlangh/moffy`** へpush。`.github/workflows/ci.yml`(ubuntu, Flutter 3.44.2)で `pub get`/`analyze`/`test` を自動実行。**CI実行=analyze No issues + テスト89件全パス**(F-01〜F-04修正の追加テスト含む)。以後ローカルWDACに依存せずクラウドで緑を担保。コード生成は未使用のためbuild_runner不要。
- 🟦 **残るライブ検証** — SQL経済(0001〜0003)の実行・`distribution_check`(§4分布)・統合テスト(孵化/受取/退会/同時操作)は**要Supabaseプロジェクト**。QAのGOはここまで通って確定。
- ✅ **価格・IAP設計(財務)** — `docs/PRICING.md`・`lib/core/constants/pricing.dart`(SSOT)。**月額¥480 / 年額¥4,800(約17%OFF,おすすめ) / 7日無料トライアル**。無料↔プレミアム境界=保管枠20↔200・広告無料のみ・限定Mofi/プレミアム卵はプレミアム・育成3枠はプラン非依存・詳細分析v1.1(課金画面で宣伝しない)。RevenueCat: offering`default`→monthly/annual→entitlement`premium`(サーバー検証が正)。Apple小規模事業者プログラム(30→15%)はlaunch前申請。`dart analyze`緑

## 確定価格（法務=特商法/サブスク表記用）
- 月額 ¥480/月(自動更新) / 年額 ¥4,800/年(自動更新・月あたり¥400・約17%OFF) / 7日無料→以後自動更新 / 解約は各ストアの定期購読管理(アプリ内不可) / 期間終了24h前まで未解約で自動更新
- ⬜ **残り** — fn_finalize_dayのクライアント配線+Drift永続化、課金(RevenueCat→entitlements Webhook)、iOS実装、イラストアセット、APK実機ビルド(Android SDK)
- ⬜ 課金(RevenueCat)・iOS実装(DeviceActivity/ThresholdAchievement)・イラストアセット供給・APK実機ビルド(Android SDK)
- ⚠️ 企画要確定: quest_definitionsのseed内容 / 法務URL・mailto宛先 / アカウント連携の出現トリガー

## 並行で回せる未着手ゲート
- **B【法務】** 法務3文書 + Play データ安全性（`PACKAGE_USAGE_STATS`目的明示・S12整合）
- **C【財務】** 価格・IAP設計（¥480/月・年額・ユニットエコノミクス）
- **D【QA】** 設計＋第1パスコードのCodexクロスレビュー

## 意思決定ログ（=新しいものを上に。日付 / 決定 / 理由）
| 日付 | 決定 | 理由 |
|---|---|---|
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
- ASC操作はASC MCP（`asc-mcp/`）を使用 → 初期設定 `node asc-mcp/merge-settings.cjs` 後にClaude Code再起動で有効化

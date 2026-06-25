# ORG_STATE（=組織の状態ファイル / Moffy）

> プロジェクトルートの単一の状態置き場。AI 8 部署がセッションを跨いで「いま何をしているか」を思い出すための場所。
> `/app-dev-org:kickoff` が作成し、`/app-dev-org:weekly-brief` と各部署が更新する。

## ▶ RESUME / 現在地（2026-06-25・/clear後はここから読む）
- **進捗**: MVPクライアント一式＋経済バックエンド(`supabase/migrations/0001〜0005`)完成。**CI=123テスト緑**(GitHub Actions)。経済セキュリティは**5ラウンドのクロスレビューで収束＝GO**(C-1/C-2/C-3/H-1/H4-1/G-1〜3/M-2/M4-1封鎖済、残H-2は受容)。**🟢ライブDB検証完了**: Supabase本番(`moffy-prod`/Tokyo/別アカウント)に`0001〜0005`適用＋抽選分布(§4)全PASS＋§3権限グリッド/列GRANT/H4-1ランタイム実証 全PASS(2026-06-25)。価格(`pricing.dart`)・法務(`docs/legal/`)・ASO(`docs/ASO.md`)・オーナー手順書あり。**観測(Sentry/PostHog)配線=完了**(PR#1)。**RevenueCat Webhook→entitlements配線=完了**(PR#2・Edge Function＋クライアント合成server権威・Codex(別モデル)+Claude-QAクロスレビューGO)。**CI=123テスト緑・analyze No issues**。
- **次の一手**: ✅RevenueCat Webhook実装完了(PR#2マージ・CI緑・Codex+QAクロスレビューGO)。残り→①**【ユーザー】Edge Functionデプロイ＋RevenueCatダッシュボードWebhook設定＋商品ID/キー突合**(`docs/IAP_SETUP.md §6`手順)②**【ユーザー】法務文書記入→公開→URL反映**(審査ブロッカー)③アプリ実接続スモーク(SUPABASE_URL/anon keyをdart-define・要実機/エミュ)④Apple小規模事業者プログラム申請/有料App契約Active確認⑤iOS実装(v1.1)。
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
  - ✅ **公開用クリーン化完了** — 公開3文書(privacy/terms/tokushoho)から内部注記/AI免責を除去、最終更新日=2026年6月25日。`docs/legal/README.md`に内部リマインダ保全。`STORE_DATA_SAFETY.md`は内部用。**Notion公開ページ方式(TSUZURUと同一)でそのまま貼れる状態**。
  - ⬜ **残(ユーザー→開発)**: ①ユーザーがNotionで3ページ公開→URL取得 ②開発が`legal_links.dart`の`moffy.example.com`を実URLに差替＋`docs/ASO.md`＋ストアのプラポリURL欄(完全一致) ③法人番号(任意)。

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
- ASC操作はASC MCP（`asc-mcp/`）を使用 → 初期設定 `node asc-mcp/merge-settings.cjs` 後にClaude Code再起動で有効化

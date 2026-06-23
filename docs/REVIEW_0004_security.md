# レビュー: 0004_security_hardening.sql（独立QAレビュー）

- 対象: `supabase/migrations/0004_security_hardening.sql`
- 横断確認: `0001_init.sql`（RLS全体） / `0002_economy_rpcs.sql` / `0003_warmup_grants.sql` / クライアント `lib/features/*/data/*_repository.dart`
- レビュアー: QA部署（qa-reviewer）/ 実装者とは別コンテキスト
- 日付: 2026-06-23
- 結論先出し: **GO（条件付き）**。新規 Critical=0 / High=0。通貨・プレミアム・図鑑・他人データの偽装/取得経路は **塞がれている**。下記 Medium/Low は v1.1 で対応推奨。

---

## ⚠ 限界開示（Claude-QA 代替レビューについて）

本レビューは、本来「実装した本人とは別のAIモデル（Codex）」が第三者レビューを行う運用（`docs/cross-review-protocol.md` の相互レビュー鉄則）に従うべきところ、**Codexヘッドレス実行が不安定なため、同一モデル系列（Claude）の別コンテキスト（QA部署）で代替**したものである。

この代替には以下の構造的限界があり、CEOは認識した上で判断されたい：
- **モデル多様性が無い**: 実装者と同系列モデルのため、同じ盲点（例: PostgreSQL 権限モデルの特定の思い込み）を共有している可能性が残る。
- **ライブDBでの実証が無い**: 本プロジェクトはライブDB未接続（`docs/BACKEND_SETUP.md` / 各SQL冒頭「未実行」）。本レビューの「攻撃可否」判定は **SQL/RLS仕様とPostgREST挙動の静的推論**であり、実際に `authenticated` ロールでPostgRESTを直叩きした実証ではない。
- **推奨**: 出荷後の最優先で、ステージング環境に `anon`/`authenticated` キーで接続し、本レビュー末尾の「実証テストケース」を実機/cURLで1回流すこと（静的レビューの裏取り）。

---

## 検証観点ごとの判定

### G-1: baselines の RLS（select-own のみ・書込ポリシー無し） — ✅ 妥当（真）

- `alter table public.baselines enable row level security;`（0004 L47）で 0001 の積み残し（RLS未有効）を解消。
- `baselines_select_own`（L50-51）は `using (auth.uid() = user_id)`。他人の行は select 不可。**真**。
- 書込ポリシー（insert/update/delete）は意図的に未作成 → RLS有効＋ポリシー不在 ⇒ `authenticated` からの直接書込みは一切不可。**真**。
- 書込みは `fn_finalize_day`（definer / 所有者postgres / RLSバイパス）の upsert（0002 L279-286）のみ。`force row level security` 未使用（横断grep済み: 0004コメント以外にヒット無し）のため definer は引き続き書ける。**整合は真**。
- 攻撃可否: 他人の基準値の読取・自分/他人の基準値改ざん いずれも **不可**。

> 補足（情報）: 0001 で baselines だけ RLS が抜けていたのは事実で、これが本マイグレーションの主要な穴埋め。0004 適用前は「他人の基準値が読めた（情報漏洩）」状態だったので、0004 は確実に適用すべき。

### G-2: profiles 列レベルUPDATE（display_name, timezone のみ） — ✅ 妥当（真）

- `revoke update on public.profiles from authenticated;`（L74）→ `grant update (display_name, timezone) ...`（L75）。
- 結果、`authenticated` が直接UPDATEできる列は `display_name, timezone` のみ。`gem_balance / point_balance / pooled_points / deleted_at / is_linked / id / created_at / updated_at` は **直接UPDATE不可**。**真**。
- RLS `profiles_update_own`（0001 L415 / 0003で `deleted_at is null` 追加）との二重防御も維持。行所有（どの行）×列GRANT（どの列）は直交。**真**。
- definer整合: 通貨を書く `fn_finalize_day`（point_balance L310-312）/ `fn_grant_quest_reward`（point_balance L694, gem_balance L705）/ `fn_spend_currency`（L789,L800）/ `fn_apply_growth`（pooled_points L442-444）/ `fn_claim_warmup`（point_balance）/ `fn_delete_account`（deleted_at L842）は所有者権限のため列GRANTの影響を受けず継続。**真**。
- クライアント実態: `lib/features/profile/*` はMockのみ（書込み無し）。通貨列の直接書込みコードはリポジトリ全体に存在しない（grep確認: home_repository は `select` のみ L133-134）。**規約違反コードも無い**。
- 攻撃可否（通貨/ジェム偽装）: PostgREST で `PATCH /profiles?id=eq.<self>` に `gem_balance` 等を載せても、列GRANT不在で **権限エラー（42501）で拒否**。**封鎖されている**。

### G-3: eggs 列レベルUPDATE（slot_index, location, is_active のみ） — ✅ 妥当（真）。ただし注意点1件（下記 M-1）

- `revoke update on public.eggs from authenticated;`（L96）→ `grant update (slot_index, location, is_active) ...`（L97）。
- `growth_points / hatched_into / rarity / acquired_source / id / user_id / created_at / updated_at` は **直接UPDATE不可**。即孵化チート（growth_points を 500 に直書き）/ 孵化結果偽装（hatched_into 差し替え）/ レアリティ詐称は **封鎖**。**真**。
- definer整合: `fn_apply_growth`（growth_points L433-435）/ `fn_hatch_egg`（location/is_active/slot_index/hatched_into L587-592）は所有者権限で継続。**真**。
- クライアント実態（`lib/features/eggs/data/egg_repository.dart`）:
  - `setActiveEgg`（L259-263）: `is_active` のみ更新 → 許可列内。OK。
  - `moveToStorage`（L268-272）: `location, is_active, slot_index` → 許可列内。OK。
  - `moveToIncubator`（L280-283）: `location, slot_index` → 許可列内。OK。
  - 既存クライアント機能は 0004 適用後も全て動作する。**回帰リスク無し**。
- 攻撃可否（即孵化/レア詐称）: `PATCH /eggs` に `growth_points=500` を載せても権限エラーで拒否。**封鎖**。

### definer整合 / force RLS — ✅ 妥当（真）

- `force row level security` は 0001〜0004 のいずれにも未使用（横断grep済み）。テーブル所有者（postgres）は RLS バイパス。
- 列GRANTは「ロール権限」、definer関数は所有者権限で実行されGRANT対象外 ⇒ RPCは全列書込み継続。**設計コメント（0004 L18-34）は正確**。

### 全テーブル横断（14テーブルのRLS / 書込み穴） — ✅ 概ね妥当

0001 の14テーブルすべてで `enable row level security` 済み（baselines は 0004 で補完）。クライアントが偽装・他人データ取得できる経路を観点別に確認：

| 観点 | 経路 | 判定 |
|---|---|---|
| (a) 通貨/ジェム偽装 | profiles 列GRANT（G-2）+ point_ledger 書込ポリシー無し（0001 L437-439） | **封鎖** |
| (b) entitlements（プレミアム）偽装 | entitlements は select-own のみ・insert/update ポリシー無し（0001 L472-475）。0004 は触っていないが元から書込み不可。`is_premium` をクライアントから一切書けない | **封鎖** |
| (c) 図鑑（mofi_collection）偽装 | select-own のみ・書込ポリシー無し（0001 L453-455）。登録は `fn_hatch_egg`（definer）のみ | **封鎖** |
| (d) 他人データ読取 | 全 user テーブルが `using (auth.uid() = user_id/id)`。`using(true)` は master 4テーブル（mofi_species/drop_tables/app_config/quest_definitions）の **select 専用**であり書込みには付いていない（0001 L398-401） | **封鎖** |
| (e) point_ledger 改ざん | 書込ポリシー無し（0001 L437-439）。加算は definer RPC の冪等キーのみ | **封鎖** |

- `using(true)` の誤適用チェック: master 4テーブルの `for select using(true)` のみ。**書込みに `using(true)` が付いた箇所は無い**。**真**。

### 冪等性（0004 再適用） — ✅ 妥当（真）

- `enable row level security`: 既に有効でも無害（再実行安全）。
- `drop policy if exists` → `create policy`（baselines_select_own）: 再適用安全。
- `revoke update ... from authenticated` / `grant update (cols) ...`: 現在の権限状態に収束。再実行安全。**真**。
- 適用順依存: 0004 は `profiles` / `eggs` / `baselines` が存在する前提（0001 後）。マイグレーション順序で担保。問題なし。

### 残存リスク — usage_daily 自己申告（既知・スコープ外）＋新規1件

- usage_daily 自己申告は既知（0004 L99-114 で明記）。1日上限480pt + is_anomaly で被害局限。スコープ外として **同意**。
- ただし、これに付随する **新規の見落とし1件（M-1）** を検出。下記参照。

---

## 指摘一覧

### M-1（Medium / 真）: usage_daily の INSERT 経路は列制限が無く、`is_finalized=true` / `is_anomaly` をクライアントが自己申告できる

- **対象**: `usage_daily`（0001 L428-433 RLS insert/update） / クライアント `lib/core/sync/usage_sync_repository.dart` L44-47, `lib/core/sync/finalize_models.dart` L70-84
- **根拠**:
  - 0004 は `profiles` と `eggs` の **UPDATE** にのみ列GRANTを掛けた。`usage_daily` には列制限を **掛けていない**（スコープ外）。
  - `usage_insert_own`（0001 L428-429）は `with check (auth.uid() = user_id)` のみ＝列の絞り無し。クライアントは INSERT 時に `is_finalized` / `is_anomaly` / `total_minutes` を任意値で入れられる。実際 `toUsageRow()`（finalize_models.dart L70-84）は `is_anomaly` をクライアントが組み立てて送っている。
  - PostgREST で `POST /usage_daily` に `{total_minutes:0, is_anomaly:false, is_finalized:true}` を投げると、INSERT は通る（列GRANTで `revoke insert` していない / RLSは本人行なら許可）。
- **PostgRESTでの攻撃可否（静的推論）**:
  - `is_finalized=true` を自己申告で先に立てても、**実害は限定的**。`fn_finalize_day`（definer / RLSバイパス）は `usage_daily` を `for update` で読み、anomaly を **サーバ側の格納値** から再判定し、最後に `is_finalized=true` を強制UPDATE（0002 L317-319）。確定計算は基準値（過去日の平均）に基づくため、`is_finalized` の事前詐称だけでは通貨は増えない。
  - 真の残存リスクは **`total_minutes` の過少申告**（=削減を多く見せる）であり、これは 0004 L99-114 で明記済みの「自己申告問題」そのもの。**新しい通貨偽装経路ではない**（上限480pt + anomalyで局限）。
  - `is_anomaly` をクライアントが `false` に固定して異常値ガードを回避しようとしても、`fn_finalize_day` は格納された `is_anomaly` を信頼する設計のため、**端末が anomaly 判定を出さない＝サーバの異常値破棄が効かない** という構造的弱点が残る（端末が1440分超を `is_anomaly=false, total_minutes=1` と詐称しても、結局 total_minutes 過少申告と同じ枠で480cap内）。
- **重大度判断**: 通貨偽装の上限が日480ptで頭打ちのため **Medium**（Criticalではない）。0004の「自己申告はスコープ外」という整理と矛盾しない。
- **修正提案（v1.1）**: (1) `revoke insert on usage_daily from authenticated; grant insert (user_id, usage_date, total_minutes, per_app_minutes, source_mode) to authenticated;` として `is_finalized` / `is_anomaly` をクライアント INSERT から外し、**サーバ（fn_finalize_day / トリガ）が anomaly を独立判定**する。(2) anomaly 判定をクライアント任せにせず、`fn_finalize_day` 内で `total_minutes > 1440` を再チェックして破棄する。
- **真偽**: **真**（ただし被害は既知の自己申告問題の範囲内で、新規Critical/Highではない）。

### L-1（Low / 真）: profiles INSERT 経路も列制限が無く、初期行に通貨初期値を載せられる

- **対象**: `profiles`（0001 L410-411 `profiles_insert_own`）
- **根拠**: 0004 は profiles の **UPDATE** のみ列制限。INSERT（匿名認証直後の初期行作成）には列GRANTが無いため、クライアントが `POST /profiles` で `{id:<self>, gem_balance:99999}` を入れられる余地がある。
- **攻撃可否（静的推論）**: 初期行は通常サーバ/トリガ側で作る想定だが、本リポジトリでは profiles の作成コードが見当たらず（profile_repository は Mock のみ）、**誰が初期行を作るか未確定**。もしクライアント INSERT に依存しているなら、初回のみ通貨を盛れる（その後は G-2 のUPDATE制限で増やせないが、初期値詐称は通る）。
- **重大度**: 初回1回限り＆実装が未確定のため **Low**。要・実装方針の確認。
- **修正提案**: 初期行作成を `auth.users` への signup トリガ（definer）に寄せるか、INSERT も列GRANT（`grant insert (id, display_name, timezone) to authenticated`）で通貨列を外す。
- **真偽**: **真**（ただし前提条件付き＝クライアントINSERTに依存している場合のみ顕在化）。

### L-2（Low / 情報）: tracked_apps / user_quests の本人書込みは設計通りだが、列制限が無い

- **対象**: `tracked_apps`（0001 L420-421 `for all`） / `user_quests`（0001 L461-464 insert/update own）
- **根拠**: user_quests は `is_completed` / `progress` / `reward_granted` を本人がUPDATEできる（列制限無し）。`reward_granted` を本人で `true` にしても、`fn_grant_quest_reward` は `for update` でフラグを見て二重付与を弾く（0002 L659-663）ため、**むしろ `reward_granted=true` を自分で立てると報酬が貰えなくなる**だけで、通貨偽装には繋がらない。`is_completed=true` 詐称も、報酬付与は definer RPC が `quest_definitions.reward` から固定額を読むため、進捗詐称で通貨は増えない（クエスト報酬の固定額をタダ取りできるかは条件判定ロジック次第＝0002のクエスト達成判定の堅牢性に依存）。
- **重大度**: **Low/情報**。0004 のスコープ外。ただし「`is_completed` 自己申告 → 固定報酬タダ取り」は別途要検証（達成条件のサーバ検証が `fn_grant_quest_reward` に無く、`is_completed` を信頼している点）。
- **修正提案（v1.1検討）**: `fn_grant_quest_reward` 内で `quest_definitions.condition` と実績（usage_daily等）を突き合わせて `is_completed` をサーバ再判定する。または user_quests の `is_completed`/`reward_granted` をクライアントUPDATE許可列から外す。
- **真偽**: **真（情報）**。0004 そのものの欠陥ではなく、0004 が触らなかった領域の既存リスク。

### I-1（情報 / 偽 → 棄却）: 「列GRACEで definer が書けなくなるのでは」という懸念

- 一部レビューで出がちな「列レベルGRANTを掛けると security definer 関数も該当列を書けなくなるのでは」という指摘は **偽**。definer 関数は所有者（postgres）権限で実行され、GRANT/REVOKE は所有者に適用されない。`force row level security` も未使用。実コード上 `fn_finalize_day` 等が point_balance/growth_points を更新する経路は維持される。**棄却**（0004 の設計通り）。

---

## 総合判定

- **新規 Critical**: 0
- **新規 High**: 0
- **Medium**: 1（M-1: usage_daily INSERT 列無制限 → 既知の自己申告問題の範囲内）
- **Low**: 2（L-1 profiles INSERT 列無制限 / L-2 user_quests 自己申告）
- **情報/棄却**: 1（I-1）

### クライアントによる偽装/取得の残存経路（最終確認）
- 通貨/ジェム偽装: **不可**（G-2 + ledger書込不可）
- プレミアム（entitlements）偽装: **不可**（select-own のみ・書込ポリシー皆無）
- 図鑑（mofi_collection）偽装: **不可**（select-own のみ・書込はdefiner孵化のみ）
- 他人データ読取: **不可**（全 user テーブル auth.uid() 一致 / `using(true)` は master select 専用）
- point_ledger 改ざん: **不可**
- 残る自己申告経路（M-1/L-2）は **日480pt上限 + anomaly + 固定報酬** で被害局限。新規の通貨膨張経路ではない。

### GO / NO-GO

**GO（条件付き）** — 0004 は G-1/G-2/G-3 の目的を正しく達成し、課金通貨・プレミアム・図鑑・他人データの偽装/取得を物理的に封鎖した。冪等性・definer整合も妥当。新規 Critical/High は 0。

**差し戻しリスト（出荷を止めない / v1.1 で対応）**:
1. （M-1）`usage_daily` の INSERT を列GRANTで絞り（`is_finalized`/`is_anomaly` をクライアントから外す）、anomaly をサーバ独立判定にする。
2. （L-1）profiles 初期行作成の責務を確定し、クライアントINSERT依存なら INSERT も列GRANTで通貨列を除外、または signup トリガへ移管。
3. （L-2）`fn_grant_quest_reward` のクエスト達成（`is_completed`）サーバ再検証、または user_quests のクライアントUPDATE許可列の絞り込み。
4. （限界開示）出荷後最優先で、ステージングで `authenticated` キーによる PostgREST 直叩き実証（下記テストケース）を1回流し、本静的レビューを裏取りする。

### 実証テストケース（ステージングで cURL / supabase-js）
- T1: `PATCH /rest/v1/profiles?id=eq.<self>` body `{"gem_balance":99999}` → **42501 で拒否されること**。
- T2: `PATCH /rest/v1/eggs?id=eq.<own_egg>` body `{"growth_points":500}` → **42501 で拒否されること**。
- T3: `GET /rest/v1/baselines?user_id=eq.<other_uid>` → **0件（他人行が返らないこと）**。
- T4: `PATCH /rest/v1/entitlements?user_id=eq.<self>` body `{"is_premium":true}` → **拒否（更新0件 or 権限エラー）**。
- T5: `POST /rest/v1/usage_daily` body `{...,"is_finalized":true,"is_anomaly":false}` → 通るが、`fn_finalize_day` 後の通貨が `total_minutes` 過少申告分（≤480pt）に収まること（M-1の被害局限確認）。

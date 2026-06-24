# REVIEW_round5_economy — Moffy 経済信頼境界 第5巡クロスレビュー（確認ラウンド）

- 対象: `supabase/migrations/0001`〜`0005` + クライアント（`lib/core/sync/*` / `lib/features/home/data/*` / `lib/features/quests/data/*`）
- 日付: 2026-06-24
- レビュアー: QA部署（qa-reviewer）
- 直近修正の検証対象: **H4-1 / M4-1**（`0004` G-4 列GRANT + `0005` fn_finalize_day の is_anomaly サーバー算出化 + `finalize_models.dart` の toUsageRow から is_anomaly 除去）
- 過去ラウンドのクローズ済み: C-1 / H-1 / C-2 / M-2 / C-3 / H4-1（本ラウンドで確認）/ M4-1（本ラウンドで確認）

---

## ⚠ レビュー体制の限界開示（必読）

本来このプロジェクトのクロスレビューは **「実装者とは別のAIモデル」（Codex / gpt-5.x）** が行う鉄則。
しかし今回も **Codex が外部利用の制限に当たり使用不可** のため、**Claude（QA）自身が
第三者レビュー役を代替**している（実装者とは別コンテキスト）。

つまり本レビューは「**モデル多様性のない自己同型レビュー**」であり、別モデルなら気付く
盲点を構造的に見落とすリスクが残る。これを補うため、本ラウンドも **攻撃者（ペンテスター）
になりきって、列GRANT 適用後に新たに生じうる偽造経路を能動的に探索**する方針で実施した。
それでもなお「別モデルによる再確認が望ましい」という限界は残ることを、判定の前提として
CEO に明示する。

---

## サマリ

| 項目 | 結果 |
|---|---|
| H4-1（is_finalized クライアント直書き）は CLOSED か | **CLOSED（確定）** |
| M4-1（is_anomaly 改ざんで異常値ガード回避）は CLOSED か | **CLOSED（確定）** |
| 新規 Critical | **0 件（無し）** |
| 新規 High | **0 件（無し）** |
| 新規 Medium | **0 件（無し）** ※ M4-2 は round4 既出の後続スコープで再掲のみ |
| 新規 Low | **1 件**（L5-1: `usage_update_own_unfinalized` の with check に is_finalized 制約が無い＝多層防御の片肺。実害なし） |
| MVPローンチに経済信頼境界は健全か（H-2 自己申告・低リスク timezone を除く） | **GO（収束）** |

**収束宣言**: 本ラウンドで新規 Critical/High は **0 件**。過去ラウンドで毎回出ていた
経済信頼境界の突破経路（C-1→H-1→C-2/M-2→C-3→H4-1）は、H4-1/M4-1 のクローズをもって
**収束した**と判定する。

---

## 1. H4-1 クローズ確認（最優先）

### 修正内容の突合

`0004_security_hardening.sql` G-4（L149-153）:
```sql
revoke insert, update on public.usage_daily from authenticated;
grant insert (user_id, usage_date, total_minutes, per_app_minutes, source_mode)
  on public.usage_daily to authenticated;
grant update (total_minutes, per_app_minutes, source_mode)
  on public.usage_daily to authenticated;
```
→ `is_finalized` / `is_anomaly` / `id` / `created_at` / `updated_at` は **GRANT されていない**。

### 攻撃再現の机上検証（round4 H4-1 の攻撃を再実行）

```
POST /rest/v1/usage_daily
{ "usage_date":"2026-06-24", "total_minutes":0,
  "per_app_minutes":{...}, "source_mode":"exact-minutes",
  "is_finalized":true, "is_anomaly":false }
```
- PostgreSQL の **列レベル INSERT 権限**は、GRANT されていない列を INSERT 文で**明示指定**すると
  `42501 (insufficient_privilege)` を返し、**INSERT 文全体が失敗**する（default が当たるのは
  「列を省略した場合」のみ）。
- したがって攻撃者が `is_finalized:true` を送った時点で **INSERT は拒否**される。
  `is_finalized=true` の usage_daily 行を直接作る経路は**物理的に塞がれた**。
- `is_finalized` を省略して INSERT した場合 → default `false` が当たり、`quest_condition_met`
  の `app_under` / `reduce_total` は `is_finalized is not true` で **未達（false）に倒れる**
  ＝ fail-closed が成立。

### 既存同期が壊れないことの確認

- `finalize_models.dart` の `toUsageRow()`（L81-86）は **生データ4列のみ**（usage_date /
  total_minutes / per_app_minutes / source_mode）を返す。`is_anomaly` は除去済み（L33-38 の
  ドキュメントコメントと整合）。
- `usage_sync_repository.dart` L44-47 の upsert は `{'user_id': uid, ...draft.toUsageRow()}`
  ＝ INSERT 許可列（user_id 含む5列）にちょうど収まる。**GRANT 範囲内なので従来の提出は通る**。
- upsert が確定済み行（`is_finalized=true`）に当たって UPDATE になる場合 → RLS
  `usage_update_own_unfinalized`（`using is_finalized=false`）で対象外となり更新されないが、
  続く `fn_finalize_day` が冪等（`already_finalized`）なので **二重確定も例外も起きない**（L43-47
  のコメントどおり）。機能・安全とも問題なし。

### definer 経路の継続

`fn_finalize_day`（0005 / security definer / 所有者権限）は列GRANTの対象外。
`is_finalized=true` 化（L936-939）も継続可能。**RLS / 列GRANT はクライアントのみを縛り、
definer は全列書込み継続**（0004 L18-35 の整合説明と一致）。

**判定: H4-1 は CLOSED（確定）。**

---

## 2. M4-1 クローズ確認 + anomaly 新ロジック検証

### 修正内容の突合

`0005` fn_finalize_day（L829-838）:
```sql
v_minutes_max := public.cfg_int('daily_minutes_max', 1440);  -- SSOT
v_is_anomaly := (v_today_minutes > v_minutes_max);
if v_is_anomaly then
  update public.usage_daily set is_anomaly = true where ... ;
  return jsonb_build_object('finalized', false, 'reason', 'anomaly');
end if;
```
- `daily_minutes_max=1440` を `app_config` に seed（L753-756 / `on conflict do nothing` で冪等）。
- anomaly はもはやクライアント申告を読まない。**サーバーが total_minutes から算出**して
  definer 権限で `is_anomaly` を書く。`is_anomaly` はクライアント書込不可（G-4）。

→ round4 M4-1 の攻撃（高利用日を `is_anomaly=true` で提出して基準値分母から除外し baseline を
高止まりさせる）は、**クライアントが is_anomaly を書けない**ため成立しない。**CLOSED（確定）**。

### anomaly 新ロジックの境界・正当性検証

1. **境界値**: 判定は `total_minutes > 1440`（厳密 `>`）。`total_minutes = 1440`（ちょうど24h）は
   anomaly **ではない**＝確定対象。物理的に 1440 分（24時間ピッタリ）は理論上ありうる端値であり、
   `>` で「24h を超える物理的不可能値」のみ弾く設計は**妥当**。`total_minutes` は 0001 の
   CHECK（`>= 0`）で下限保証。負値は入らない。
2. **早期 return パスの正当性**: anomaly 日は `is_anomaly=true` を立てて即 return。baseline 計算・
   台帳加算・ストリーク更新・卵充当はすべてスキップ。**anomaly 日に pt が付かない**＝正当。
3. **分母除外の継続**: baseline 平均計算（L842-848）は `and is_anomaly = false` で anomaly 日を
   除外し続ける。サーバーが is_anomaly を立てた日は以後の分母から正しく外れる。**整合**。
4. **正常日の明示 false 書込み**: 確定時 `set is_finalized=true, is_anomaly=false`（L936-939）。
   再提出で total_minutes が anomaly 圏から正常圏へ変わった場合も is_anomaly を false に整合させる。
   ただし**再提出は確定済み行に対しては RLS で弾かれる**ため、実際に正常↔異常を往復させる経路は
   クライアントには無い（finalize 前の未確定行のみ提出可）。設計の堅牢性として問題なし。
5. **サーバー算出切替で壊れた箇所**: `fn_finalize_day` 以外に is_anomaly を読む/書く RPC は無い
   （grep 確認）。`quest_condition_met` は is_anomaly を参照しない。**回帰なし**。

**判定: M4-1 は CLOSED（確定）。anomaly のサーバー算出化は境界・分母除外とも正当。**

---

## 3. fail-closed 全体再確認

H4-1 修正後、「usage 行が無い／未確定」の状態で報酬系に到達できないことを再確認した。

| 条件タイプ | 行なし | 未確定（is_finalized=false） | 確定（is_finalized=true） |
|---|---|---|---|
| `app_under` | not found → **false** | `is_finalized is not true` → **false** | per_app で判定（正当） |
| `reduce_total` | not found → **false** | **false** | baseline 存在かつ削減量で判定 |

- `is_finalized=true` はクライアントが立てられない（H4-1 クローズ済み）ため、上記「確定」列に
  到達するのは `fn_finalize_day`（サーバー）を実際に通った日のみ。**fail-closed の前提が成立**。
- `streak_keep` / `points_earn` は definer 専管テーブル（streaks / point_ledger source='reduction'）
  ベースで、クライアント直書き不可（書込ポリシー無し）。✅
- `hatch_count` は eggs.location='hatched' を数えるが、C-3 トリガー（hatched 遷移は hatched_into
  非NULL ＝ fn_hatch_egg 経由のみ）で計数が信頼できる。✅（round4 で CLOSED 確認済み）

---

## 4. 残存探索（攻撃者視点で粘った結果）

クライアント書込可能な全列から報酬・通貨・図鑑・プレミアムへ至る新経路を探索した。

### 4-1. クライアント書込可能列の棚卸し（列GRANT 後の確定状態）

| テーブル | INSERT 可能列 | UPDATE 可能列 | 危険な列が書けるか |
|---|---|---|---|
| usage_daily | user_id, usage_date, total_minutes, per_app_minutes, source_mode | total_minutes, per_app_minutes, source_mode | is_finalized/is_anomaly **不可** ✅ |
| profiles | （insert は own のみ・RLS） | display_name, timezone | gem/point/pooled/is_linked/deleted_at **不可** ✅ |
| eggs | （insert ポリシー無し＝不可） | slot_index, location, is_active | growth_points/rarity/hatched_into **不可** ✅ |
| user_quests | （insert 剥奪＝不可 / C-2） | progress | is_completed/completed_at/reward_granted **不可** ✅ |
| tracked_apps | 本人 CRUD 全列可 | 全列可 | 報酬計算に影響しない（下記 4-2） |

### 4-2. tracked_apps 経由の影響評価

- `tracked_apps` は本人 CRUD 全列可（0001 `tracked_apps_all_own`）。攻撃者は対象アプリを自由に
  増減・改名できる。
- しかし **サーバーの確定計算（fn_finalize_day）は tracked_apps を一切参照しない**。
  baseline も reduction も `usage_daily.total_minutes` のみで計算する。`quest_condition_met` の
  `app_under` は条件の `package`（quest_definitions.condition 側 ＝ master / クライアント書込不可）と
  `usage_daily.per_app_minutes` を突き合わせる。tracked_apps はクライアント側の計測対象選択に
  使われるだけで、**サーバー権威の報酬計算には入らない**。利得経路なし。✅

### 4-3. eggs の slot/location/is_active 悪用（再確認）

- `is_active=true` を storage 卵に立てられるか → `uq_eggs_one_active`（部分一意 index）で
  アクティブ卵は1個に制限。`fn_apply_growth` は `is_active AND location='incubating'` で対象を
  絞るため、storage の活性卵には積まれず無害（round4 横断確認 #7 と同じ）。✅
- location を直接 'hatched' に → C-3 トリガーで拒否（hatched_into NULL）。✅
- slot_index の競合 → `uq_eggs_slot`（incubating+slot 一意）で防止。✅

### 4-4. profiles.timezone 経由（受容リスク・再掲）

- timezone はクライアント UPDATE 可。クエストの period 窓（日/週境界）を多少ずらせるが、
  条件判定そのもの（利用実績・孵化数・基礎pt 等のサーバー権威データ）は破れない。
  **低リスクとして受容**（round4 と同判定 / 今回スコープ外）。

### 4-5. 負数・境界・競合・二重実行（RPC 横断）

- `fn_spend_currency`: `p_amount <= 0` 拒否（負数で残高増不可）、`for update` で残高ロック、
  残高不足は例外、kind を gem/point 限定。✅
- `fn_grant_quest_reward`: `reward_granted` フラグ + pt は ledger unique で物理封鎖。
  さらに C-1 でサーバー再判定（quest_condition_met）を毎回行い、偽 is_completed では付与しない。✅
- `fn_claim_warmup`: 冪等キー `uid:warmup:day`（生涯1回）。day を 1/2 限定。starter 卵は既存
  チェックで再生成しない。✅
- `fn_hatch_egg`: 行ロック + `location in ('incubating','storage')` ガード + growth_points=0
  リセットで再孵化封鎖。✅
- 二重実行: 全 RPC が冪等キー or フラグ or 行ロックで保護。✅

### 4-6. RLS 横断（全14テーブル）

round4 横断確認 #1 から変更なし。master系4は read-only、point_ledger/mofi_collection/
streaks/entitlements/baselines は select のみ書込ポリシー無し、profiles/eggs/usage_daily/
user_quests は列GRANTで危険列を封鎖、tracked_apps は本人CRUD（報酬非関与）。
**`using true` の書込ポリシーは存在しない**。✅

---

## 5. 新規指摘（Low 1 件のみ）

### L5-1（Low / 確定）— `usage_update_own_unfinalized` の with check に is_finalized 制約が無い（多層防御の片肺）

- 対象: `0001` `usage_update_own_unfinalized`（L431-433）
- 重大度: **Low（実害なし）**

round4 の H4-1 修正提案は2点（①列GRANT適用 ②`with check` に `is_finalized=false` 追加）だったが、
実装は **①のみ**で②は未適用。現状の RLS は:
```sql
create policy "usage_update_own_unfinalized" on public.usage_daily
  for update using (auth.uid() = user_id and is_finalized = false)
  with check (auth.uid() = user_id);   -- ← is_finalized の制約が無い
```

#### 影響評価（攻撃が成立するか）
- 仮に `using` を通った未確定行に対し UPDATE で `is_finalized=true` を立てようとしても、
  **列GRANT（G-4）で is_finalized は UPDATE 不可**＝`42501` で拒否される。
- したがって②が無くても **攻撃は列GRANTで止まる**。②は「列GRANT が将来誤って緩められた場合の
  二重防御（defense in depth）」に過ぎない。

#### 真偽
**確定（実害なし）**。現時点で偽造経路は列GRANTで完全に塞がれているため、出荷ブロッカーではない。
多層防御の原則として、後続パスで `with check (auth.uid()=user_id and is_finalized=false)` を
追加することを**推奨**（必須ではない）。

---

## 6. M4-2 / L4-1 の後続スコープ妥当性

- **M4-2（pooled 上限未実装）**: `fn_apply_growth` の pool 分岐は単純加算のみで、S6 の「最大3日分」
  上限が未実装（`pooled_points_max_days=3` は seed 済みだが未参照）。
  - **出荷ブロッカーか**: **否**。理由 — pooled→卵充当の RPC が現状**未実装**（pool に積むだけで
    pool から卵へ移す経路が無い）。pooled は HomeServerSnapshot で表示されるのみで、現時点で
    pooled が通貨・卵成長・報酬へ化ける経路は無い。利得に繋がらないため後続で妥当。
  - **条件**: MVP で pooled 充当機能を出す前に上限クランプを実装すること（出荷時点で機能未提供なら問題なし）。
- **L4-1（point_balance と卵充当の二重計上の見え方）**: `fn_finalize_day` が point_balance に
  +N し、かつ fn_apply_growth で卵成長 +N するが point_balance は減算しない。
  - **出荷ブロッカーか**: **否（要設計確認）**。point_balance が「使える通貨」なら二重便益の懸念だが、
    現状 `fn_spend_currency('point', ...)` の消費先 RPC（ジェム購入等）が MVP で配線されているか
    要確認。企画/開発に point_balance の SSOT 定義（使える通貨か実績表示か）を確認する事項として
    後続で妥当。

両件とも round4 既出。**新規ではない**ため severity を再計上しない。後続スコープ判断は妥当。

---

## 7. GO / NO-GO 判定

- **H4-1 は CLOSED（確定）**。is_finalized のクライアント直書きは列GRANT で物理的に封鎖。
  fail-closed の前提（is_finalized はサーバー専管）が成立した。
- **M4-1 は CLOSED（確定）**。is_anomaly はサーバー算出化され、クライアント書込不可。境界・分母除外とも正当。
- **新規 Critical: 0 件（無し）／ 新規 High: 0 件（無し）／ 新規 Medium: 0 件（無し）**。
  新規は Low 1 件（L5-1 / 実害なし・多層防御の推奨のみ）。
- **MVPローンチに経済信頼境界は健全か（H-2 自己申告・低リスク timezone を除く）**:
  - **GO（収束）**。
  - 理由: 過去ラウンドで毎回検出されていた信頼境界突破経路（クエスト報酬偽造・無限再孵化・
    fail-open・hatch_count 偽造・is_finalized 直書き）はすべて塞がれた。クライアントが書ける列から
    報酬・通貨・図鑑・プレミアムへ至る新経路は、本ラウンドの能動的探索でも**発見されなかった**。
  - 残る既知リスクは2系統のみ:
    1. **H-2（端末申告 total_minutes の過大申告）** — 構造的限界。480pt/日 cap + サーバー anomaly
       判定で被害局限。受容。
    2. **timezone による period 窓ずらし** — 低リスク。条件判定本体は破れない。受容。
  - 後続スコープ（M4-2 pooled 上限・L4-1 point_balance SSOT 定義）は、いずれも現時点で利得に
    繋がらず、MVP 出荷時点で機能未提供 or 設計確認で対応可能。出荷を妨げない。

### 開発への差し戻し（後続・任意）
1. **L5-1（Low / 任意）**: `usage_update_own_unfinalized` の with check に `is_finalized=false` を
   追加（多層防御）。
2. **M4-2（pooled 機能を MVP で出すなら必須）**: pooled 上限クランプ実装、出さないなら「pooled は
   v1.1」とスコープ明文化。
3. **L4-1（要設計確認）**: point_balance の SSOT 定義を企画と確定。
4. **L4-2（低 / round4 既出）**: hatch_count の期間判定を profiles.timezone に統一。

### 体制への注記
本レビューは Claude（QA）自己同型レビューのため、可能なら **Codex 復帰時に H4-1/M4-1 修正後の
列GRANT適用・anomaly サーバー算出を別モデルで再確認**することを引き続き推奨する。特に
ライブDBでの「クライアントが is_finalized/is_anomaly を含む行を POST した際に 42501 で拒否される」
ことの実機確認（本レビューは机上検証）を、可能なら出荷前に1度実施されたい。

# REVIEW_round4_economy — Moffy 経済信頼境界 第4巡クロスレビュー

- 対象: `supabase/migrations/0001`〜`0005` + クライアント (`*_repository.dart` / `lib/core/iap/*`)
- 日付: 2026-06-24
- レビュアー: QA部署 (qa-reviewer)
- 過去ラウンドのクローズ済み指摘: C-1 (is_completed偽装) / H-1 (無限再孵化) / C-2 (fail-open+クエスト捏造) / M-2 (カスケード巻込) / C-3 (hatch_count偽装)

---

## ⚠ レビュー体制の限界開示 (必読)

本来このプロジェクトのクロスレビューは **「実装者とは別のAIモデル」** (Codex / gpt-5.x) が
行う鉄則。しかし今回は **Codex が外部利用の制限に当たり使用不可** のため、
**Claude (QA) 自身が第三者レビュー役を代替** している。

つまり本レビューは「**モデル多様性のない自己同型レビュー**」であり、別モデルなら
気付く盲点を構造的に見落とすリスクが残る。これを補うため、本レビューは
**受動的な観点チェックではなく、攻撃者(ペンテスター)になりきって新しい偽造経路を
能動的に構築する**方針で実施した。それでもなお「別モデルによる再レビューが望ましい」
という限界は残ることを、判定の前提として CEO に明示する。

---

## サマリ

| 項目 | 結果 |
|---|---|
| C-3 (hatched遷移サーバー専管) は CLOSED か | **CLOSED (確定)** |
| 新規 Critical | **0 件** |
| 新規 High | **1 件** (H4-1: `usage_daily.is_finalized` クライアント直書き) |
| 新規 Medium | **2 件** (M4-1: `is_anomaly` 改ざんで異常値ガード回避 / M4-2: pooled 無限累積) |
| 新規 Low | **2 件** (L4-1: `fn_finalize_day` 残高と卵充当の二重計上の見え方 / L4-2: hatch_count の updated_at が UTC 固定) |
| MVPローンチ判定 (H-2・低リスクtimezone を除く) | **条件付き GO** (H4-1 の対処を強く推奨。詳細は末尾) |

---

## C-3 クローズ確認 (最優先)

`0005` の `fn_eggs_block_hatched_mutation` を 5 ケースで机上検証した。

トリガー本体 (要点):
```sql
-- ① 復活防止 (M-2)
if old.location = 'hatched' and new.location is distinct from old.location then RAISE;
-- ② hatched 遷移のサーバー専管 (C-3)
if new.location = 'hatched' and old.location is distinct from 'hatched'
   and new.hatched_into is null then RAISE;
```

| # | ケース | OLD.location | NEW.location | NEW.hatched_into | 期待 | トリガー判定 | 結果 |
|---|---|---|---|---|---|---|---|
| (a) | クライアント直接 hatched 化 (`update eggs set location='hatched'`) | incubating/storage | hatched | NULL (列GRANTで書けない) | 拒否 | ②に合致 → RAISE | ✅ 拒否 |
| (b) | `fn_hatch_egg` 正規孵化 (location と hatched_into を同時 set) | incubating/storage | hatched | 非NULL | 通過 | ①不該当・②は hatched_into 非NULLで不該当 | ✅ 通過 |
| (c) | 枠操作 (incubating↔storage / is_active / slot) | ≠hatched | ≠hatched | 不問 | 通過 | ①②とも不該当 | ✅ 通過 |
| (d) | `ON DELETE SET NULL` カスケード (mofi_collection 削除) | hatched | hatched (不変) | NULL | 通過 | ①は NEW=OLD で不該当・②は OLD=hatched で不該当 | ✅ 通過 |
| (e) | 復活 (hatched→incubating/storage で再孵化) | hatched | ≠hatched | 不問 | 拒否 | ①に合致 → RAISE | ✅ 拒否 |

補強点 (多層防御の確認):
- 仮に (a) のトリガーをすり抜けても、`hatch_count` 偽造には「location='hatched'」計数しか効かず、
  `fn_hatch_egg` を経ないので図鑑エントリ・通貨は増えない。報酬は `fn_grant_quest_reward` の
  `quest_condition_met` 再判定経由でのみ。
- `fn_hatch_egg` 側も `growth_points=0` リセット + `location in ('incubating','storage')` ガードで
  再孵化を二重に封鎖 (H-1)。

判定: **C-3 は CLOSED (確定)**。トリガーの判別キーを「クライアントが書けない `hatched_into`」に
置いた設計は妥当で、列GRANT (0004) と整合している。

---

## 新規指摘

### H4-1 (High / 確定) — `usage_daily.is_finalized` をクライアントが直接 true 化できる (fail-closed 回避)

- 対象: `0001_init.sql` (usage_daily の RLS) / `0005` `quest_condition_met` / `0004` (列GRANT未適用)
- 重大度: **High**

#### 何が問題か
`0005` の C-2 fail-closed 修正は、「`app_under` / `reduce_total` クエストは
**`usage_daily` 行が存在し `is_finalized=true` の日のみ達成と見なす**」という前提に立つ。
コメントにも明記:
> usage_daily 自体は端末申告 (H-2) だが、**is_finalized は fn_finalize_day (definer) のみが
> 立てる確定フラグ**なので、未確定値での偽達成を防ぐ。

ところが、この「is_finalized はサーバーのみが立てる」という前提が **成立していない**。

- `usage_daily` の RLS (0001):
  - `usage_insert_own` : `with check (auth.uid() = user_id)` — **列の制限なし**。`is_finalized` を含む任意列を insert 可能。
  - `usage_update_own_unfinalized` : `using (auth.uid()=user_id and is_finalized=false) with check (auth.uid()=user_id)` — 未確定行を更新でき、**`with check` 側に `is_finalized` の制約がない**。
- `0004_security_hardening.sql` は列レベル GRANT を **profiles と eggs にのみ** 適用。`usage_daily` には適用していない。よって authenticated は `usage_daily` の全列を直接 INSERT/UPDATE できる。

つまり攻撃者は **`fn_finalize_day` を一切呼ばずに**、PostgREST で
`is_finalized=true` の usage_daily 行を直接作れる。

#### 攻撃手順 (PostgREST 直接)
```
-- anon/公開キー + 自分の JWT で:
POST /rest/v1/usage_daily
{ "usage_date":"2026-06-24", "total_minutes":0,
  "per_app_minutes":{"com.zhiliaoapp.musically":0},
  "source_mode":"exact-minutes", "is_finalized":true, "is_anomaly":false }
```
これで「TikTok 0分・確定済み」の行が user 権限で作れる。続いて
```
POST /rest/v1/rpc/fn_evaluate_quest   { "p_user_quest_id": <app_under quest> }
POST /rest/v1/rpc/fn_grant_quest_reward { "p_user_quest_id": <同上> }
```
`quest_condition_met('app_under')` は「行が存在し is_finalized=true」を満たすので
`per_app_minutes['...'] < target` で **達成 true**。**実際に利用を削減していなくても**
`app_under` 系クエストの pt/ジェム/報酬卵を獲得できる。

`reduce_total` も同様に、`is_finalized=true` の usage_daily 行 + 攻撃者が baselines を
作れない点に救われるが (baselines は 0004 でRLS+書込ポリシー無し=直接作成不可)、
`app_under` は baselines 非依存なので **単独で成立する** のが致命的。

> 重要な区別: これは H-2 (「total_minutes を過少申告して reduction pt を稼ぐ / 480上限で緩和」)
> とは別物。H-2 は `fn_finalize_day` 経由で 480pt/日 の上限が効く。本件 H4-1 は
> **finalize を経ずにクエスト報酬系 (上限の効かない固定報酬・ジェム・報酬卵) を偽造**できる。
> 480cap でも anomaly でも緩和されない。

#### 真偽
**確定**。RLS 定義・0004 の適用範囲・`quest_condition_met` の前提を突き合わせた結果、
fail-closed の根拠 (is_finalized のサーバー専管) が物理的に担保されていない。

#### 修正提案 (開発へ差し戻し)
いずれかで `is_finalized` / `is_anomaly` を「クライアントは書けない」状態にする:
1. (推奨) `usage_daily` に列レベル GRANT を 0004 と同方針で適用:
   ```sql
   revoke insert, update on public.usage_daily from authenticated;
   grant insert (usage_date, total_minutes, per_app_minutes, source_mode) on public.usage_daily to authenticated;
   grant update (total_minutes, per_app_minutes, source_mode) on public.usage_daily to authenticated;
   -- is_finalized / is_anomaly は GRANT しない (= サーバー definer 専管)
   ```
   ※ 列レベル INSERT GRANT では未指定列はデフォルト値 (is_finalized=false / is_anomaly=false) になり、クライアントは true をセットできない。`fn_finalize_day` 等の definer は引き続き全列書込可。
   ※ 併せて `usage_update_own_unfinalized` の `with check` に `is_finalized = false` を追加し、確定済み化の自己申告を二重に封じる。
2. もしくは `quest_condition_met` を「is_finalized=true かつ **point_ledger に当該日の reduction 行がある**」など、definer 専管テーブル (point_ledger / baselines) でクロス検証する。
   - ただし `app_under` (削減0でも達成しうるクエスト) は reduction 行が無い日もあるため、(1) の列GRANTが本質的で確実。

---

### M4-1 (Medium / 確定) — `is_anomaly` 改ざんで異常値ガードを無効化 (H-2 を増幅)

- 対象: `0001` usage_daily RLS / `0002` `fn_finalize_day` (anomaly 分母除外・確定スキップ)
- 重大度: **Medium**

#### 何が問題か
H4-1 と同根 (usage_daily の列が自由に書ける) だが、影響面が異なるので分離。
`is_anomaly` はクライアントが自由に false/true を設定できる。

- `fn_finalize_day` は `is_anomaly=true` の日を「確定しない / 基準値の分母から除外」する (S4-3 異常値ガード)。
- 攻撃者は **意図的に `is_anomaly` を操作**できる:
  - **基準値の引き上げ**: 「使い過ぎた日」を `is_anomaly=true` で提出 → finalize の基準値平均計算 (0002 L213-219) の分母から除外される。結果、平均が下がらず baseline が高止まり → 翌日以降の `reduced = baseline - today` が大きく出て **reduction pt を過大取得**できる。
  - 480/日 cap は効くが、cap 上限 (480pt) まで毎日不正に積める余地が広がる。

これは「H-2 (端末申告は信頼できない / 480cap で緩和)」の受容範囲を、**サーバー側の異常値ガードを
攻撃者が任意に on/off できる**点で増幅する。anomaly ガードは「物理的にありえない値の破棄」という
防御だったが、攻撃者が制御できるなら防御として機能しない。

#### 攻撃手順
高利用日を `is_anomaly=true` で提出し続け、baseline を意図的に高く保つ。低利用日は
`is_anomaly=false` で提出 → finalize で大きな reduction を得る (日次480まで)。

#### 真偽
**確定** (列GRANT 未適用の事実から)。ただし利得は 480pt/日 cap の範囲内なので High ではなく Medium。

#### 修正提案
H4-1 の修正 (1) で `is_anomaly` も GRANT 対象外にすれば同時に解決する。
異常値判定は本来サーバー (finalize 内で total_minutes>1440 等を判定) で行うべきで、
クライアント申告の `is_anomaly` を信頼するのは設計として弱い。
→ サーバー側で `is_anomaly` を再計算 (total_minutes が上限超なら true) し、クライアント値は無視する。

---

### M4-2 (Medium / 確定) — `pooled_points` が上限なく無限累積 (S6 の最大3日分が未実装)

- 対象: `0002` `fn_apply_growth` (pooled 加算) / `app_config.pooled_points_max_days=3`
- 重大度: **Medium**

#### 何が問題か
S6 / PRD は「アクティブ卵不在時の pt を **最大3日分プール**」と定義し、
`app_config.pooled_points_max_days=3` を持つ。しかし `fn_apply_growth` の pool 分岐 (0002 L442-445) は:
```sql
update public.profiles set pooled_points = pooled_points + p_points where id = v_uid;
```
と **単純加算のみ**で、上限クランプ・古い分の失効を一切行っていない。コメントも
「ここでは取りこぼし防止のため単純加算」と自認。

攻撃というより設計の抜け。アクティブ卵を持たない状態で finalize を繰り返すと
pooled_points が青天井に積み上がる。pooled_points が後で卵成長に充当される設計
(クライアント表示では pooled を見せている) なら、「3日上限」を超えた分が
**正当に獲得した以上の卵成長**に化ける経路になりうる。

#### 真偽
**確定** (コードに上限処理が無い)。ただし pooled→卵充当の RPC が現状見当たらず
(`fn_apply_growth` は pool に積むだけで、pool から卵へ移す経路が未実装)、
**現時点で直接の利得には繋がっていない**ため Medium 据え置き。MVP で pooled 充当を
実装する前に上限ロジックを入れること。

#### 修正提案
`fn_apply_growth` の pool 加算時に `pooled_points_max_days × (1日の理論最大=cap)` 等で
クランプするか、pooled の発生日を記録して 3日超を失効させる。MVP で pooled 機能を出さないなら
明示的に「pooled は v1.1」とスコープ確定する。

---

### L4-1 (Low / 要確認) — `fn_finalize_day`: point_balance 加算と卵充当の関係 (二重計上の見え方)

- 対象: `0002` `fn_finalize_day` (L309-313 残高加算 + L344-346 fn_apply_growth 呼出)
- 重大度: **Low**

`fn_finalize_day` は初回確定時に `point_balance += v_final_points` し、続けて
`fn_apply_growth(null, v_final_points)` を呼ぶ。`fn_apply_growth` は
`spend_incubation: -v_final_points` の台帳を記録するが、**`point_balance` は減算しない**
(卵 growth_points を増やすか pooled を増やすのみ)。

結果として:
- 台帳合計 (reduction +N, spend_incubation -N) = 0 に収束。
- しかし `point_balance` (導出キャッシュ) は +N のまま (spend ぶんの減算がない)。

これは「reduction pt は残高にも入り、かつ卵成長にも積まれる」= **同じ pt を残高と卵の両取り**に
見える。設計意図が「reduction pt は『削減実績の累計表示用』に残高加算し、卵成長は別カウンタ
(spend_incubation 台帳は監査用で残高に反映しない)」であれば仕様。しかし profiles.point_balance を
`fn_spend_currency` で**ジェム購入等に使える残高**として消費できる以上、
「卵に積んだ pt をさらに残高として使える」二重便益になっていないか **要確認**。

#### 真偽
**要確認**。攻撃ではなく設計整合の問題。point_balance が「使える通貨」なのか
「実績表示用の累計」なのかで判定が変わる。`fn_spend_currency('point', ...)` が存在する以上、
使える通貨と解釈すると二重便益。企画/開発に SSOT 定義の確認を差し戻す。

---

### L4-2 (Low / 確定) — `hatch_count` の期間判定が UTC 固定でユーザーTZと不整合

- 対象: `0005` `quest_condition_met` (`hatch_count` 分岐 L168-175)
- 重大度: **Low**

```sql
and (updated_at at time zone 'UTC')::date between v_period_lo and v_period_hi
```
`hatch_count` クエストの孵化日判定は `updated_at` を **UTC** で日付化しているが、
`v_period_lo/hi` (period_start) は **ユーザーTZ基準** (fn_sync_quests が `now() at time zone v_tz`)。
TZ がずれると、日本時間の深夜〜早朝に孵化した卵が UTC では前日扱いになり、
weekly 窓 (7日) の端で **1日ずれて達成判定がブレる**。

経済偽造ではなく境界バグ。weekly は窓が広い (7日) ので影響は端の1日のみだが、
daily の hatch_count があると顕在化する。判定を `at time zone <profiles.timezone>` に統一すべき。

#### 真偽
**確定**。低リスク (利得ではなくUX上のブレ) として Low。

---

## 横断確認 (網羅チェックの結果 — 問題なしだった項目)

攻撃を試みたが破れなかった/設計通りだった点を記録する (「問題なし」で終わらせない方針の裏取り)。

1. **RLS 14テーブル**: baselines は 0004 で RLS 有効化済み (G-1)。master系4 (mofi_species/drop_tables/app_config/quest_definitions) は read-only ポリシーのみで書込不可。point_ledger / mofi_collection / streaks / entitlements は select のみ・書込ポリシー無し → クライアント直書き不可。**master に `using true` の書込ポリシーは存在しない**。
2. **entitlements (tier偽装)**: insert/update ポリシー無し + Webhook(service_role) のみ。クライアントは is_premium を一切書けない。IAP も RevenueCat→Webhook→entitlements でサーバー検証。✅
3. **fn_spend_currency**: `p_amount <= 0` を拒否 (負数で残高増やせない)。`for update` で残高ロック・残高不足は例外。`p_kind` を gem/point に限定。✅
4. **fn_claim_warmup**: 冪等キー `uid:warmup:day` (生涯1回)。day を 1/2 に限定。starter 卵は `acquired_source='starter'` 既存チェックで再生成しない。同日 Day1/Day2 連打時の spend_incubation 日付冪等は設計コメントで認識済み (通常運用は別日)。✅ ただし「同日に Day1+Day2 両方 claim すると spend_incubation が1回しか立たず、卵に Day2 ぶんが積まれるが控除台帳は1行」= 台帳とのわずかな不整合の余地はあるが、warmup は生涯1回 + 卵への充当なので利得化しない。Low 未満。
5. **fn_grant_quest_reward の二重付与**: `reward_granted` フラグ + pt は ledger unique で物理封鎖。gem/卵は reward_granted ガード下で1回のみ。✅
6. **fn_sync_quests のクエスト捏造**: authenticated の user_quests INSERT 剥奪済み (C-2)。period はサーバー now()+TZ。quest_id は quest_definitions(is_active) からのみ。クライアントは任意 quest 捏造不可。✅
7. **eggs の uq_eggs_one_active / uq_eggs_slot**: storage 卵を is_active=true にはできる (制約は location 無条件) が、fn_apply_growth は `is_active AND location='incubating'` で対象を絞るので storage活性卵には積まれず無害。同時育成枠超えは uq_eggs_slot (incubating+slot一意) で防止。✅
8. **search_path / definer**: 全 definer 関数に `set search_path = ''` + 完全修飾。search_path 乗っ取り対策済み。✅
9. **fn_evaluate_quest 悪用**: condition をサーバーが quest_condition_met で再判定。未達は is_completed を立てない。既達は据え置き (取り消さない) で整合。→ ただし app_under の達成根拠が H4-1 で崩れる点に注意 (H4-1 で集約)。

---

## GO / NO-GO 判定

- **C-3 は CLOSED (確定)**。再孵化・hatched偽造の経路は塞がれている。
- **新規 Critical: 0 / 新規 High: 1 (H4-1)**。
- **MVPローンチに経済信頼境界は健全か (H-2 と低リスクtimezone を除く)**:
  - **NO-GO (現状のまま) → H4-1 修正で GO**。
  - 理由: H4-1 は「H-2 の受容範囲 (480cap で緩和される reduction 過大申告)」を**超える**。
    finalize を経ずに **上限の効かないクエスト固定報酬・ジェム・報酬卵を偽造**できるため、
    H-2 受容の前提 (被害は 480pt/日 に局限) が崩れる。これは「除外してよい既知リスク」ではなく
    **新規の信頼境界突破**。
  - H4-1 の修正 (usage_daily への列GRANT適用 = 0004 と同方針、is_finalized/is_anomaly を definer 専管化) は
    既存パターンの横展開で、1マイグレーションで対処可能。これを入れれば M4-1 も同時解決し、
    経済信頼境界は MVP として健全と判定できる。
  - M4-2 / L4-1 は MVP の pooled・point消費仕様に依存する設計確認事項。pooled 充当機能と
    point_balance 消費の SSOT 定義を固める前提でローンチ可。

### 開発への差し戻し (優先順)
1. **H4-1 (必須・ローンチブロッカー)**: `usage_daily` に列レベル GRANT を適用し `is_finalized`/`is_anomaly` を definer 専管化。`usage_update_own_unfinalized` の with check に `is_finalized=false` 追加。
2. **M4-1 (H4-1 と同時解決)**: is_anomaly をサーバー再計算に。
3. **M4-2 (pooled 機能を MVP で出すなら必須)**: pooled 上限クランプ実装 or スコープ除外を明文化。
4. **L4-1 (要確認)**: point_balance の SSOT 定義 (使える通貨か実績表示か) を企画と確定。
5. **L4-2 (低)**: hatch_count の期間判定を profiles.timezone に統一。

### 体制への注記
本レビューは Claude(QA) 自己同型レビューのため、**H4-1 修正後に可能なら別モデル(Codex復帰時)で
再確認**することを推奨する。特に usage_daily の列GRANT適用後、`fn_finalize_day` の upsert
(クライアントが is_finalized を書かなくなる) が壊れないか動作確認が必要。

# レビュー報告書: コア経済RPC + クライアント本配線 (0002_economy_rpcs)

- 対象: `supabase/migrations/0002_economy_rpcs.sql` ほか（下記）
- レビュー実施: QA部署 (qa-reviewer)
- 日付: 2026-06-23

## レビュー手法と限界の開示（重要）

- 本来の方針は **別モデル (Codex) によるクロスレビュー**（書いた本人＝実装モデルが検品しない鉄則）。
- しかし **Codex CLI が当環境のヘッドレス実行で固まり利用不可** だったため、今回は **実装者とは別コンテキストの QA（Claude）による独立レビュー** に切り替えた。
- したがって本レビューは「別モデルによる相互検証」ではなく **同系統モデル (Claude) の独立読解** である点を限界として開示する。先入観なくコードを通読し、自力で不具合を検出する方針で実施した。
- ライブDBは無く **静的レビュー（コード読解）のみ**。SQL の実行・分布検証・実機テストは未実施。指摘の「真偽」はコード上の根拠で判定し、実行確認が必要なものは「要確認」と明記した。

レビュー対象ファイル:
1. `supabase/migrations/0002_economy_rpcs.sql`
2. `supabase/migrations/0001_init.sql`
3. `supabase/tests/distribution_check.sql`
4. `lib/features/eggs/data/egg_repository.dart`, `lib/features/quests/data/quest_repository.dart`, `lib/features/profile/data/account_repository.dart`, `lib/features/collection/data/collection_repository.dart`, `lib/core/constants/remote_config.dart`, `lib/core/constants/economy.dart`
5. 参照: `docs/PRD.md` (§4 / S1〜S14), `docs/ARCHITECTURE.md` (§1-4)

---

## 指摘一覧

### F-01【High｜確定不具合】ウォームアップ自動付与 (S1: Day1=200/Day2=300) が**どこにも実装されていない**
- 箇所: `0002` 全体 / `0001` `ledger_source` enum `'warmup'`（line 55）
- 根拠: PRD §S1・§5受け入れ「初日（S1）でDay1孵化体験まで到達」は MVP の中核離脱対策。`ledger_source` に `'warmup'` を定義し `app_config.warmup_grants={"day1":200,"day2":300}` も seed 済み（`0001` line 526）だが、**この値を読んで `point_ledger` に warmup を挿入し卵 growth に充当する RPC が 0002 に存在しない**。`fn_finalize_day` は `v_sample_days=0`（データ無し日）で `v_applied_min:=0 → v_reduced=0 → 0pt`、すなわち warmup 日は何も付与されない（line 234-238, 281 の `if v_final_points>0` を通らない）。
- 影響: 新規ユーザーが Day1 で孵化体験に到達できない。PRD が「最大の離脱要因」と明記した初日体験が成立しない。
- 修正提案: `fn_grant_warmup(p_date)` 等を新設するか `fn_finalize_day` 内で warmup ステージ時に `warmup_grants` を `point_ledger(source='warmup', idem=uid×date×'warmup')` で冪等付与し、`fn_apply_growth` で初回ボーナス卵へ充当する。初回ボーナス卵の生成経路（`acquired_source='starter'`）も併せて要確認（0002 に生成 RPC が見当たらない）。
- 真偽: **確定不具合**（仕様要件の未実装）。

### F-02【High｜確定不具合】ストリーク倍率の **off-by-one**（適用段が1日遅れる / S14）
- 箇所: `0002` `fn_finalize_day` line 259, 314-321
- 根拠: 倍率は `v_mult := public.streak_multiplier(v_streak_cur)` で算出するが、`v_streak_cur` は **今日の継続を加算する前** のストリーク。今日の加算（`v_streak_cur+1`）は line 316 で倍率適用後に行われる。
  - 連続3日目: 関数突入時 `v_streak_cur=2` → `streak_multiplier(2)` は `days<=2` の最大段 = days:1 → **×1.0**。だが PRD §S14・§4表は「3日=×1.2」。
  - 同様に7日目に ×1.5 ではなく ×1.2 が乗る。常に1日分の倍率が遅れる。
- 補足: コメント（line 257-258）は「今日時点の到達段で乗せる」と書いており、**実装が設計コメントと矛盾**している。クライアント表示（`quest_repository` の `streaks.current_streak` ＝維持後の値で `StreakTier.multiplierFor`）とサーバー実付与の段がズレるため、ユーザーから見て「×1.2と表示されているのに×1.0しか付かない」体験になりうる。
- 修正提案: 継続判定を先に行い、`v_reduced>0` なら `streak_multiplier(v_streak_cur+1)` を倍率に使う（＝今日を含めた到達段で乗算）。または継続判定と倍率算出の順序を入れ替える。どちらを正とするか PRD と突合のうえ統一すること。
- 真偽: **確定不具合**（仕様値とコメントの双方に反する）。重大度は経済の体感に直結するため High。

### F-03【High｜確定不具合】退会時に **`auth.users` を直接 DELETE しても孵化卵が `mofi_species` 経由で残らない**点は問題ないが、`fn_delete_account` の cascade 連鎖は成立——ただし **論理削除(deleted_at)/30日猶予(S12)が未実装**
- 箇所: `0002` `fn_delete_account` line 815 / `0001` 各FK
- 根拠（cascade検証 = 観点5）: 0001 で `profiles.id references auth.users(id) on delete cascade`（line 74）。ユーザーデータ各表（`tracked_apps`/`usage_daily`/`baselines`/`point_ledger`/`eggs`/`mofi_collection`/`user_quests`/`streaks`/`entitlements`）はいずれも `references auth.users(id) on delete cascade`（profiles ではなく auth.users を直接参照）。`eggs.hatched_into → mofi_collection(id) on delete set null`（line 292-294）。したがって `delete from auth.users` で**全ユーザー行は連鎖削除され孤児行は出ない**（cascade自体はOK）。`mofi_species` は master なので残るが正しい。
- 不具合: PRD §S12・`0001` line 86-87 は **「即時論理削除 → 30日以内に物理削除」** と明記し `profiles.deleted_at` 列も用意済み。しかし `fn_delete_account` は**即時物理削除**（`deleted_at` を一切使わない）。仕様（30日猶予による誤操作復旧）と実装が不一致。
- 影響: 誤操作・サポート復旧の余地が無い。即時全消去は審査上は通るが、自社仕様未達。
- 修正提案: 仕様を「即時物理削除」に倒すなら PRD/0001 のコメントを正す（仕様変更の承認をCEO/企画へ）。仕様どおりにするなら `deleted_at` セット＋セッション無効化に留め、物理削除はバッチ/cron へ。**どちらかに統一**が必要。
- 真偽: cascade は**確定OK**（孤児行なし）。論理削除未実装は**確定不一致**。

### F-04【Medium｜確定不具合】`fn_grant_quest_reward` の残高更新が `fn_finalize_day` と**非対称**（台帳と残高の整合がフラグ依存）
- 箇所: `0002` `fn_grant_quest_reward` line 665-680
- 根拠（観点2）: `fn_finalize_day` は `point_ledger` insert 後に `get diagnostics row_count` で**実挿入時のみ** `point_balance` を更新（line 296-303）。一方 `fn_grant_quest_reward` は `on conflict do nothing` の直後、**`get diagnostics` を使わず無条件に** `point_balance += v_points`（line 677-679）している。
  - 通常経路（`reward_granted` フラグで再入を弾く）では二重に到達しないため、**実運用での二重付与は起きにくい**。ただし整合の担保が「ledger の unique」ではなく「reward_granted フラグ」だけに依存し、設計の一貫性が崩れている。
  - 潜在リスク: `reward_granted=false` のまま当該 idempotency_key の ledger 行が（別経路・手動・再生成で）既存になっているケースでは、conflict で台帳は増えないが残高だけ +v_points され、**台帳合計と point_balance がズレる**。PRD/ARCHITECTURE は「台帳が真、point_balance は導出キャッシュ」（0001 line 80-83）と定義しており、その不変条件が破れうる。
- 修正提案: `fn_finalize_day` と同様に `get diagnostics v_rowcount=row_count; if v_rowcount>0 then update profiles ...` へ統一。
- 真偽: **確定不具合（整合性の非対称）**。通常フローでの実害可能性は低いため Medium。

### F-05【Medium｜要確認】クライアント `setActiveEgg` の2段 UPDATE が**非原子的**で `uq_eggs_one_active` 違反の窓がある
- 箇所: `egg_repository.dart` `SupabaseEggRepository.setActiveEgg` line 259-263
- 根拠（観点3/7）: 「全 incubating を `is_active=false`」→「対象を `is_active=true`」を**2回の独立した PostgREST update** で実行。間で失敗するとアクティブ卵が0個になりうる。また同時実行や `uq_eggs_one_active` 部分一意制約との競合で2行目 update が制約違反になる窓がある（直前の false 化がまだ可視化されていない等）。枠移動は RPC ではなくクライアント直接 update（0001 の `eggs_update_own` 許可）で行う設計のため、原子性が無い。
- 影響: 残高には影響しない（成長 pt はRPC集約）が、UI 状態が壊れる/例外。信頼境界の毀損ではない。
- 修正提案: アクティブ切替も `security definer` RPC（単一Txで false化→true化）に寄せる。MVP据え置きなら「失敗時リトライ＋再読込」をUI側に明記。
- 真偽: **要確認**（DBの可視性タイミング依存。実機/同時操作テストで再現確認を推奨）。

### F-06【Low｜誤検知寄り→確認済みOK】`security definer` + `search_path=''` + 完全修飾の網羅（観点1/9）
- 箇所: `0002` 全関数
- 確認結果: 公開・内部の全10関数（`cfg`/`cfg_int`/`cfg_num`/`streak_multiplier`/`fn_finalize_day`/`fn_apply_growth`/`fn_hatch_egg`/`fn_grant_quest_reward`/`fn_spend_currency`/`fn_delete_account`）すべてに `security definer` と `set search_path = ''` が付与され、テーブル参照は `public.` / `auth.uid()` で完全修飾されている。**漏れなし**。
- 組込み関数（観点9）: `now()` `random()` `round()` `floor()` `greatest()` `coalesce()` `jsonb_*` `timezone`（`at time zone`）`auth.uid()` は `pg_catalog` が暗黙先頭のため `search_path=''` 下でも解決される。`auth.uid()` は `auth` スキーマ完全修飾で問題なし。**確定OK**。
- 注記: `0001` の `public.set_updated_at()`（トリガ関数）には `set search_path=''` が無いが、`security definer` でもなく所有者権限実行でもない（トリガは呼び出しユーザー権限／`new.updated_at=now()` のみ）ため実害は小。一貫性の観点で付与を推奨（Low）。
- 真偽: 観点1/9は**確定OK**。トリガ関数の search_path はLow改善提案。

### F-07【Low｜確定OK】権限 revoke/grant（観点8）
- 箇所: `0002` line 835-852
- 確認結果: 全10関数を `revoke all ... from public, anon, authenticated`、公開5RPC（`fn_finalize_day`/`fn_hatch_egg`/`fn_grant_quest_reward`/`fn_spend_currency`/`fn_delete_account`）のみ `grant execute to authenticated`。内部ヘルパ（`cfg*`/`streak_multiplier`/`fn_apply_growth`）は grant せず、`security definer` の内部呼び出しは所有者権限で動くため execute 不要。**妥当・漏れなし**。
- 真偽: **確定OK**。

### F-08【Low｜確定OK】型整合 `user_quests.quest_id`(text) ↔ `quest_definitions.id`(text)（観点6）
- 箇所: `0001` line 197, 300, 320 / `0002` line 619, 636-637, 655, 671
- 確認結果: `mofi_species.id` と `quest_definitions.id` はともに `text` PK、`user_quests.quest_id` は `text` FK で一致。`fn_grant_quest_reward` の `v_quest_def text` も text で、`quest_definitions.id = v_quest_def` の比較は同型・暗黙キャスト無し。idempotency_key 構築の `|| v_quest_def` も text 連結で問題なし。**確定OK**（uuid/text 混在の罠なし）。
- 真偽: **確定OK**。

### F-09【Low｜確定OK】信頼境界・クライアント書き込み封鎖（観点7）
- 箇所: クライアント4リポジトリ / `0001` RLS
- 確認結果:
  - `point_ledger`/`mofi_collection`/`entitlements`/`streaks` は RLS で select のみ・書込ポリシー無し（0001 line 435-475）。クライアントが残高・図鑑・権利を直接書く経路は無い。
  - `egg_repository`/`quest_repository`/`collection_repository`/`account_repository` の Supabase 実装は孵化・報酬・退会をすべて RPC 経由で呼び、残高/図鑑をクライアントで加算していない（`hatch`→`fn_hatch_egg`、`claimReward`→`fn_grant_quest_reward`、`deleteAccount`→`fn_delete_account`）。
  - フォールバック（Mock）は `Env.hasSupabase` が false のときのみ DI される（`*RepositoryProvider`）。Mock は**ローカルメモリ状態のみ**更新し、Supabase へ一切書かない。本番（Supabase設定済み）では Mock が選ばれないため「本番でモックが残高を動かす」リスクは無い。
- 真偽: **確定OK**。ただし F-12（フォールバック運用）参照。

### F-10【Medium｜要確認】抽選累積重みの端数寄せと distribution_check の整合（観点4）
- 箇所: `0002` `fn_hatch_egg` line 514-531 / `distribution_check.sql` line 46-62
- 根拠: 孵化抽選は `v_roll=random()`（[0,1)）で common→rare→sr→ssr の累積比較、**最後の else で ssr に寄せる**（line 528）。重み合計が <1.0 の場合の端数は ssr に寄る。`distribution_check.sql` の §4-2 ループ（line 46-62）は**同一の累積判定**を再現しており、ロジックは1:1で一致（残余 ssr 寄せも一致）。drop_tables 合計=1.0 検証（line 155-173）も別途あり、seed 値（0001 line 506-510）は各行ちょうど 1.0。
- 確認結果: ロジック整合は**OK**。重み合計が1でない場合の挙動（ssr寄せ）も設計どおりで一貫。
- 要確認点: `distribution_check.sql` は「fn_hatch_egg と同一ロジックを**手書きで複製**」している（line 12-13 が「レビュー時に突合せよ」と明記）。複製である以上、将来 RPC 側のみ変更されるとテストが乖離する。**実DBでの実行検証は未実施**（ライブDB無し）。
- 修正提案: 可能なら抽選コアを共通 SQL 関数化してテストと本体で共有。最低限、CI で両者の同期を担保する運用メモを残す。
- 真偽: ロジック整合は**確定OK**、実行収束は**要確認**（未実行）。

### F-11【Medium｜要確認】`fn_apply_growth` のプール上限 (S6: 最大3日) が**未実装**でプールが無制限に膨らむ
- 箇所: `0002` `fn_apply_growth` line 429-438
- 根拠: アクティブ卵が無い場合 `profiles.pooled_points += p_points` を**単純加算**。コメント自身（line 430-431）が「最大日数の管理は表示側＋充当時調整。ここでは取りこぼし防止のため単純加算」と認める。だが PRD §S6・`app_config.pooled_points_max_days=3`（0001 line 530）は「最大3日分プール」と上限を定義。サーバーがプール上限をクランプしないと、長期間アクティブ卵不在のユーザーで `pooled_points` が際限なく積み上がり、後でまとめて充当されると経済設計（1日上限480の趣旨）を超えた一括成長が起きうる。
- 影響: 経済バランスの逸脱（直接の二重付与ではないが S6 の意図違反）。
- 修正提案: プール上限を `daily_point_cap * pooled_points_max_days` 等でサーバー側クランプ。少なくとも仕様の所在（サーバー/クライアントどちらが上限責務か）を明文化。
- 真偽: **確定不具合（仕様未達）**だが、充当ロジック側で吸収する設計余地があるため**要確認**扱い。重大度 Medium。

### F-12【Low｜情報】本番フォールバックが Mock になりうる構成（観点7の運用面）
- 箇所: 各 `*RepositoryProvider`（`Env.hasSupabase` 分岐）/ `remote_config.dart`
- 根拠: `Env.hasSupabase` が false だと**全リポジトリが Mock** になり、孵化・報酬・退会がローカルで「成功」扱いになる。本番ビルドで Supabase 設定が欠落するとサーバー未接続のまま UI が成功表示する（残高はサーバーに書かれないので改ざんではないが、ユーザー体験上の不整合）。
- 修正提案: 本番フレーバーでは `Env.hasSupabase` 必須をビルド時アサート／起動時チェックで担保。
- 真偽: **情報**（信頼境界違反ではない。リリース構成の運用ガード）。

### F-13【Low｜確定OK→軽微注意】`fn_finalize_day` の `already_finalized` フラグ算出
- 箇所: `0002` line 349
- 根拠: `'already_finalized', not v_inserted and v_final_points > 0`。`v_final_points=0`（削減0の日）では常に false を返すが、これは「確定対象pt無し」を意味し許容範囲。冪等再実行で `v_inserted=false` のとき正しく `already_finalized=true`（pt>0時）を返す。論理に破綻なし。
- 真偽: **確定OK**（軽微: pt0の再確定を区別したいならフラグ命名を見直す程度）。

---

## 開発への差し戻し修正リスト（優先順）

| # | 重大度 | 指摘 | 必須/推奨 |
|---|--------|------|-----------|
| 1 | High | **F-01** ウォームアップ自動付与(S1 Day1=200/Day2=300)＋初回ボーナス卵生成の実装 | 出荷必須 |
| 2 | High | **F-02** ストリーク倍率 off-by-one（適用段が1日遅れ。設計コメントとも矛盾） | 出荷必須 |
| 3 | High | **F-03** 退会の論理削除/30日猶予(S12) と即時物理削除の不一致を解消（仕様か実装どちらかに統一） | 出荷必須（仕様判断要） |
| 4 | Medium | **F-04** `fn_grant_quest_reward` の残高更新を `get diagnostics` で初回挿入時のみに統一 | 出荷必須 |
| 5 | Medium | **F-11** プール上限(S6 最大3日)のサーバー側クランプ | 出荷前推奨 |
| 6 | Medium | **F-05** `setActiveEgg` の非原子2段update → RPC化 or リトライUI | 出荷前推奨 |
| 7 | Medium | **F-10** 抽選分布の**実DB実行検証**（ライブDBで distribution_check 実行） | 出荷前推奨 |
| 8 | Low | **F-06/F-12** トリガ関数の search_path、本番フォールバックのビルドガード | 次サイクル可 |

cascade(F-03孤児行)、型整合(F-08)、権限(F-07)、search_path網羅(F-06)、クライアント信頼境界(F-09) は **確定OK**。

---

## GO / NO-GO 判定

**判定: NO-GO（条件付き）**

- 経済コアの**信頼境界・権限・型・cascade・抽選ロジック整合**は良好で、設計品質は高い。
- ただし **High 3件（F-01 ウォームアップ未実装 / F-02 倍率 off-by-one / F-03 退会仕様不一致）** は、いずれも MVP の受け入れ条件（§5: S1初日体験・S14倍率・S12退会）に直結する。F-01 は「最大の離脱要因対策」が成立せず、F-02 は表示と実付与の乖離、F-03 は自社仕様との不一致。
- これらは経済の正しさ・初日体験・審査関連に関わるため、**現状ではコア経済として出荷不可**。
- F-01・F-02・F-04 を修正し、F-03 の仕様方針を確定（CEO/企画判断）したうえで、**ライブDBでの distribution_check 実行と実機での孵化/受取/退会/同時操作テスト**を経て再レビューすれば GO 可能。

> 限界の再掲: 本判定は **Codex 不在のため Claude-QA 単独の静的レビュー** に基づく。SQL 実行・分布収束・実機検証は未実施。ライブDB環境が整い次第、実行系テストでの裏取りを強く推奨する。

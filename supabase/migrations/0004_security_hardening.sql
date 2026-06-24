-- ============================================================================
-- Moffy セキュリティ強化 (0004_security_hardening.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / CEO承認済み / 日付: 2026-06-23
-- 準拠: 0001_init.sql の確定スキーマ / ORG_STATE.md / docs/cross-review-protocol.md
--
-- 目的 (= 信頼境界の物理的な締め直し):
--   0001 では一部の改ざん防止を「アプリ規約 + RPC集約」という運用で担保していた
--   (例: profiles の通貨列・eggs の growth_points)。本マイグレーションは、それらを
--   PostgreSQL の「列レベル GRANT」で物理的に書き込み不能にし、運用ではなく権限で
--   信頼境界を守る。RLS (行所有) は維持しつつ、UPDATE できる列を最小化する。
--
-- 冪等性 (= 再適用安全):
--   * policy は `drop policy if exists` を先行させてから create。
--   * `enable row level security` は再実行しても無害 (既に有効なら何も起きない)。
--   * `revoke` / `grant` は再実行安全 (現在の権限状態に収束するだけ)。
--
-- ★最重要: definer 関数 × 列レベル GRANT × RLS の整合 (自己レビュー結果):
--   * security definer 関数 (fn_finalize_day / fn_apply_growth / fn_hatch_egg /
--     fn_grant_quest_reward / fn_claim_warmup / fn_spend_currency 等) は
--     **所有者 (postgres) 権限で実行**される。
--   * 列レベル GRANT (= `grant update (col) to authenticated`) が制限するのは
--     「authenticated ロールで直接 SQL を投げるクライアント」のみ。所有者は GRANT の
--     対象外なので、definer 関数は引き続き **全列を書き込める**。
--   * 同様に、RLS も definer 関数の所有者 (postgres) には適用されない (テーブル所有者は
--     RLS をバイパス。`force row level security` は使っていない / 0001)。
--   * したがって本マイグレーション適用後も:
--       - fn_finalize_day  → point_ledger 加算 / profiles.point_balance・pooled_points 更新
--         / baselines への基準値スナップショット書込み … いずれも継続可能。
--       - fn_apply_growth  → eggs.growth_points 加算 … 継続可能。
--       - fn_hatch_egg     → eggs.hatched_into / location 更新・mofi_collection 登録 … 継続可能。
--       - fn_grant_quest_reward → profiles 通貨・user_quests.reward_granted … 継続可能。
--       - fn_claim_warmup  → profiles.point_balance・eggs (starter) … 継続可能。
--     クライアント (authenticated) だけが、下記「除外列」を直接 UPDATE できなくなる。
-- ============================================================================

-- ============================================================================
-- G-1: baselines の RLS 有効化 (= 0001 の積み残し。RLS未有効・ポリシー無しだった)
-- ----------------------------------------------------------------------------
--   * baselines は「その日に適用された基準値」の監査/再計算用スナップショット。
--     本人は自分の行を select できるべきだが、0001 では RLS が無効のままで
--     他人の行も読めてしまう状態だった。これを本人限定 select に締める。
--   * 書き込みポリシーは敢えて作らない: baselines を書くのは fn_finalize_day
--     (security definer / 所有者権限 = RLS バイパス) のみ。クライアントからの
--     insert/update/delete は (書き込みポリシー不在により) 一切不可。
-- ============================================================================
alter table public.baselines enable row level security;

drop policy if exists "baselines_select_own" on public.baselines;
create policy "baselines_select_own" on public.baselines
  for select using (auth.uid() = user_id);
-- 書き込みポリシーは作らない ⇒ クライアント直接書込み不可。
-- baselines への書込みは fn_finalize_day (definer / 所有者権限) のみ。

-- ============================================================================
-- G-2: profiles 列レベル UPDATE 制限 (案A承認: is_linked は除外)
-- ----------------------------------------------------------------------------
--   * 0001 では profiles_update_own (行所有) のみで、列の絞りはアプリ規約頼みだった。
--     ここで authenticated の UPDATE 権限を「設定系 2列」に物理的に限定する。
--   * 許可列 (クライアントが直接更新可): display_name, timezone
--   * 除外列 (クライアントは直接更新不可):
--       id, is_linked, gem_balance, point_balance, pooled_points,
--       deleted_at, created_at, updated_at
--     - 通貨 (gem_balance / point_balance) と pooled_points は RPC (definer) /
--       service_role でのみ変更 (信頼境界 / 通貨改ざん防止)。
--     - deleted_at は退会フロー (fn_delete_account / definer) が立てる (S12)。
--     - id / created_at / updated_at は不変 or トリガ (set_updated_at) 管理。
--     - is_linked は **アカウント連携フロー (将来の連携 RPC / Webhook) が
--       サーバー側で立てる** (案A承認)。クライアントが自己申告で連携済みを
--       詐称できないよう、ここで物理的に書込み不能にする (信頼境界)。
--   * RLS の profiles_update_own (行所有 / 0001) は維持: 列レベル GRANT は
--     「どの列を書けるか」、RLS は「どの行を書けるか」を担保し、両者は直交する。
-- ============================================================================
revoke update on public.profiles from authenticated;
grant update (display_name, timezone) on public.profiles to authenticated;

-- ============================================================================
-- G-3: eggs 列レベル UPDATE 制限
-- ----------------------------------------------------------------------------
--   * 0001 では eggs_update_own (行所有) のみで、growth_points / hatched_into 等の
--     改ざん防止はアプリ規約頼みだった。ここで authenticated の UPDATE 権限を
--     「ユーザー操作で正当に変わる枠管理 3列」に物理的に限定する。
--   * 許可列 (クライアントが直接更新可): slot_index, location, is_active
--       - 育成枠 (slot_index) / 所在 (location: incubating/storage) / アクティブ卵の
--         切替 (is_active) は、ユーザーが UI 上で行う正当な枠操作。
--   * 除外列 (クライアントは直接更新不可):
--       id, user_id, rarity, growth_points, hatched_into,
--       acquired_source, created_at, updated_at
--     - growth_points (成長) と hatched_into (孵化結果) は RPC (definer) のみ:
--       fn_apply_growth (成長加算) / fn_hatch_egg (孵化) が書く。クライアントが
--       成長ptや孵化結果を直接書き換えられないようにする (経済の信頼境界)。
--     - rarity は入手時確定 (S5) で不変。acquired_source は入手経路の監査記録で不変。
--     - id / user_id / created_at / updated_at は不変 or トリガ管理。
--   * RLS の eggs_update_own (行所有 / 0001) は維持 (G-2 と同様、行と列は直交)。
-- ============================================================================
revoke update on public.eggs from authenticated;
grant update (slot_index, location, is_active) on public.eggs to authenticated;

-- ============================================================================
-- G-4: usage_daily 列レベル INSERT/UPDATE 制限 (= H4-1/M4-1 修正 / Claude-QA 4巡目)
-- ----------------------------------------------------------------------------
--   設計責任: 開発部署 (engineer) / 日付: 2026-06-24 / 起因: Claude-QA 4巡目レビュー
--     - H4-1 (High): usage_daily は RLS (usage_insert_own / usage_update_own_unfinalized)
--       で本人 INSERT / 未確定 UPDATE を許すが、**列レベル GRANT が未適用** (0004 は
--       profiles/eggs のみだった)。そのためクライアント (authenticated) が
--       `is_finalized=true` や `is_anomaly` を **直接書けた**。
--     - 攻撃 (M4-1 連鎖): 攻撃者は「対象アプリ 0 分・is_finalized=true」の usage_daily 行を
--       直接 INSERT し、fn_finalize_day (サーバー確定) を経ずに 0005 の quest_condition_met
--       (app_under / reduce_total の fail-closed = is_finalized=true 要求) を通過させ、
--       クエスト達成 → ジェム/卵/固定pt (480上限の外) を偽造できた。C-2 の fail-closed が
--       「クライアントが is_finalized を立てられる」ことで根本から破れていた。
--
--   修正方針 (G-2/G-3 と同じ列レベル GRANT の横展開):
--     * 端末 (Drift) が提出する「生データ列」だけを authenticated が書けるようにし、
--       確定/異常の権威フラグ (is_finalized / is_anomaly) はサーバー (definer) 専管にする。
--     * 行レベル (RLS / 本人かつ未確定) と列レベル (どの列を書けるか) の二重防御を維持。
--
--   許可列 (クライアントが直接書ける = 端末の生データ提出に必要な最小列):
--     * INSERT: user_id, usage_date, total_minutes, per_app_minutes, source_mode
--         - id は INSERT 列から除外 → 0001 の `default gen_random_uuid()` で自動採番される。
--           列レベル GRANT で列を列挙しない場合、その列はクライアントから指定できず
--           default が必ず適用される (検証ケース 2)。
--     * UPDATE: total_minutes, per_app_minutes, source_mode
--         - 未確定日の上書き提出 (端末の再集計) に必要な生データ列のみ。
--   除外列 (クライアントは直接書けない / definer 専管):
--     * is_finalized : サーバー確定フラグ。fn_finalize_day (definer) のみが true 化する。
--                      クライアントが立てられないため C-2 fail-closed が物理的に成立する。
--     * is_anomaly   : 異常値フラグ。サーバー (fn_finalize_day / definer) が total_minutes と
--                      app_config.daily_minutes_max から算出して書く (0005 で fn_finalize_day を
--                      更新。端末の自己申告を信用しない = 信頼境界)。
--     * id           : 主キー。default gen_random_uuid() で自動採番 (上記)。
--     * created_at / updated_at : default now() / set_updated_at トリガ (0001 trg_usage_daily_updated_at)
--                                 で自動充填される。クライアントは触れない。
--
--   ★definer 関数との整合 (G-2/G-3 と同じ理屈):
--     * fn_finalize_day (security definer / 所有者権限) は列レベル GRANT の対象外。よって
--       is_finalized=true 化・is_anomaly 書込み・total_minutes 等の更新を全列で継続できる。
--     * RLS も所有者 (postgres) はバイパス (force row level security 未使用 / 0001)。
--
--   ★クライアント配線 (本修正に同梱):
--     * lib/core/sync/finalize_models.dart の toUsageRow() は is_anomaly を送らないよう是正
--       (除外列になったため送ると権限エラーになる)。端末の生データ提出 (user_id, usage_date,
--       total_minutes, per_app_minutes, source_mode) は許可列に収まり従来どおり通る。
--
--   既存 RLS (0001) は維持:
--     usage_select_own / usage_insert_own / usage_update_own_unfinalized
--       (本人 select / 本人 insert / 本人かつ is_finalized=false の行のみ update)。
-- ============================================================================
revoke insert, update on public.usage_daily from authenticated;
grant insert (user_id, usage_date, total_minutes, per_app_minutes, source_mode)
  on public.usage_daily to authenticated;
grant update (total_minutes, per_app_minutes, source_mode)
  on public.usage_daily to authenticated;

-- ============================================================================
-- 残存リスク (= 本マイグレーションのスコープ外。明記のみ / 緩和は別パス)
-- ----------------------------------------------------------------------------
--   * usage_daily の「自己申告」問題:
--       端末 (Drift) が OS の利用時間を計測し、total_minutes / per_app_minutes を
--       本人 insert / 未確定 update する (0001 RLS: usage_insert_own /
--       usage_update_own_unfinalized)。サーバーは OS の実利用時間を独立に検証できない
--       (= 端末の主張を入力として受け取るしかない / 信頼境界の構造的限界)。
--       悪意ある端末は「削減した」と過大申告してポイントを不正取得し得る。
--   * 緩和 (既存 / 0001 + G-4):
--       - 1日上限 480pt (app_config.daily_point_cap) を fn_finalize_day が
--         「倍率適用後の最終値」に対して適用 → 1日あたりの不正利得を上限で頭打ち。
--       - is_anomaly フラグ (物理的にありえない 1440分超等) で異常値を破棄/記録。
--         ★G-4 以降は is_anomaly はサーバー (fn_finalize_day / definer) が算出し書き込む
--         (端末の自己申告ではない / 0005 で fn_finalize_day を更新)。
--       - ★G-4: is_finalized / is_anomaly はクライアント書込不可になったため、「生データの
--         過大申告」は残るが、「確定フラグの偽造による確定スキップ (fn_finalize_day を経ない
--         達成)」は塞がれた (H4-1/M4-1 解消)。total_minutes 等の過大申告は上限 480pt で頭打ち。
--   * 「確定の入力となる端末申告そのもの (total_minutes)」の真正性検証は本質的に困難であり、
--     上限 + サーバー anomaly 判定による被害局限が現実解である旨を明記する (今回スコープ外)。
-- ============================================================================

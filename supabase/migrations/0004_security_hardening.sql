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
-- 残存リスク (= 本マイグレーションのスコープ外。明記のみ / 緩和は別パス)
-- ----------------------------------------------------------------------------
--   * usage_daily の「自己申告」問題:
--       端末 (Drift) が OS の利用時間を計測し、total_minutes / per_app_minutes を
--       本人 insert / 未確定 update する (0001 RLS: usage_insert_own /
--       usage_update_own_unfinalized)。サーバーは OS の実利用時間を独立に検証できない
--       (= 端末の主張を入力として受け取るしかない / 信頼境界の構造的限界)。
--       悪意ある端末は「削減した」と過大申告してポイントを不正取得し得る。
--   * 緩和 (既存 / 0001):
--       - 1日上限 480pt (app_config.daily_point_cap) を fn_finalize_day が
--         「倍率適用後の最終値」に対して適用 → 1日あたりの不正利得を上限で頭打ち。
--       - is_anomaly フラグ (物理的にありえない 1440分超等) で異常値を破棄/記録。
--   * 今回は列レベル GRANT で「確定後のサーバー側データ (通貨/成長/基準値)」の改ざんを
--     塞いだが、「確定の入力となる端末申告そのもの」の真正性検証は本質的に困難であり、
--     上限 + anomaly 判定による被害局限が現実解である旨を明記する (今回スコープ外)。
-- ============================================================================

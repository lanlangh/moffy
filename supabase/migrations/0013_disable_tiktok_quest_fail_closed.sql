-- ============================================================================
-- 0013: daily_tiktok_under_20 の停止 + app_under キー欠落の fail-closed 化 (v1.1 順0)
-- ============================================================================
-- 真因 (2026-08-07 全数調査 S 系列の前提潰し):
--   iOS は FamilyControls の不透明トークンのためアプリを個別識別できず、
--   usage_daily.per_app_minutes に 'com.zhiliaoapp.musically' キーが**構造的に存在しない**。
--   0005 の quest_condition_met('app_under') は行の存在と is_finalized=true までは
--   fail-closed 化したが、キー欠落を coalesce(...,0) で「0分」と解釈するため、
--   確定日がありさえすれば 0 < 20 で達成になる (= キー次元では fail-open のまま)。
--   v1.1 順2 でクエスト自動評価を配線すると**全 iOS ユーザーが毎日 30pt を不正取得**
--   するため、配線より先にこの地雷を除去する (ORG_STATE: 直す順番の順0)。
--   ※ fn_evaluate_quest は authenticated に grant 済みのため、配線前の現在も
--     直接 RPC を叩けば同じ穴を突ける。順0 はその封鎖でもある。
--
-- 対処 (3点):
--   1. quest_condition_met: per_app_minutes に対象キーが無い日は未達 (false) に倒す。
--      「計測できないものは検証できない＝報酬を出さない」(0005 C-2 と同じ原則)。
--      トレードオフ: TikTok 未インストールの Android ユーザーも未達になるが、
--      "TikTok を 20 分未満に" というクエストの対象外の人であり、誤付与より安全。
--   2. quest_definitions.daily_tiktok_under_20 を is_active=false。
--      fn_sync_quests (0005) は is_active=true のみインスタンス化するため、
--      翌日以降の新規インスタンスが止まる。iOS はアプリ識別が原理的に不可能なので、
--      アプリ名指しクエストは両OSで検証可能な形 (合計時間の予算等) に再設計するまで停止。
--   3. 既存の未受取インスタンスを削除 (画面の残骸防止 + 将来の一括評価対象から除外)。
--      reward_granted=true の行は付与実績の監査証跡なので残す (現状 0 件のはず。
--      0 件でない場合は db-apply-0013 の Verify が警告する)。
--
-- 冪等: UPDATE/DELETE は再実行安全 (2回目は 0 行)。関数は create or replace。
-- 適用: .github/workflows/db-apply-0013.yml (手動 workflow_dispatch)。
-- 前提: 0001〜0012 適用済み (moffy-prod)。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. quest_condition_met: app_under のキー欠落 fail-closed 化
--    (0005 の定義を全文置換。変更点は app_under 分岐の v_has_key 判定のみ)
-- ----------------------------------------------------------------------------
create or replace function public.quest_condition_met(
  p_uid       uuid,
  p_condition jsonb,
  p_kind      public.quest_kind,
  p_period    date)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type      text := p_condition->>'type';
  v_target    integer := coalesce(
                 (p_condition->>'target')::integer,
                 (p_condition->>'minutes')::integer, 0);
  v_package   text := p_condition->>'package';
  v_period_lo date;
  v_period_hi date;
  v_val       integer;
  v_used      integer;
  v_baseline  integer;
  v_today     integer;
  v_finalized boolean;
  v_has_key   boolean;
begin
  if v_type is null then
    return false;
  end if;

  -- 期間範囲: daily は当日のみ、weekly は period_start を含む7日窓 (PRD §S14 週初日基準)。
  v_period_lo := p_period;
  if p_kind = 'weekly' then
    v_period_hi := p_period + 6;
  else
    v_period_hi := p_period;
  end if;

  case v_type
    when 'app_under' then
      if v_package is null then
        return false;
      end if;
      -- ★C-2 fail-closed (0005): 当該 period の usage_daily 行が存在し、かつサーバー確定
      --   (is_finalized=true) でなければ未達。
      -- ★0013 fail-closed: per_app_minutes に対象キーが**存在しない**日も未達。
      --   キー欠落は「利用 0 分」ではなく「そのアプリを計測できていない」(iOS は
      --   構造的に常に欠落 / Android は未インストール等)。計測できない日に
      --   報酬を出さない。キーが実在する場合のみ per_app で判定。
      select per_app_minutes ? v_package,
             coalesce((per_app_minutes->>v_package)::integer, 0), is_finalized
        into v_has_key, v_used, v_finalized
        from public.usage_daily
       where user_id = p_uid and usage_date = p_period;
      if not found or v_finalized is not true or v_has_key is not true then
        return false;
      end if;
      return v_used < v_target;

    when 'reduce_total' then
      -- 削減量 = その日の適用基準(baselines.applied_minutes) - その日の利用(total_minutes)。
      -- ★C-2 fail-closed: usage_daily 行が確定 (is_finalized=true) で、baselines も存在する
      --   場合のみ判定。行が無い/未確定 (warmup・暫定) なら未達。
      select b.applied_minutes, u.total_minutes, u.is_finalized
        into v_baseline, v_today, v_finalized
        from public.usage_daily u
        join public.baselines b
          on b.user_id = u.user_id and b.baseline_date = u.usage_date
       where u.user_id = p_uid and u.usage_date = p_period;
      if not found or v_finalized is not true
         or v_baseline is null or v_today is null then
        return false;
      end if;
      return greatest(v_baseline - v_today, 0) >= v_target;

    when 'streak_keep' then
      -- その period にストリークが維持された (last_progress_date = period)。
      select 1 into v_val
        from public.streaks
       where user_id = p_uid and last_progress_date = p_period;
      return found;

    when 'hatch_count' then
      -- 当該 period 窓内に孵化した卵数 (hatched 化された卵の updated_at がその窓)。
      select count(*)::integer into v_val
        from public.eggs
       where user_id = p_uid
         and location = 'hatched'
         and (updated_at at time zone 'UTC')::date between v_period_lo and v_period_hi;
      return coalesce(v_val, 0) >= v_target;

    when 'points_earn' then
      -- 当該 period 窓内の基礎pt獲得 (source='reduction')。固定報酬は含めない (S14)。
      select coalesce(sum(amount), 0)::integer into v_val
        from public.point_ledger
       where user_id = p_uid
         and source = 'reduction'
         and ledger_date between v_period_lo and v_period_hi;
      return coalesce(v_val, 0) >= v_target;

    else
      -- 未知type は未達。
      return false;
  end case;
end;
$$;

-- 権限は 0005 のまま (内部専用 / authenticated には revoke 済み)。create or replace は
-- 既存 ACL を保持するが、初適用環境との差異を無くすため明示的に収束させる。
revoke all on function public.quest_condition_met(uuid, jsonb, public.quest_kind, date)
  from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 2. daily_tiktok_under_20 の停止 (fn_sync_quests が翌日以降インスタンス化しなくなる)
-- ----------------------------------------------------------------------------
update public.quest_definitions
   set is_active = false
 where id = 'daily_tiktok_under_20'
   and is_active = true;


-- ----------------------------------------------------------------------------
-- 3. 既存の未受取インスタンスの掃除
--    loadQuests は user_quests を無フィルタで読む (quest_repository.dart) ため、
--    残すと「絶対に達成できないクエスト」が画面に出続ける。付与済み
--    (reward_granted=true) は監査証跡として残す (Verify で件数を警告表示)。
-- ----------------------------------------------------------------------------
delete from public.user_quests
 where quest_id = 'daily_tiktok_under_20'
   and reward_granted = false;

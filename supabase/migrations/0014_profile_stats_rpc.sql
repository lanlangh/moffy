-- ============================================================================
-- 0014: fn_profile_stats — メニュー統計のサーバー集計 RPC (v1.1 順1 / S1)
-- ============================================================================
-- 真因 (2026-08-06 実機で発覚 / ORG_STATE S1):
--   profile_repository.dart:51 の profileRepositoryProvider が条件分岐なしで
--   MockProfileRepository を返しており、メニューの統計5指標
--   (総削減時間/総獲得Mofi/図鑑達成/最長ストリーク/累計pt) が全ユーザー同一の
--   ハードコード値 (1280分/11/9/12/3640pt) だった。図鑑 1/40 vs メニュー 9/40 が
--   同一アプリ内で矛盾し、新規ユーザーにも初日から「12日連続」が出る。
-- 対処: サーバー権威データから本人分を集計する RPC を 1 本用意し、クライアントは
--   表示するだけにする (信頼境界: クライアントは集計・改ざんしない)。
--
-- 集計定義 (アプリ内の他画面と同じ定義に揃える = 同一アプリ内で矛盾させない):
--   * total_reduced_minutes: 確定日 (usage_daily.is_finalized=true) の
--       greatest(baselines.applied_minutes - total_minutes, 0) の総和。
--       quest_condition_met('reduce_total') と同じ削減量定義 (0005)。
--       warmup 等 baselines の無い日は削減 0 (join で自然に除外)。
--   * total_mofi: mofi_collection.obtained_count の総和 (重複入手も数える)。
--   * dex_discovered: mofi_collection の行数 (= distinct 種×色違い。
--       uq_collection_dex により 1 エントリ 1 行 / collection_repository.dart と同一定義)。
--   * longest_streak: streaks.longest_streak (行が無ければ 0)。
--   * total_points: point_ledger の正の amount の総和 (= 累計獲得pt。
--       spend_incubation 等の控除は含めない。残高 (profiles.point_balance) とは別概念)。
--
-- 信頼境界:
--   * security invoker (既定) + RLS: 各テーブルは 0001/0004 で select-own ポリシー済み。
--     関数内の user_id = auth.uid() 述語は二重防御 + インデックス利用のため。
--   * 読み取り専用 (stable)。書込は一切しない。
-- 冪等: create or replace / revoke・grant は再実行安全。
-- 適用: .github/workflows/db-apply-0013.yml が 0013 とまとめて適用する。
-- 前提: 0001〜0013 適用済み (moffy-prod)。
-- ============================================================================

create or replace function public.fn_profile_stats()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_reduced integer;
  v_mofi    integer;
  v_dex     integer;
  v_streak  integer;
  v_points  integer;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  -- 総削減時間(分): 確定日のみ。quest_condition_met('reduce_total') と同一定義。
  select coalesce(sum(greatest(b.applied_minutes - u.total_minutes, 0)), 0)::integer
    into v_reduced
    from public.usage_daily u
    join public.baselines b
      on b.user_id = u.user_id and b.baseline_date = u.usage_date
   where u.user_id = v_uid and u.is_finalized = true;

  -- 総獲得Mofi (重複含む) と 図鑑発見数 (行=種×色違い)。
  select coalesce(sum(obtained_count), 0)::integer, count(*)::integer
    into v_mofi, v_dex
    from public.mofi_collection
   where user_id = v_uid;

  -- 最長ストリーク (行が無ければ NULL のまま → 下で 0 に倒す)。
  select longest_streak into v_streak
    from public.streaks
   where user_id = v_uid;
  v_streak := coalesce(v_streak, 0);

  -- 累計獲得pt (正の記帳のみ / 残高ではない)。
  select coalesce(sum(amount) filter (where amount > 0), 0)::integer
    into v_points
    from public.point_ledger
   where user_id = v_uid;

  return jsonb_build_object(
    'total_reduced_minutes', v_reduced,
    'total_mofi',            v_mofi,
    'dex_discovered',        v_dex,
    'longest_streak',        v_streak,
    'total_points',          v_points);
end;
$$;

-- 権限: 本人集計なので authenticated のみ。anon/public は不可。
revoke all on function public.fn_profile_stats() from public, anon;
grant execute on function public.fn_profile_stats() to authenticated;

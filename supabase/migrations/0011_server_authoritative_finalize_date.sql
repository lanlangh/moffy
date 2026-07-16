-- ============================================================================
-- Moffy 追補マイグレーション (0011_server_authoritative_finalize_date.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-07-16 / 起因: Codex 第三者レビュー (PR #55)
-- 準拠: docs/PRD.md §S4-2 (当日分のみ確定 = その日が終了した分を翌日に確定 /
--         未来日付・過去日付の遡及加点は不可 / 日付境界の正はサーバー時刻)
--       docs/ARCHITECTURE.md §1-5 (生データ提出 → fn_finalize_day → 確定値取得)
--       supabase/migrations/0005_economy_exploit_fix.sql (fn_finalize_day 本体)
--
-- このマイグレーションが解決する問題（Codex 指摘 #1a / #1b）:
--   PR #55 で「削減 → usage_daily 提出 → fn_finalize_day 確定」の未配線を修正したが、
--   対象日を **端末時計の暦日** で決めていた。fn_finalize_day は `p_date > v_server_today`
--   （未来日）しか拒否しないため、以下の2つの穴が残っていた。
--
--   #1a 端末時計が1日進んでいると「端末の昨日」=「サーバーの今日」になり、当日確定が通る。
--       削減量 = 基準値 - 当日利用分 は時間とともに**減るだけ**なので、朝の少ない利用時間で
--       満額(480pt上限)を確定でき、その日は使い放題になる。PRD §S4-2「日付境界の正は
--       サーバー時刻」に反する（480pt上限は被害を制限するだけで境界を満たさない）。
--
--   #1b fn_finalize_day は **is_finalized を読まない**。加算は
--       idempotency_key = uid×date×'reduction' で冪等だが、これは
--       `if v_final_points > 0 then insert ... on conflict do nothing` の内側にあるため、
--       **0pt で確定した日は台帳行が作られない**。よって「確定済み日は二度と加算されない」は
--       0pt 日について偽。ある日を 0pt で確定 → その後に過去日(usage_date < p_date)を提出して
--       基準値を押し上げ → 同じ日で再度 RPC を呼ぶ、で確定済み日へ新規加点できた
--       （RLS 迂回不要 = 他の日を提出するだけで到達可能）。過去日の再実行は streaks の
--       last_progress_date を巻き戻す副作用もあった。
--
-- 解決の方針（fn_finalize_day 本体は書き換えない = 220行の複製による転記事故を避ける）:
--   1. 対象日を**サーバーが決めて返す** fn_pending_finalize_date() を新設する。
--      クライアントは端末時計で日付を決めない（S4: 日付境界の正はサーバー時刻+ユーザーTZ）。
--   2. **ガード付きラッパー** fn_finalize_ended_day(p_date) を新設し、authenticated には
--      こちらだけを grant する。fn_finalize_day(date) の直接実行権限は剥奪する。
--        - p_date >= サーバー当日 → 'day_not_ended' で拒否（#1a を境界で塞ぐ）。
--        - 既に is_finalized=true → 計算前に早期 return（#1b: 0pt 確定日への再加点と
--          streak 巻き戻しを塞ぐ）。
--   3. 本体 fn_finalize_day は definer のまま維持し、ラッパーからのみ呼ぶ。
--      auth.uid() は JWT クレーム由来なので definer 経由でも本人 uid が解決される。
--
-- 冪等性: 関数は create or replace / grant は再付与可 ＝ 再実行安全。
-- 前提: 0001〜0010 は適用済み(本番)。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. 対象日をサーバーが決める（S4: 日付境界の正 = サーバー時刻 + profiles.timezone）
-- ----------------------------------------------------------------------------
--   戻り: { target_date, server_today, already_finalized, has_usage_row }
--     * target_date      … 今クライアントが提出・確定すべき日（= サーバー当日の前日）。
--     * already_finalized… その日が確定済みか。true ならクライアントは何もしない
--                          （確定済み行は RLS usage_update_own_unfinalized で更新不可＝
--                           再提出すると権限エラーで再試行し続けるため、事前に止める）。
--     * has_usage_row    … 生データ提出済みか（未提出なら提出が必要）。
create or replace function public.fn_pending_finalize_date()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_tz           text;
  v_server_today date;
  v_target       date;
  v_finalized    boolean;
  v_found        boolean := false;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid;
  if v_tz is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  v_server_today := (now() at time zone v_tz)::date;
  -- PRD §S4-2「その日が終了した分を翌日に確定 / 遡及加点は不可」＝対象は前日ちょうど1日。
  v_target := v_server_today - 1;

  select is_finalized into v_finalized
    from public.usage_daily
   where user_id = v_uid and usage_date = v_target;
  v_found := found;

  return jsonb_build_object(
    'target_date', v_target,
    'server_today', v_server_today,
    'already_finalized', coalesce(v_finalized, false),
    'has_usage_row', v_found
  );
end;
$$;

revoke all on function public.fn_pending_finalize_date() from public, anon, authenticated;
grant execute on function public.fn_pending_finalize_date() to authenticated;


-- ----------------------------------------------------------------------------
-- 2. ガード付きラッパー（クライアントが呼べる唯一の確定入口）
-- ----------------------------------------------------------------------------
create or replace function public.fn_finalize_ended_day(p_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid          uuid := auth.uid();
  v_tz           text;
  v_server_today date;
  v_finalized    boolean;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid;
  if v_tz is null then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;
  v_server_today := (now() at time zone v_tz)::date;

  -- ★#1a: 終了していない日は確定しない（サーバー時刻が正 / 端末時計を信用しない）。
  --   本体 fn_finalize_day は未来日しか拒否しないため、当日はここで止める。
  --   当日確定を許すと「朝＝利用0分＝削減が基準値満額」で確定でき、その後使い放題になる。
  if p_date >= v_server_today then
    return jsonb_build_object('finalized', false, 'reason', 'day_not_ended');
  end if;

  -- ★#1b: 確定済みなら計算前に早期 return（0pt 確定日への再加点 / streak 巻き戻しを塞ぐ）。
  --   本体の冪等は「台帳 insert の on conflict」に依存しており、0pt 日は台帳行が無いため
  --   冪等が効かない。確定の事実は usage_daily.is_finalized が持つのでここで判定する。
  select is_finalized into v_finalized
    from public.usage_daily
   where user_id = v_uid and usage_date = p_date;
  if v_finalized is true then
    return jsonb_build_object(
      'finalized', true,
      'already_finalized', true,
      'points_awarded', 0,
      'reason', 'already_finalized'
    );
  end if;

  -- 本体へ委譲（提出済み生データの検証・基準値・倍率・上限・冪等加算はすべて本体の責務）。
  return public.fn_finalize_day(p_date);
end;
$$;

revoke all on function public.fn_finalize_ended_day(date) from public, anon, authenticated;
grant execute on function public.fn_finalize_ended_day(date) to authenticated;

-- ★本体の直接実行を禁止する（ガードを迂回して当日確定/再確定されるのを防ぐ）。
--   fn_finalize_ended_day は security definer なので、権限剥奪後も本体を呼べる。
--   ※Dart 側の呼び出し先も fn_finalize_ended_day へ変更済み
--     （lib/core/sync/usage_sync_repository.dart）。
revoke execute on function public.fn_finalize_day(date) from authenticated;


-- ============================================================================
-- 残存リスク（本マイグレーションのスコープ外 / 明記のみ）
-- ----------------------------------------------------------------------------
--   * usage_daily の「自己申告」問題は未解決のまま（受容リスク H-2 / 0004 に記載）。
--     端末は total_minutes を過少申告して削減を偽装できる。緩和は 480pt/日上限のみ。
--     本マイグレーションは「日付境界」と「確定の一度きり」を保証するだけで、
--     申告値そのものの真正性は担保しない（サーバーは OS 実利用時間を独立検証できない）。
--   * 長期未起動（数日分の未確定日）は回収しない。PRD §S4-2「過去日付の遡及加点は不可」に
--     従い、対象は常に「サーバー当日の前日」ちょうど1日。仕様変更する場合は PRD 改訂が先。
-- ============================================================================

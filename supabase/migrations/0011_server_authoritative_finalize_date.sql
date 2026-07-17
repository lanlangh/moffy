-- ============================================================================
-- Moffy 追補マイグレーション (0011_server_authoritative_finalize_date.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-07-16 / 起因: Codex 第三者レビュー (PR #55)
-- 準拠: docs/PRD.md §S4-2 (その日が終了した分を翌日に確定 / 遡及・未来加点は不可 /
--         日付境界の正はサーバー時刻 + ユーザーTZ)
--       docs/ARCHITECTURE.md §1-5 (生データ提出 → fn_finalize_day → 確定値取得)
--       supabase/migrations/0005_economy_exploit_fix.sql (fn_finalize_day 本体)
--
-- ----------------------------------------------------------------------------
-- 背景: PR #55 で「削減 → usage_daily 提出 → fn_finalize_day 確定」の未配線を修正したが、
--       Codex 第2次レビューで、ラッパー方式では塞げない穴が4つ残ることが判明した。
--       本マイグレーションは **提出と確定を1本の definer RPC に統合** して全て塞ぐ。
--
-- 解決する問題:
--   #1 対象日が強制されていない
--      旧ラッパーは `p_date >= v_server_today` しか拒否せず、`p_date < 昨日` は素通り。
--      過去日を多数 INSERT して各日を確定すれば遡及加点できた（480pt上限は「1日ごと」
--      なので総量を抑止しない）。⇒ 対象日は **サーバーが決めた「前日」ちょうど1日**のみ。
--
--   #2 profiles.timezone がクライアント更新可能
--      0004 の `grant update (display_name, timezone)` により、端末から TZ を変更できた。
--      日付計算に使う値なので、東京20時に Pacific/Kiritimati へ変えるとサーバー側が翌日に
--      なり、「まだ進行中の日」を確定できてしまう（= 当日確定 = 使い放題）。
--      ⇒ timezone の UPDATE 権限を剥奪する（アプリは timezone を書いていない＝影響なし。
--         lib/**/*.dart に timezone の書込コードは 0 件。profiles は 0006 の handle_new_user
--         が既定値 'Asia/Tokyo' で自動作成する）。
--
--   #3/#5 is_finalized 判定が原子的でない（TOCTOU / 競合）
--      旧ラッパーは `select is_finalized`（ロック無し）で判定 → 並行2要求が両方 false を読み
--      本体へ進めた。本体も行ロック後に is_finalized を再確認しない。
--      ⇒ 行ロック（for update）を取ってから判定する。READ COMMITTED では待機解除後に
--         最新のコミット済み版で WHERE を再評価するため、後発は is_finalized=true を読む。
--      ⇒ さらに「対象日の決定 → 生データ書込 → ロック → 確定」を**1トランザクション**に
--         統合し、事前照会と本送信の間のズレ（日跨ぎ・他端末の確定）を消す。
--
--   #4 実 DB では upsert が列権限で必ず拒否される（= 提出が一度も成功しない）
--      0004 の列 GRANT は INSERT=5列 / UPDATE=3列と非対称。PostgREST の merge-upsert は
--      入力全列について `ON CONFLICT DO UPDATE SET col = EXCLUDED.col` を生成し、
--      PostgreSQL は DO UPDATE SET に並ぶ全列の UPDATE 権限を**競合の有無に関係なく**
--      文の実行前に要求する。よって user_id / usage_date の UPDATE 権限不足で 42501。
--      ⇒ 書込を definer RPC 内に移し、生データ列のみをサーバーが書く（列GRANTの対象外）。
--         クライアントの usage_daily への直接 INSERT/UPDATE 権限はもはや使わない。
--
-- 冪等性: drop if exists / create or replace / grant 再付与 ＝ 再実行安全。
-- 前提: 0001〜0010 は適用済み(本番)。旧 0011（fn_finalize_ended_day 版）が適用済みでも
--       本ファイルの再実行で正しく置き換わる。
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. 旧設計（ガード付きラッパー）の撤去
-- ----------------------------------------------------------------------------
--   fn_finalize_ended_day は #1(任意の過去日) / #3(非原子的判定) / #4(列権限) を
--   塞げないため廃止する。未適用の環境でも `if exists` で無害。
drop function if exists public.fn_finalize_ended_day(date);


-- ----------------------------------------------------------------------------
-- 1. 対象日をサーバーが返す（クライアントは「どの日のOS利用データを集めるか」を知る）
-- ----------------------------------------------------------------------------
--   これは**照会専用**であり、権限境界ではない（境界は 2. の RPC が持つ）。
--   戻り: { target_date, server_today, already_finalized, has_usage_row }
--     * target_date      … 提出・確定すべき日（= サーバー当日の前日）。
--     * already_finalized… 確定済みなら true（クライアントは何もしない＝無駄な往復を省く）。
--     * has_usage_row    … 生データ提出済みか（診断・ログ用）。
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
-- 2. 提出＋確定の統合 RPC（クライアントが呼べる唯一の入口 / 権限境界はここ）
-- ----------------------------------------------------------------------------
--   引数の p_date は「クライアントがどの日のつもりで集めたか」の申告にすぎない。
--   サーバーは自分で対象日を計算し、一致しなければ拒否する（#1）。
--   ＝ 端末時計・端末TZ・任意の過去日で加点することはできない。
create or replace function public.fn_submit_and_finalize_day(
  p_date            date,
  p_total_minutes   integer,
  p_per_app_minutes jsonb,
  p_source_mode     text
)
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
  v_target := v_server_today - 1;

  -- ★#1: 対象日はサーバー権威。クライアント申告と一致しなければ拒否する。
  --   (a) 当日・未来日 → 進行中の日を確定できない（削減量は時間とともに減るだけなので、
  --       朝に確定すると満額を取ってその後使い放題になる）。
  --   (b) 前日より古い日 → 遡及加点不可（PRD §S4-2）。
  --   日跨ぎでズレた場合もここで弾かれ、クライアントは次回の起動/復帰で正しい日を再取得する。
  if p_date is distinct from v_target then
    return jsonb_build_object(
      'finalized', false,
      'reason', 'wrong_finalize_date',
      'target_date', v_target
    );
  end if;

  -- 入力検証（CHECK 制約違反を例外ではなく理由付きの戻りにする＝クライアントが再試行地獄に
  -- 陥らないように）。
  if p_total_minutes is null or p_total_minutes < 0 then
    return jsonb_build_object('finalized', false, 'reason', 'invalid_total_minutes');
  end if;
  if p_source_mode is null
     or p_source_mode not in ('exact-minutes', 'threshold-achievement') then
    return jsonb_build_object('finalized', false, 'reason', 'invalid_source_mode');
  end if;

  -- ★#4: 生データ書込は definer 権限のサーバー側で行う（列GRANT の非対称を回避）。
  --   まず行を確実に存在させる（競合時は何もしない＝後段のロックで直列化する）。
  insert into public.usage_daily(
    user_id, usage_date, total_minutes, per_app_minutes, source_mode)
  values (
    v_uid, v_target, p_total_minutes,
    coalesce(p_per_app_minutes, '{}'::jsonb), p_source_mode)
  on conflict (user_id, usage_date) do nothing;

  -- ★#3/#5: 行ロックを取ってから確定判定する（原子的）。
  --   READ COMMITTED では、先行トランザクションのコミット待ちで解除された後に
  --   最新版で WHERE を再評価するため、後発の要求は is_finalized=true を読む。
  select is_finalized into v_finalized
    from public.usage_daily
   where user_id = v_uid and usage_date = v_target
   for update;

  if v_finalized then
    -- 確定済み日の生データは上書きしない（確定値の再計算・streak 巻き戻しを防ぐ）。
    return jsonb_build_object(
      'finalized', true,
      'already_finalized', true,
      'points_awarded', 0,
      'reason', 'already_finalized'
    );
  end if;

  -- 未確定なら生データを最新値へ更新（definer / 生データ列のみ）。
  update public.usage_daily
     set total_minutes   = p_total_minutes,
         per_app_minutes = coalesce(p_per_app_minutes, '{}'::jsonb),
         source_mode     = p_source_mode
   where user_id = v_uid and usage_date = v_target;

  -- 本体へ委譲（同一トランザクション＝行ロック保持のまま）。
  -- 基準値・ウォームアップ判定・倍率・上限・冪等加算・異常値判定はすべて本体の責務。
  return public.fn_finalize_day(v_target);
end;
$$;

revoke all on function public.fn_submit_and_finalize_day(date, integer, jsonb, text)
  from public, anon, authenticated;
grant execute on function public.fn_submit_and_finalize_day(date, integer, jsonb, text)
  to authenticated;

-- ★本体の直接実行を禁止（ガードを迂回した任意日確定を防ぐ）。
--   fn_submit_and_finalize_day は security definer なので、剥奪後も本体を呼べる。
revoke execute on function public.fn_finalize_day(date) from authenticated;


-- ----------------------------------------------------------------------------
-- 3. ★#2: profiles.timezone のクライアント更新を禁止する
-- ----------------------------------------------------------------------------
--   timezone は「経済日付（どの日を確定するか）」の計算に使う = セキュリティ境界。
--   0004 では display_name と同列に扱っていたが、0011 で日付境界の根拠になったため分離する。
--   アプリは timezone を書いていない（lib/**/*.dart に書込 0 件）ので機能影響はない。
--   0006 handle_new_user が既定値 'Asia/Tokyo' で profiles を自動作成する。
revoke update on public.profiles from authenticated;
grant update (display_name) on public.profiles to authenticated;


-- ----------------------------------------------------------------------------
-- 4. クライアントの usage_daily 直接書込権限を剥奪する
-- ----------------------------------------------------------------------------
--   提出は 2. の RPC 経由のみ（definer が書く）。直接 INSERT/UPDATE の経路を残すと、
--   「確定前に生データだけ差し替える」等の抜け道になるため塞ぐ。
--   ※ select は維持（自分の履歴表示・基準値の参照に使う）。
revoke insert, update on public.usage_daily from authenticated;


-- ============================================================================
-- 残存リスク（本マイグレーションのスコープ外 / 明記のみ）
-- ----------------------------------------------------------------------------
--   * usage_daily の「自己申告」問題は未解決（受容リスク H-2 / 0004 に記載）。端末は
--     total_minutes を過少申告して削減を偽装できる。緩和は 480pt/日上限のみ。本ファイルは
--     「日付境界」「確定の一度きり」「書込経路の一本化」を保証するが、申告値そのものの
--     真正性は担保しない（サーバーは OS 実利用時間を独立検証できない）。
--   * timezone が Asia/Tokyo 固定になる（日本のみ配信のため v1.0 では許容）。将来、
--     海外配信や TZ 変更 UI を入れる場合は「経済用TZは次の安全な境界まで変更を保留する」
--     サーバー側の仕組み（申請 → 翌日反映）が必要。クライアント直接更新に戻してはならない。
--   * 長期未起動（数日分の未確定日）は回収しない。PRD §S4-2「遡及加点は不可」に従い、
--     対象は常に「サーバー当日の前日」ちょうど1日。仕様変更する場合は PRD 改訂が先。
-- ============================================================================

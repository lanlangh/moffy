-- ============================================================================
-- egg_pacing_check.sql — 0018（評価制 ◎/○/△・計測なし・R・2日目「残り全部」）の動作検証
-- ----------------------------------------------------------------------------
-- 前提: local_auth_stub.sql → 0001〜0018 を適用した **テスト用 DB**（CI の postgres サービス）。
--       本番には流さない（テストユーザーを作り、台帳と卵を書く）。
-- 合否: 期待と違えば raise exception で落ちる（CI ゲート）。
--
-- 検証する仕様（docs/design/EGG_PACING_DESIGN.md）:
--   §2-2 評価式 … R=120 で m=50 → ◎100 / m=85 → ○70 / m=120 → △15
--   §2-2 絶対ライン … R=30 で m=30 → ◎（半分=15 より 30分以内が効く）
--   §2-3 計測なし … is_measured=false → 0pt・確定済み・連続日数は据え置き
--   §2-3 古い iOS アプリ … p_is_measured 省略 + threshold-achievement → 計測なし扱い
--   §2-5 連続日数 … ◎/○ で +1、△ で 0
--   §2-1 R の上方修正 … 計測ありの確定日が 7 日たまったら中央値で上げる（下げない）
--   §3-3 初回ボーナス … day1=300、day2=孵化までの残り全部（既存の 200pt 卵も孵る）
--   クエスト reduce_total … 計測ありの 0 分（iOS）は達成、計測なしは未達
--   fn_set_usual_minutes … 選択肢以外は拒否
-- ============================================================================

\set ON_ERROR_STOP on
\echo '================ egg_pacing_check.sql 開始 ================'

-- ----------------------------------------------------------------------------
-- 共通ヘルパ（テストだけで使う / 本番に無い）
-- ----------------------------------------------------------------------------
create or replace function pg_temp.t_user(p_id uuid)
returns void language plpgsql as $$
begin
  insert into auth.users(id) values (p_id) on conflict (id) do nothing;
  -- 0006 のトリガーが profiles を作る。無ければ直接作る（保険）。
  insert into public.profiles(id) values (p_id) on conflict (id) do nothing;
  perform set_config('request.jwt.claim.sub', p_id::text, false);
end $$;

-- サーバー当日（Asia/Tokyo）の前日 = 提出・確定できる唯一の日。
create or replace function pg_temp.t_target()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Tokyo')::date - 1
$$;

-- 確定済み・計測ありの過去日を直接作る（R の上方修正の母数を作るため）。
create or replace function pg_temp.t_finalized_day(p_id uuid, p_date date, p_minutes integer)
returns void language plpgsql as $$
begin
  insert into public.usage_daily(
    user_id, usage_date, total_minutes, per_app_minutes, source_mode,
    is_finalized, is_anomaly, is_measured)
  values (p_id, p_date, p_minutes, '{}'::jsonb, 'exact-minutes', true, false, true);
end $$;

-- ----------------------------------------------------------------------------
-- 1. 評価式（R=120）: ◎ / ○ / △ とストリーク
-- ----------------------------------------------------------------------------
do $$
declare
  u_great uuid := '00000000-0000-0000-0000-00000000a001';
  u_good  uuid := '00000000-0000-0000-0000-00000000a002';
  u_poor  uuid := '00000000-0000-0000-0000-00000000a003';
  r jsonb;
  v_pts integer;
  v_streak integer;
begin
  -- ◎: 50分（<= max(30, 60)）
  perform pg_temp.t_user(u_great);
  perform public.fn_set_usual_minutes(120);
  -- 事前のストリークを 2 にしておき、+1 で 3 になることを見る
  update public.streaks set current_streak = 2 where user_id = u_great;
  insert into public.streaks(user_id, current_streak, longest_streak)
    values (u_great, 2, 2) on conflict (user_id) do update set current_streak = 2;
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 50, '{"com.x":50}'::jsonb, 'exact-minutes', true);
  if (r->>'finalized')::boolean is not true or r->>'band' <> 'great' or (r->>'points_awarded')::integer <> 100 then
    raise exception '[FAIL] R=120 m=50 は ◎100pt のはず: %', r;
  end if;
  if (r->>'streak_after')::integer <> 3 then
    raise exception '[FAIL] ◎ で連続日数が +1 になっていない: %', r;
  end if;
  select point_balance into v_pts from public.profiles where id = u_great;
  if v_pts <> 100 then
    raise exception '[FAIL] 残高に 100pt が入っていない: %', v_pts;
  end if;
  if not exists (select 1 from public.point_ledger
                  where user_id = u_great and source = 'reduction'
                    and amount = 100 and meta->>'band' = 'great'
                    and (meta->>'usual_minutes')::integer = 120
                    and meta->>'usual_minutes_source' = 'reported') then
    raise exception '[FAIL] 台帳の meta に band / usual_minutes が無い';
  end if;
  -- baselines の互換スナップショット（applied_minutes = R / stage = confirmed）
  if not exists (select 1 from public.baselines
                  where user_id = u_great and baseline_date = pg_temp.t_target()
                    and applied_minutes = 120 and stage = 'confirmed') then
    raise exception '[FAIL] baselines の互換行（applied=R, confirmed）が無い';
  end if;
  -- 冪等: もう一度提出しても加算されない
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 50, '{"com.x":50}'::jsonb, 'exact-minutes', true);
  if (r->>'already_finalized')::boolean is not true or (r->>'points_awarded')::integer <> 0 then
    raise exception '[FAIL] 再提出で二重加算: %', r;
  end if;

  -- ○: 85分（> 60, <= max(60, 90)）
  perform pg_temp.t_user(u_good);
  perform public.fn_set_usual_minutes(120);
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 85, '{"com.x":85}'::jsonb, 'exact-minutes', true);
  if r->>'band' <> 'good' or (r->>'points_awarded')::integer <> 70 then
    raise exception '[FAIL] R=120 m=85 は ○70pt のはず: %', r;
  end if;
  if (r->>'streak_after')::integer <> 1 then
    raise exception '[FAIL] ○ で連続日数が 1 になっていない: %', r;
  end if;

  -- △: 120分（> 90）。ストリークは 0 に戻る。
  perform pg_temp.t_user(u_poor);
  perform public.fn_set_usual_minutes(120);
  insert into public.streaks(user_id, current_streak, longest_streak)
    values (u_poor, 5, 5) on conflict (user_id) do update set current_streak = 5;
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 120, '{"com.x":120}'::jsonb, 'exact-minutes', true);
  if r->>'band' <> 'poor' or (r->>'points_awarded')::integer <> 15 then
    raise exception '[FAIL] R=120 m=120 は △15pt のはず: %', r;
  end if;
  select current_streak into v_streak from public.streaks where user_id = u_poor;
  if v_streak <> 0 or (r->>'streak_after')::integer <> 0 then
    raise exception '[FAIL] △ で連続日数が 0 に戻っていない: % / %', v_streak, r;
  end if;
  raise notice '=== 1. 評価式（◎/○/△・ストリーク・台帳 meta・冪等）PASS ===';
end $$;

-- ----------------------------------------------------------------------------
-- 2. 絶対ライン（R=30: 30分以内なら ◎）と 既定 R（未申告 = 120）
-- ----------------------------------------------------------------------------
do $$
declare
  u_low uuid := '00000000-0000-0000-0000-00000000a011';
  u_def uuid := '00000000-0000-0000-0000-00000000a012';
  r jsonb;
begin
  perform pg_temp.t_user(u_low);
  perform public.fn_set_usual_minutes(30);
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 30, '{"com.x":30}'::jsonb, 'exact-minutes', true);
  if r->>'band' <> 'great' then
    raise exception '[FAIL] R=30 m=30 は絶対ライン（30分以内）で ◎ のはず: %', r;
  end if;

  perform pg_temp.t_user(u_def);  -- 未申告 → 既定 120
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 60, '{"com.x":60}'::jsonb, 'exact-minutes', true);
  if r->>'band' <> 'great' or (r->>'usual_minutes')::integer <> 120
     or r->>'usual_minutes_source' <> 'default' then
    raise exception '[FAIL] 未申告は R=120（default）で評価されるはず: %', r;
  end if;
  if not exists (select 1 from public.baselines
                  where user_id = u_def and stage = 'provisional') then
    raise exception '[FAIL] 既定 R の日は baselines.stage = provisional のはず';
  end if;
  raise notice '=== 2. 絶対ライン・既定 R PASS ===';
end $$;

-- ----------------------------------------------------------------------------
-- 3. 計測なし: 0pt・確定済み・連続日数は据え置き / 古い iOS アプリは計測なし扱い
-- ----------------------------------------------------------------------------
do $$
declare
  u_unm uuid := '00000000-0000-0000-0000-00000000a021';
  u_old uuid := '00000000-0000-0000-0000-00000000a022';
  u_oldand uuid := '00000000-0000-0000-0000-00000000a023';
  r jsonb;
  v_streak integer;
  v_fin boolean;
  v_meas boolean;
begin
  perform pg_temp.t_user(u_unm);
  insert into public.streaks(user_id, current_streak, longest_streak)
    values (u_unm, 4, 4) on conflict (user_id) do update set current_streak = 4;
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 0, '{}'::jsonb, 'threshold-achievement', false);
  if (r->>'finalized')::boolean is not true or r->>'band' <> 'unmeasured'
     or (r->>'points_awarded')::integer <> 0 or (r->>'is_measured')::boolean is not false then
    raise exception '[FAIL] 計測なしは finalized=true / band=unmeasured / 0pt のはず: %', r;
  end if;
  select current_streak into v_streak from public.streaks where user_id = u_unm;
  if v_streak <> 4 then
    raise exception '[FAIL] 計測なしで連続日数が動いた: %', v_streak;
  end if;
  select is_finalized, is_measured into v_fin, v_meas
    from public.usage_daily where user_id = u_unm and usage_date = pg_temp.t_target();
  if v_fin is not true or v_meas is not false then
    raise exception '[FAIL] 計測なしの行が確定済み/is_measured=false になっていない';
  end if;
  if exists (select 1 from public.point_ledger where user_id = u_unm) then
    raise exception '[FAIL] 計測なしなのに台帳に行がある（幻の pt）';
  end if;

  -- 古い iOS アプリ（p_is_measured を送らない）→ 計測なし扱い（fail-closed）
  perform pg_temp.t_user(u_old);
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 0, '{}'::jsonb, 'threshold-achievement');
  if r->>'band' <> 'unmeasured' then
    raise exception '[FAIL] 旧 iOS アプリの 0 分は計測なし扱いのはず: %', r;
  end if;

  -- 古い Android アプリ（p_is_measured を送らない）→ 計測あり扱い
  perform pg_temp.t_user(u_oldand);
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 0, '{}'::jsonb, 'exact-minutes');
  if r->>'band' <> 'great' then
    raise exception '[FAIL] 旧 Android アプリの 0 分は計測あり（◎）のはず: %', r;
  end if;
  raise notice '=== 3. 計測なし / 旧アプリの既定 PASS ===';
end $$;

-- ----------------------------------------------------------------------------
-- 4. R の上方修正: 計測ありの確定日が 7 日たまったら直近 7 日の中央値で上げる（下げない）
-- ----------------------------------------------------------------------------
do $$
declare
  u_up uuid := '00000000-0000-0000-0000-00000000a031';
  u_dn uuid := '00000000-0000-0000-0000-00000000a032';
  r jsonb;
  v_usual integer;
  v_src text;
  i integer;
begin
  -- 既定 R=120 のまま、200分の日を 6 日分（確定・計測あり）→ 7日目に 60分 → 中央値 200 > 120 → 200 へ
  perform pg_temp.t_user(u_up);
  for i in 1..6 loop
    perform pg_temp.t_finalized_day(u_up, pg_temp.t_target() - i, 200);
  end loop;
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 60, '{"com.x":60}'::jsonb, 'exact-minutes', true);
  -- その日の評価は **修正前の R（120）** で決まる（60 <= 60 → ◎）
  if r->>'band' <> 'great' then
    raise exception '[FAIL] 修正前の R で評価されるはず（60/120 → ◎）: %', r;
  end if;
  select usual_minutes, usual_minutes_source into v_usual, v_src from public.profiles where id = u_up;
  if v_usual <> 200 or v_src <> 'measured' then
    raise exception '[FAIL] 7日の中央値 200 で R が上がっていない: % / %', v_usual, v_src;
  end if;

  -- 申告 R=300 で実測の中央値 60 → 下げない
  perform pg_temp.t_user(u_dn);
  perform public.fn_set_usual_minutes(300);
  for i in 1..6 loop
    perform pg_temp.t_finalized_day(u_dn, pg_temp.t_target() - i, 60);
  end loop;
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 60, '{"com.x":60}'::jsonb, 'exact-minutes', true);
  select usual_minutes, usual_minutes_source into v_usual, v_src from public.profiles where id = u_dn;
  if v_usual <> 300 or v_src <> 'reported' then
    raise exception '[FAIL] 実測が少なくても R を下げてはいけない: % / %', v_usual, v_src;
  end if;
  raise notice '=== 4. R の上方修正（上げる / 下げない）PASS ===';
end $$;

-- ----------------------------------------------------------------------------
-- 5. 初回ボーナス: day1=300 → day2=残り全部（200）で 500。既存の 200pt 卵は 300 で孵る。
--    初回ボーナス卵が孵化済みなら day2 は 200 をアクティブ卵へ。
-- ----------------------------------------------------------------------------
do $$
declare
  u_new uuid := '00000000-0000-0000-0000-00000000a041';
  u_legacy uuid := '00000000-0000-0000-0000-00000000a042';
  u_hatched uuid := '00000000-0000-0000-0000-00000000a043';
  r jsonb;
  v_egg uuid;
  v_pts integer;
  v_egg2 uuid;
begin
  -- 新規: day1
  perform pg_temp.t_user(u_new);
  r := public.fn_claim_warmup(1);
  if (r->>'granted')::integer <> 300 or r->>'mode' <> 'day1' then
    raise exception '[FAIL] day1 は 300pt のはず: %', r;
  end if;
  select id, growth_points into v_egg, v_pts from public.eggs
    where user_id = u_new and acquired_source = 'starter';
  if v_pts <> 300 then
    raise exception '[FAIL] 初回ボーナス卵に 300 が入っていない: %', v_pts;
  end if;
  -- day1 を再度呼んでも二重付与しない
  r := public.fn_claim_warmup(1);
  if (r->>'granted')::integer <> 0 or (r->>'already_claimed')::boolean is not true then
    raise exception '[FAIL] day1 の二重付与: %', r;
  end if;
  -- day2 = 残り全部（500-300=200）
  r := public.fn_claim_warmup(2);
  if (r->>'granted')::integer <> 200 or r->>'mode' <> 'top_up' then
    raise exception '[FAIL] day2 は残り全部（200）のはず: %', r;
  end if;
  select growth_points into v_pts from public.eggs where id = v_egg;
  if v_pts <> 500 then
    raise exception '[FAIL] day2 後に 500 になっていない: %', v_pts;
  end if;

  -- 既存ユーザー（旧 day1=200 で止まっている卵）: day2 で 300 が入って 500
  perform pg_temp.t_user(u_legacy);
  insert into public.eggs(user_id, rarity, growth_points, location, slot_index, is_active, acquired_source)
    values (u_legacy, 'normal', 200, 'incubating', 1, true, 'starter') returning id into v_egg;
  insert into public.point_ledger(user_id, ledger_date, source, amount, idempotency_key, meta)
    values (u_legacy, current_date - 30, 'warmup', 200, u_legacy::text || ':warmup:1', '{"day":1}'::jsonb);
  r := public.fn_claim_warmup(2);
  if (r->>'granted')::integer <> 300 or r->>'mode' <> 'top_up' then
    raise exception '[FAIL] 既存の 200pt 卵には残り 300 が入るはず: %', r;
  end if;
  select growth_points into v_pts from public.eggs where id = v_egg;
  if v_pts <> 500 then
    raise exception '[FAIL] 既存卵が 500 になっていない: %', v_pts;
  end if;

  -- 初回ボーナス卵が孵化済み: day2 は warmup_grants.day2（200）をアクティブ卵へ
  perform pg_temp.t_user(u_hatched);
  insert into public.eggs(user_id, rarity, growth_points, location, slot_index, is_active, acquired_source)
    values (u_hatched, 'normal', 0, 'hatched', null, false, 'starter');
  insert into public.eggs(user_id, rarity, growth_points, location, slot_index, is_active, acquired_source)
    values (u_hatched, 'rare', 10, 'incubating', 1, true, 'standard') returning id into v_egg2;
  r := public.fn_claim_warmup(2);
  if (r->>'granted')::integer <> 200 or r->>'mode' <> 'active' then
    raise exception '[FAIL] 初回ボーナス卵が孵化済みなら day2=200 をアクティブ卵へ: %', r;
  end if;
  select growth_points into v_pts from public.eggs where id = v_egg2;
  if v_pts <> 210 then
    raise exception '[FAIL] アクティブ卵に 200 が入っていない: %', v_pts;
  end if;
  raise notice '=== 5. 初回ボーナス（day1=300 / day2=残り全部 / 孵化済みは 200→アクティブ卵）PASS ===';
end $$;

-- ----------------------------------------------------------------------------
-- 6. クエスト reduce_total: 計測ありの 0 分（iOS）は達成、計測なしは未達
-- ----------------------------------------------------------------------------
do $$
declare
  u_ios0 uuid := '00000000-0000-0000-0000-00000000a051';
  u_unm  uuid := '00000000-0000-0000-0000-00000000a052';
  r jsonb;
  cond jsonb := '{"type":"reduce_total","target":30}'::jsonb;
begin
  perform pg_temp.t_user(u_ios0);
  perform public.fn_set_usual_minutes(120);
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 0, '{}'::jsonb, 'threshold-achievement', true);
  if r->>'band' <> 'great' then
    raise exception '[FAIL] 計測ありの iOS 0 分は ◎ のはず: %', r;
  end if;
  if not public.quest_condition_met(u_ios0, cond, 'daily', pg_temp.t_target()) then
    raise exception '[FAIL] 計測ありの iOS 0 分で reduce_total が未達になっている（0015 の一律除外が残っている）';
  end if;

  perform pg_temp.t_user(u_unm);
  r := public.fn_submit_and_finalize_day(pg_temp.t_target(), 0, '{}'::jsonb, 'threshold-achievement', false);
  if public.quest_condition_met(u_unm, cond, 'daily', pg_temp.t_target()) then
    raise exception '[FAIL] 計測なしの日に reduce_total が達成になっている';
  end if;
  raise notice '=== 6. クエスト reduce_total と is_measured PASS ===';
end $$;

-- ----------------------------------------------------------------------------
-- 7. fn_set_usual_minutes: 選択肢以外は拒否
-- ----------------------------------------------------------------------------
do $$
declare
  u uuid := '00000000-0000-0000-0000-00000000a061';
  ok boolean := false;
begin
  perform pg_temp.t_user(u);
  begin
    perform public.fn_set_usual_minutes(45);
  exception when others then
    if sqlerrm like '%invalid_usual_minutes%' then ok := true; end if;
  end;
  if not ok then
    raise exception '[FAIL] 選択肢に無い 45 分が通った';
  end if;
  perform public.fn_set_usual_minutes(180);
  if (select usual_minutes from public.profiles where id = u) <> 180 then
    raise exception '[FAIL] 180 分の申告が保存されていない';
  end if;
  raise notice '=== 7. fn_set_usual_minutes PASS ===';
end $$;

-- ----------------------------------------------------------------------------
-- 8. app_config の値（設計書 §3-4）
-- ----------------------------------------------------------------------------
do $$
begin
  if (select value from public.app_config where key = 'egg_thresholds') -> 'stages'
       is distinct from '[0,100,200,300,500]'::jsonb then
    raise exception '[FAIL] egg_thresholds.stages が設計値と違う';
  end if;
  if (select (value)::text::integer from public.app_config where key = 'daily_point_cap') <> 100 then
    raise exception '[FAIL] daily_point_cap が 100 でない';
  end if;
  if (select value from public.app_config where key = 'warmup_grants')
       is distinct from '{"day1":300,"day2":200}'::jsonb then
    raise exception '[FAIL] warmup_grants が設計値と違う';
  end if;
  if (select value from public.app_config where key = 'streak_multipliers')
       is distinct from '[{"days":1,"mult":1.0}]'::jsonb then
    raise exception '[FAIL] streak_multipliers が廃止値（全段×1.0）でない';
  end if;
  raise notice '=== 8. app_config PASS ===';
end $$;

select '✅ egg_pacing_check.sql 完了（全ブロック PASS）' as result;

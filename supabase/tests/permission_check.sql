-- permission_check.sql
-- 経済セキュリティ・エピックのライブ最終証明（信頼境界の検証）。
-- BACKEND_SETUP.md §3 の RPC 権限グリッド ＋ 列レベル GRANT（G-2/G-3/H4-1/M4-1/C-1/C-3）を
-- 実 DB に対して自己検証する。期待と異なれば RAISE EXCEPTION で失敗させる（CI ゲート化）。
-- migration 0001〜0011 適用後に実行する前提（DB Verify ワークフローから呼ぶ）。
-- ⚠️ 0011 で確定の入口が fn_submit_and_finalize_day 一本になり、fn_finalize_day 本体・
--    profiles.timezone・usage_daily への直接書込は剥奪された。期待値もそれに合わせてある。

\echo '================ permission_check.sql 開始 ================'

-- ============================================================
-- §3-A: RPC execute 権限グリッド（公開RPC=authenticated true/anon false、内部ヘルパ=false）
-- ============================================================
do $$
declare
  r record;
  -- 期待: proname -> (auth_can, anon_can)
  expected jsonb := jsonb_build_object(
    -- 0011: 本体 fn_finalize_day は authenticated から revoke 済み。クライアントが呼べる
    --   確定の入口は fn_submit_and_finalize_day のみ（対象日=前日の強制・行ロック・
    --   definer 書込を1トランザクションで行うガード）。本体を直接呼べると当日確定・
    --   任意の過去日への遡及加点が通ってしまうため、ここが false であることは経済の要。
    'fn_finalize_day',           jsonb_build_array(false, false),
    'fn_submit_and_finalize_day', jsonb_build_array(true,  false),
    'fn_pending_finalize_date',  jsonb_build_array(true,  false),
    'fn_hatch_egg',              jsonb_build_array(true,  false),
    'fn_grant_quest_reward',     jsonb_build_array(true,  false),
    'fn_evaluate_quest',         jsonb_build_array(true,  false),
    'fn_sync_quests',            jsonb_build_array(true,  false),
    'fn_spend_currency',         jsonb_build_array(true,  false),
    'fn_delete_account',         jsonb_build_array(true,  false),
    'fn_claim_warmup',           jsonb_build_array(true,  false),
    'fn_ensure_first_egg',       jsonb_build_array(true,  false),
    'fn_purge_deleted_accounts', jsonb_build_array(false, false),
    'fn_apply_growth',           jsonb_build_array(false, false),
    'quest_condition_met',       jsonb_build_array(false, false),
    'cfg',                       jsonb_build_array(false, false),
    'cfg_int',                   jsonb_build_array(false, false),
    'cfg_num',                   jsonb_build_array(false, false),
    'streak_multiplier',         jsonb_build_array(false, false)
  );
  exp_auth boolean;
  exp_anon boolean;
  seen text[] := array[]::text[];
  fail_count int := 0;
begin
  for r in
    select p.proname,
           has_function_privilege('authenticated', p.oid, 'execute') as auth_can,
           has_function_privilege('anon', p.oid, 'execute')          as anon_can,
           p.prosecdef as secdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (array(select jsonb_object_keys(expected)))
    order by p.proname
  loop
    seen := seen || r.proname;
    exp_auth := (expected -> r.proname ->> 0)::boolean;
    exp_anon := (expected -> r.proname ->> 1)::boolean;
    if r.auth_can is distinct from exp_auth or r.anon_can is distinct from exp_anon then
      raise warning '[§3-A FAIL] % auth=% (期待%) anon=% (期待%)',
        r.proname, r.auth_can, exp_auth, r.anon_can, exp_anon;
      fail_count := fail_count + 1;
    else
      raise notice '  [ok] % auth=% anon=% secdef=%', r.proname, r.auth_can, r.anon_can, r.secdef;
    end if;
    -- 公開・内部問わず definer であるべき（所有者権限で実行）
    if not r.secdef then
      raise warning '[§3-A FAIL] % が security definer でない', r.proname;
      fail_count := fail_count + 1;
    end if;
  end loop;

  -- 期待した関数が全て存在したか（取りこぼし＝適用漏れ）
  if array_length(seen, 1) is distinct from (select count(*)::int from jsonb_object_keys(expected)) then
    raise warning '[§3-A FAIL] 期待した関数のうち存在しないものがある。存在=% / 期待=%',
      array_length(seen, 1), (select count(*) from jsonb_object_keys(expected));
    fail_count := fail_count + 1;
  end if;

  if fail_count > 0 then
    raise exception '§3-A RPC権限グリッド検証 失敗（% 件）', fail_count;
  end if;
  raise notice '=== §3-A RPC権限グリッド PASS ===';
end $$;

-- ============================================================
-- §3-A-2: 確定経路の中核RPCは「引数シグネチャ」まで一致すること（0011）
--   §3-A は proname だけで照合し、存在確認も「取得行数 = 期待キー数」の比較なので、
--   期待する関数が消え **同名・別引数の関数が1つ残っている**場合でも通過してしまう
--   （Codex 第3次レビュー #2）。経済の要である確定経路だけはシグネチャを固定する。
--   ※ db-apply-0011.yml も同じ検査をするが、恒常的な DB Verify にも同じ厳密さが必要。
-- ============================================================
do $$
declare
  fail_count int := 0;
begin
  if to_regprocedure('public.fn_submit_and_finalize_day(date,integer,jsonb,text)') is null then
    raise warning '[§3-A-2 FAIL] fn_submit_and_finalize_day(date,integer,jsonb,text) が存在しない';
    fail_count := fail_count + 1;
  end if;
  if to_regprocedure('public.fn_pending_finalize_date()') is null then
    raise warning '[§3-A-2 FAIL] fn_pending_finalize_date() が存在しない';
    fail_count := fail_count + 1;
  end if;
  if to_regprocedure('public.fn_finalize_day(date)') is null then
    raise warning '[§3-A-2 FAIL] fn_finalize_day(date) が存在しない';
    fail_count := fail_count + 1;
  end if;
  -- 旧ラッパー（p_date < 当日 なら任意の過去日を通し、遡及加点を許した設計）は撤去済みであること。
  if to_regprocedure('public.fn_finalize_ended_day(date)') is not null then
    raise warning '[§3-A-2 FAIL] 旧ラッパー fn_finalize_ended_day(date) が残っている（遡及加点の経路）';
    fail_count := fail_count + 1;
  end if;

  if fail_count > 0 then
    raise exception '§3-A-2 中核RPCのシグネチャ検証 失敗（% 件）', fail_count;
  end if;
  raise notice '=== §3-A-2 中核RPCのシグネチャ PASS ===';
end $$;

-- ============================================================
-- §3-A-3: 経済日付の根拠（profiles.timezone）が正規化されていること（0011 / #1）
--   ACL を閉じても、0011 適用**前**に改ざんされた既存値は残る。RPC はその値を読んで
--   対象日を計算するため、'Asia/Tokyo' 以外が1行でもあると当日確定が継続可能になる。
--   本アプリは日本のみ配信で timezone を書く実装が無い ＝ 他の値は不正。
-- ============================================================
do $$
declare
  v_bad int;
begin
  select count(*) into v_bad
    from public.profiles
   where timezone is distinct from 'Asia/Tokyo';
  if v_bad > 0 then
    raise exception '§3-A-3 FAIL: timezone が Asia/Tokyo でない profiles 行が % 件ある（0011 の正規化漏れ）', v_bad;
  end if;
  raise notice '=== §3-A-3 経済日付TZの正規化 PASS ===';
end $$;

-- ============================================================
-- §3-A-4: 基準値の母集団は「確定済み日」だけであること（0012 / fail-closed）
--   fn_finalize_day の基準値クエリが is_anomaly=false しか要求していないと、直接 INSERT
--   された未確定行（既定 is_finalized=false / is_anomaly=false）が平均に入る。欠損日は
--   除外される仕様なので、窓内に高い total_minutes の行を1つ注入するだけで基準値が上がり、
--   削減量が水増しされて日次上限まで加点できてしまう。
--   0011 で直接書込は剥奪したが、REVOKE はテーブルをロックせず、適用前の行も残るため
--   ACL だけでは塞ぎきれない。本質的な防御はこのフィルタ（0005 quest_condition_met の
--   C-2 fail-closed と同じ原則）。
-- ============================================================
do $$
declare
  v_src text;
begin
  select p.prosrc into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_finalize_day';
  if v_src is null then
    raise exception '§3-A-4 FAIL: fn_finalize_day が存在しない';
  end if;
  if v_src not like '%and is_finalized = true%' then
    raise exception '§3-A-4 FAIL: fn_finalize_day の基準値クエリに is_finalized=true が無い（0012 未適用＝未確定の注入行が基準値に効く）';
  end if;
  raise notice '=== §3-A-4 基準値の母集団=確定済み日のみ PASS ===';
end $$;

-- ============================================================
-- §3-B: 列レベル GRANT ホワイトリスト（authenticated）
--   正: 許可されているべき列 / 負: 課金通貨・確定フラグ等は不可
-- ============================================================
do $$
declare
  fail_count int := 0;
  -- (table, column, priv, expected) の検証セット
  checks text[][] := array[
    -- == 負（false であるべき）== 経済セキュリティの核心 ==
    array['usage_daily','is_finalized','INSERT','false'],  -- H4-1
    array['usage_daily','is_finalized','UPDATE','false'],  -- H4-1
    array['usage_daily','is_anomaly','INSERT','false'],    -- M4-1
    array['usage_daily','is_anomaly','UPDATE','false'],    -- M4-1
    array['profiles','gem_balance','UPDATE','false'],      -- G-2 課金通貨改ざん防止
    array['profiles','point_balance','UPDATE','false'],    -- G-2
    array['profiles','pooled_points','UPDATE','false'],    -- G-2
    array['profiles','is_linked','UPDATE','false'],        -- G-2
    array['profiles','deleted_at','UPDATE','false'],       -- G-2 / F-03
    array['eggs','growth_points','UPDATE','false'],        -- G-3 即孵化チート防止
    array['eggs','hatched_into','UPDATE','false'],         -- H-1 / C-3 再孵化防止
    array['eggs','rarity','UPDATE','false'],               -- G-3
    array['user_quests','is_completed','UPDATE','false'],  -- C-1 報酬偽造防止
    array['user_quests','reward_granted','UPDATE','false'],-- C-1
    -- 0011 #2: timezone は「経済日付（どの日を確定するか）」の計算根拠＝セキュリティ境界。
    --   クライアントが書けると、東京20時に Pacific/Kiritimati へ変えてサーバーを翌日扱いに
    --   させ、「まだ進行中の日」を確定できる（= 当日確定 = 満額取って使い放題）。
    array['profiles','timezone','UPDATE','false'],
    -- 0011 #4: usage_daily への直接書込は全面剥奪。提出は fn_submit_and_finalize_day
    --   （definer）経由のみ。列GRANTの非対称（INSERT=5列/UPDATE=3列）で PostgREST の
    --   merge-upsert が必ず 42501 になる問題も、書込をサーバーへ寄せることで解消する。
    array['usage_daily','total_minutes','INSERT','false'],
    array['usage_daily','source_mode','INSERT','false'],
    array['usage_daily','total_minutes','UPDATE','false'],
    array['usage_daily','per_app_minutes','UPDATE','false'],
    -- == 正（true であるべき）== 正規の書込み列 ==
    array['profiles','display_name','UPDATE','true'],
    array['eggs','slot_index','UPDATE','true'],
    array['eggs','location','UPDATE','true'],
    array['eggs','is_active','UPDATE','true'],
    array['user_quests','progress','UPDATE','true']
  ];
  c text[];
  actual boolean;
  expected boolean;
begin
  foreach c slice 1 in array checks loop
    actual := has_column_privilege('authenticated', ('public.'||c[1])::regclass, c[2], c[3]);
    expected := c[4]::boolean;
    if actual is distinct from expected then
      raise warning '[§3-B FAIL] authenticated %.% %=% (期待%)', c[1], c[2], c[3], actual, expected;
      fail_count := fail_count + 1;
    end if;
  end loop;

  -- C-2: user_quests へのクライアント INSERT は剥奪済みであるべき（テーブル権限）
  if has_table_privilege('authenticated', 'public.user_quests'::regclass, 'INSERT') then
    raise warning '[§3-B FAIL] authenticated が user_quests に INSERT 可（C-2 クエスト捏造経路）';
    fail_count := fail_count + 1;
  end if;

  -- 0011 #4: usage_daily へのクライアント直接書込は剥奪済みであるべき（テーブル権限）。
  --   提出経路は fn_submit_and_finalize_day（definer）のみ。直接書込が残っていると
  --   「確定前に生データだけ差し替える」抜け道になる。
  if has_table_privilege('authenticated', 'public.usage_daily'::regclass, 'INSERT') then
    raise warning '[§3-B FAIL] authenticated が usage_daily に INSERT 可（0011 提出経路の一本化が破れている）';
    fail_count := fail_count + 1;
  end if;
  if has_table_privilege('authenticated', 'public.usage_daily'::regclass, 'UPDATE') then
    raise warning '[§3-B FAIL] authenticated が usage_daily に UPDATE 可（0011 提出経路の一本化が破れている）';
    fail_count := fail_count + 1;
  end if;

  -- 0011 #1(5次): profiles への INSERT も剥奪済みであるべき。0001 の profiles_insert_own
  --   RLS が残るため、プロフィール行が欠損しているユーザーは任意の timezone 付きで
  --   INSERT でき、UPDATE を塞いでも同じ穴が空く。行生成は 0006 handle_new_user
  --   (definer トリガ) の責務。
  if has_table_privilege('authenticated', 'public.profiles'::regclass, 'INSERT') then
    raise warning '[§3-B FAIL] authenticated が profiles に INSERT 可（任意timezoneで行を作れる＝当日確定の穴）';
    fail_count := fail_count + 1;
  end if;

  if fail_count > 0 then
    raise exception '§3-B 列レベルGRANT検証 失敗（% 件）', fail_count;
  end if;
  raise notice '=== §3-B 列レベルGRANT（課金通貨/確定フラグ/報酬の改ざん封鎖）PASS ===';
end $$;

-- ============================================================
-- §3-C: ランタイム実証（A-5 / H4-1）
--   authenticated ロールで is_finalized 付き INSERT を試み、権限拒否で失敗することを確認。
--   ※ 0011 以降、usage_daily は INSERT 自体が剥奪されたため、拒否はテーブル権限レベルで
--     起きる（0010 までは is_finalized の列権限で起きていた）。どちらでも 42501 で拒否
--     されることに変わりはなく、本ブロックの合否は変わらない。
--   ※ 真の合否判定は §3-B（has_column_privilege / has_table_privilege）。
--     本ブロックは実挙動のデモ（best-effort）。
-- ============================================================
do $$
declare
  ok boolean := false;
begin
  begin
    set local role authenticated;
  exception when others then
    raise notice '  [skip] §3-C: set role authenticated 不可（%）。§3-B が権限を保証済み。', sqlerrm;
    return;
  end;

  begin
    insert into public.usage_daily(user_id, usage_date, total_minutes, per_app_minutes, source_mode, is_finalized)
    values ('00000000-0000-0000-0000-000000000000', current_date, 0, '{}'::jsonb, 'exact-minutes', true);
    -- ここに到達したら偽造成功＝重大欠陥
    raise exception '[§3-C FAIL] authenticated が is_finalized=true 付き行を INSERT できた（H4-1 破れ）';
  exception
    when insufficient_privilege then
      if sqlerrm ilike '%is_finalized%' or sqlerrm ilike '%column%' then
        ok := true;
        raise notice '  [ok] H4-1 ランタイム実証: is_finalized 付き INSERT は列権限拒否（42501 / %）', sqlerrm;
      else
        raise notice '  [info] 42501 だが列メッセージ不一致（RLS等の可能性）: %', sqlerrm;
        ok := true; -- 少なくとも拒否はされた
      end if;
  end;

  reset role;
  if not ok then
    raise exception '[§3-C FAIL] H4-1 ランタイム検証が想定外';
  end if;
  raise notice '=== §3-C H4-1 ランタイム実証 PASS ===';
end $$;

select '✅ permission_check.sql 完了（全ブロック PASS）' as result;

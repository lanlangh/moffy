-- ============================================================================
-- 抽選分布検証クエリ (distribution_check.sql)
-- ----------------------------------------------------------------------------
-- 目的: fn_hatch_egg の抽選ロジック (drop_tables 重み → Mofiレアリティ → 個体均等 →
--       色違い独立2%) が PRD §4 の理論値に収束するかを、ライブDBで N回試行して検証する。
--
-- 前提: 0001_init.sql + 0002_economy_rpcs.sql 適用済みの DB に psql で接続して実行。
--   psql "$DATABASE_URL" -f supabase/tests/distribution_check.sql
--
-- 注意: fn_hatch_egg は auth.uid() と実データ(卵/図鑑)に依存するため、ここでは
--   「抽選の数学的核」だけを fn_hatch_egg と同一ロジックで再現して分布検証する
--   (RPC本体は security definer で副作用を伴うため、純粋抽選を切り出して検証)。
--   ロジックは 0002 の fn_hatch_egg と1:1で一致させてある (レビュー時に突合すること)。
--
-- 合否: 各セルの実測比率が理論値 ±許容 (tolerance) 内なら PASS。
--   N=200000 程度で SSR(0.3%) でも十分収束する。許容は理論値の相対±15% + 絶対0.002。
-- ============================================================================

\set N 200000

-- ----------------------------------------------------------------------------
-- 1. 卵レア → Mofiレア 分布検証 (§4-2)
-- ----------------------------------------------------------------------------
-- fn_hatch_egg と同じ累積判定 (common→rare→sr→ssr, 残余はssr) を再現。
do $$
declare
  v_n        integer := 200000;
  v_egg      public.egg_rarity;
  v_dist     jsonb;
  v_roll     numeric;
  v_cum      numeric;
  v_rar      text;
  v_count    jsonb;
  i          integer;
  v_expected numeric;
  v_actual   numeric;
  v_tol      numeric;
  v_fail     integer := 0;
  k          text;
begin
  raise notice '=== §4-2 卵レア→Mofiレア 分布検証 (N=% / 各卵レア) ===', v_n;
  for v_egg in select egg_rarity from public.drop_tables order by egg_rarity loop
    select distribution into v_dist from public.drop_tables where egg_rarity = v_egg;
    v_count := jsonb_build_object('common',0,'rare',0,'sr',0,'ssr',0);

    for i in 1..v_n loop
      v_roll := random();
      v_cum := coalesce((v_dist->>'common')::numeric, 0);
      if v_roll < v_cum then v_rar := 'common';
      else
        v_cum := v_cum + coalesce((v_dist->>'rare')::numeric, 0);
        if v_roll < v_cum then v_rar := 'rare';
        else
          v_cum := v_cum + coalesce((v_dist->>'sr')::numeric, 0);
          if v_roll < v_cum then v_rar := 'sr';
          else v_rar := 'ssr';
          end if;
        end if;
      end if;
      v_count := jsonb_set(v_count, array[v_rar],
                   to_jsonb((v_count->>v_rar)::integer + 1));
    end loop;

    -- 各レアの実測比率 vs 理論値。
    foreach k in array array['common','rare','sr','ssr'] loop
      v_expected := coalesce((v_dist->>k)::numeric, 0);
      v_actual   := (v_count->>k)::numeric / v_n;
      -- 許容: 相対±15% + 絶対0.002 (低確率セルの揺らぎ吸収)。
      v_tol := greatest(v_expected * 0.15, 0.002);
      if abs(v_actual - v_expected) > v_tol then
        raise warning '  [FAIL] egg=% rarity=% expected=% actual=% (tol=%)',
          v_egg, k, v_expected, round(v_actual,5), round(v_tol,5);
        v_fail := v_fail + 1;
      else
        raise notice '  [ok]  egg=% rarity=% expected=% actual=%',
          v_egg, k, v_expected, round(v_actual,5);
      end if;
    end loop;
  end loop;

  if v_fail > 0 then
    raise exception '§4-2 分布検証 FAILED: % セルが許容外', v_fail;
  end if;
  raise notice '=== §4-2 PASS ===';
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. 色違い独立率検証 (§4-3 / S13: 2.0% = 1/50)
-- ----------------------------------------------------------------------------
do $$
declare
  v_n       integer := 200000;
  v_rate    numeric := public.cfg_num('shiny_rate', 0.02);
  v_hits    integer := 0;
  i         integer;
  v_actual  numeric;
  v_tol     numeric;
begin
  raise notice '=== §4-3 色違い率検証 (N=% / shiny_rate=%) ===', v_n, v_rate;
  for i in 1..v_n loop
    if random() < v_rate then v_hits := v_hits + 1; end if;
  end loop;
  v_actual := v_hits::numeric / v_n;
  v_tol := greatest(v_rate * 0.10, 0.001);  -- 相対±10% + 絶対0.001
  if abs(v_actual - v_rate) > v_tol then
    raise exception '色違い率 FAIL: expected=% actual=% (tol=%)',
      v_rate, round(v_actual,5), round(v_tol,5);
  end if;
  raise notice '  [ok] shiny expected=% actual=% -> PASS', v_rate, round(v_actual,5);
end;
$$;

-- ----------------------------------------------------------------------------
-- 3. 個体均等抽選の検証 (§4-2 後段: レアリティ内は均等)
-- ----------------------------------------------------------------------------
-- 例: SR個体4種 (slime_05/dragon_03/dragon_04/beast_04) が各1/4に収束するか（種数は動的取得）。
do $$
declare
  v_n      integer := 90000;
  v_id     text;
  v_count  jsonb := '{}'::jsonb;
  v_total  integer;
  i        integer;
  rec      record;
  v_actual numeric;
begin
  raise notice '=== §4-2後段 SR個体均等抽選検証 (N=%) ===', v_n;
  select count(*) into v_total from public.mofi_species
    where rarity = 'sr' and is_active = true;
  for i in 1..v_n loop
    select id into v_id from public.mofi_species
      where rarity = 'sr' and is_active = true
      order by random() limit 1;
    v_count := jsonb_set(v_count, array[v_id],
                 to_jsonb(coalesce((v_count->>v_id)::integer, 0) + 1));
  end loop;

  for rec in select id from public.mofi_species
               where rarity = 'sr' and is_active = true loop
    v_actual := coalesce((v_count->>rec.id)::numeric, 0) / v_n;
    raise notice '  SR % : actual=% (expected=%)',
      rec.id, round(v_actual,4), round(1.0/v_total,4);
    if abs(v_actual - 1.0/v_total) > 0.03 then
      raise exception 'SR個体均等 FAIL: % actual=%', rec.id, round(v_actual,4);
    end if;
  end loop;
  raise notice '=== §4-2後段 PASS ===';
end;
$$;

-- ----------------------------------------------------------------------------
-- 4. drop_tables 各行合計=1.0 の整合検証 (§4-2 / QA観点5)
-- ----------------------------------------------------------------------------
do $$
declare
  rec record;
  v_sum numeric;
begin
  raise notice '=== drop_tables 合計=1.0 検証 ===';
  for rec in select egg_rarity, distribution from public.drop_tables loop
    v_sum := coalesce((rec.distribution->>'common')::numeric,0)
           + coalesce((rec.distribution->>'rare')::numeric,0)
           + coalesce((rec.distribution->>'sr')::numeric,0)
           + coalesce((rec.distribution->>'ssr')::numeric,0);
    if abs(v_sum - 1.0) > 1e-9 then
      raise exception 'drop_table % 合計が1.0でない: %', rec.egg_rarity, v_sum;
    end if;
    raise notice '  egg=% sum=% [ok]', rec.egg_rarity, v_sum;
  end loop;
  raise notice '=== 合計検証 PASS ===';
end;
$$;

-- 全DOブロックが例外なく完了すれば全PASS。
select '✅ distribution_check.sql 完了（上の notice/warning を確認）' as result;

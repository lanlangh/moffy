#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""0018_egg_pacing_bands.sql を生成する（既存関数の本体を機械抽出して差し替える）。

なぜスクリプトで作るか（0012 / 0016 と同じ作法）:
  fn_finalize_day / fn_claim_warmup / fn_submit_and_finalize_day / quest_condition_met は
  それぞれ 0016 / 0016 / 0011 / 0015 が最新定義。手で転記すると既存ロジック
  （行ロック・異常値判定・冪等キー・権限の再掲 …）を取りこぼす。
  ここでは **最新定義をそのまま抽出し、変える箇所だけをアンカー付きで置換**する。
  アンカーが見つからない／複数ある場合は AssertionError で止まる（黙って別物を作らない）。

使い方:
  python3 tools/db/gen_migration_0018.py
  → supabase/migrations/0018_egg_pacing_bands.sql を上書きする。
    出力を直したいときは**このスクリプトを直して再生成**する（SQL を手で編集しない）。
"""
from __future__ import annotations

import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MIG = os.path.join(ROOT, 'supabase', 'migrations')
OUT = os.path.join(MIG, '0018_egg_pacing_bands.sql')


def read(name: str) -> str:
    with io.open(os.path.join(MIG, name), encoding='utf-8') as f:
        return f.read()


def extract_function(sql: str, name: str) -> str:
    """`create or replace function public.<name>(` から直後の `\n$$;` までを返す。"""
    head = 'create or replace function public.%s(' % name
    starts = [m.start() for m in re.finditer(re.escape(head), sql)]
    assert len(starts) == 1, '%s: 定義が %d 個（1個のはず）' % (name, len(starts))
    start = starts[0]
    end = sql.index('\n$$;', start) + len('\n$$;')
    return sql[start:end]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    n = text.count(old)
    assert n == 1, '%s: アンカーが %d 箇所（1箇所のはず）:\n%s' % (label, n, old[:120])
    return text.replace(old, new)


def between(text: str, start_anchor: str, end_anchor: str, label: str):
    """start_anchor の先頭から end_anchor の末尾までの (start, end) を返す。どちらも1回だけ出ること。"""
    assert text.count(start_anchor) == 1, '%s: 開始アンカーが一意でない' % label
    assert text.count(end_anchor) == 1, '%s: 終了アンカーが一意でない' % label
    s = text.index(start_anchor)
    e = text.index(end_anchor) + len(end_anchor)
    assert s < e, '%s: アンカーの順序が逆' % label
    return s, e


# ============================================================================
# 1. fn_finalize_day（0016 版を土台に、基準値→評価制へ）
# ============================================================================
def build_finalize_day(src_0016: str) -> str:
    fn = extract_function(src_0016, 'fn_finalize_day')

    # --- (a) declare ブロックを差し替える（基準値用の変数を評価用に） ---
    s, e = between(fn, 'declare\n  v_uid           uuid := auth.uid();',
                   "  v_egg_result    jsonb := 'null'::jsonb;\n", 'finalize/declare')
    new_declare = """declare
  v_uid           uuid := auth.uid();
  v_tz            text;
  v_server_today  date;
  v_today_minutes integer;
  v_is_measured   boolean;
  v_source_mode   text;
  v_is_anomaly    boolean;
  v_minutes_max   integer;       -- daily_minutes_max (異常値しきい値)
  v_window_days   integer;       -- ★0018: 実測で R を上方修正する母数（7日）
  v_cap           integer;       -- daily_point_cap
  v_bands         jsonb;         -- ★0018: daily_bands（◎/○/△ の条件と pt）
  v_usual         integer;       -- ★0018: R = ふだんのSNS時間（分）
  v_usual_source  text;          -- ★0018: 'default' / 'reported' / 'measured'
  v_great_limit   integer;       -- ★0018: ◎ になる上限（分）
  v_good_limit    integer;       -- ★0018: ○ になる上限（分）
  v_band          text;          -- ★0018: 'great' / 'good' / 'poor' / 'unmeasured'
  v_raw_avg       numeric(8,2);  -- baselines スナップショット互換（常に null）
  v_sample_days   integer;       -- baselines スナップショット互換（計測ありの確定日数）
  v_applied_min   integer;       -- baselines スナップショット互換（= R）
  v_stage         public.baseline_stage;
  v_reduced       integer;
  v_base_points   integer;
  v_mult          numeric := 1.0; -- ★0018: 倍率は廃止（互換のため 1.0 固定で記録）
  v_final_points  integer;
  v_capped        boolean := false;
  v_idem          text;
  v_rowcount      integer := 0;
  v_inserted      boolean := false;
  v_streak_cur    integer;
  v_streak_last   date;
  v_streak_after  integer;
  v_median        numeric;
  v_egg_result    jsonb := 'null'::jsonb;
"""
    fn = fn[:s] + new_declare + fn[e:]

    # --- (b) 生データの読み取りに is_measured / source_mode を足す ---
    fn = replace_once(
        fn,
        """  select total_minutes
    into v_today_minutes
    from public.usage_daily
   where user_id = v_uid and usage_date = p_date
   for update;   -- 行ロック (同時 finalize の競合防止)""",
        """  select total_minutes, is_measured, source_mode
    into v_today_minutes, v_is_measured, v_source_mode
    from public.usage_daily
   where user_id = v_uid and usage_date = p_date
   for update;   -- 行ロック (同時 finalize の競合防止)""",
        'finalize/select usage')

    # --- (c) 設定の読み取り ---
    fn = replace_once(
        fn,
        """  -- SSOT 読み取り (マジックナンバー禁止)。
  v_minutes_max := public.cfg_int('daily_minutes_max', 1440);
  v_window_days := public.cfg_int('baseline_window_days', 7);
  v_floor_min   := public.cfg_int('baseline_floor_min', 30);
  v_ppm         := public.cfg_int('point_per_minute', 1);
  v_cap         := public.cfg_int('daily_point_cap', 480);
""",
        """  -- SSOT 読み取り (マジックナンバー禁止)。
  -- ★0018: baseline_floor_min / point_per_minute は使わない（評価制）。
  v_minutes_max := public.cfg_int('daily_minutes_max', 1440);
  v_window_days := public.cfg_int('baseline_window_days', 7);
  v_cap         := public.cfg_int('daily_point_cap', 100);
  v_bands       := public.cfg('daily_bands',
                     '{"great":{"abs_min":30,"ratio":0.5,"points":100},"good":{"abs_min":60,"ratio":0.75,"points":70},"poor":{"points":15}}'::jsonb);
""",
        'finalize/config')

    # --- (d) 基準値〜倍率・上限の計算を、評価制（◎/○/△/計測なし）へ差し替える ---
    s, e = between(fn, '  -- 基準値 = 本日(p_date)を含まない直近 window 日平均 (欠損除外 / S11)。',
                   """  if v_final_points > v_cap then
    v_final_points := v_cap;
    v_capped := true;
  end if;
""", 'finalize/core')
    core_old = fn[s:e]
    # ストリーク現状取得は既存のまま使う（抽出した本体から切り出す）。
    ss, se = between(core_old, '  -- ストリーク現状取得 (倍率算出のため。streaks 行が無ければ0)。',
                     """    v_streak_cur := 0;
    v_streak_last := null;
  end if;
""", 'finalize/streak fetch')
    streak_fetch = core_old[ss:se].replace(
        '  -- ストリーク現状取得 (倍率算出のため。streaks 行が無ければ0)。',
        '  -- ストリーク現状取得 (streaks 行が無ければ0)。')
    core_new = """  -- ★0018: 基準 R = 「ふだんのSNS時間」（本人申告 → 実測で上方修正のみ）。
  --   以前の「直近7日平均との差」は、減らした状態が続くほど基準が下がって報われなく
  --   なる構造だった（docs/design/EGG_PACING_REDESIGN.md §3-B）。R は自動では下げない。
  select usual_minutes, usual_minutes_source
    into v_usual, v_usual_source
    from public.profiles where id = v_uid;
  if v_usual is null then
    v_usual := public.cfg_int('usual_minutes_default', 120);
    v_usual_source := 'default';
  end if;
  v_usual_source := coalesce(v_usual_source, 'default');

""" + streak_fetch + """
  -- ★0018: 計測なし（権限なし / iOS で対象アプリ未選択 / 古い iOS アプリ）は評価しない。
  --   0pt・卵は進まない・連続日数は据え置き（責めない）。確定済みにはする（再提出させない）。
  --   これで「計測できていない日から出続ける幻の 30pt」（0分 − 下限30分）が消える。
  if v_is_measured is not true then
    update public.usage_daily
      set is_finalized = true,
          is_anomaly = false
      where user_id = v_uid and usage_date = p_date;
    return jsonb_build_object(
      'finalized', true,
      'points_awarded', 0,
      'base_points', 0,
      'multiplier', 1.0,
      'baseline_minutes', v_usual,
      'reduced_minutes', 0,
      'capped', false,
      'stage', 'unmeasured',
      'band', 'unmeasured',
      'is_measured', false,
      'usual_minutes', v_usual,
      'usual_minutes_source', v_usual_source,
      'today_minutes', v_today_minutes,
      'streak_after', v_streak_cur,
      'egg_applied', 'null'::jsonb,
      'already_finalized', false
    );
  end if;

  -- ★0018: 1日の評価（docs/design/EGG_PACING_DESIGN.md §2-2）。
  --   ◎ しっかり離れた日: m <= max(30, R/2)      → 100pt
  --   ○ 減らした日      : m <= max(60, R*3/4)    →  70pt
  --   △ 多めだった日    : それ以外               →  15pt
  --   絶対ライン（30分/60分）は、ふだんから少ない人（R=30/60）が ◎○ を取れるようにするため。
  v_great_limit := greatest(
    coalesce((v_bands->'great'->>'abs_min')::integer, 30),
    floor(v_usual * coalesce((v_bands->'great'->>'ratio')::numeric, 0.5))::integer);
  v_good_limit := greatest(
    coalesce((v_bands->'good'->>'abs_min')::integer, 60),
    floor(v_usual * coalesce((v_bands->'good'->>'ratio')::numeric, 0.75))::integer);

  if v_today_minutes <= v_great_limit then
    v_band := 'great';
    v_base_points := coalesce((v_bands->'great'->>'points')::integer, 100);
  elsif v_today_minutes <= v_good_limit then
    v_band := 'good';
    v_base_points := coalesce((v_bands->'good'->>'points')::integer, 70);
  else
    v_band := 'poor';
    v_base_points := coalesce((v_bands->'poor'->>'points')::integer, 15);
  end if;

  -- 互換値: 削減量 = max(R − m, 0)（クエスト reduce_total / 統計の「総削減時間」が使う）。
  v_reduced := greatest(v_usual - v_today_minutes, 0);
  v_applied_min := v_usual;
  v_raw_avg := null;
  select count(*)::integer into v_sample_days
    from public.usage_daily
   where user_id = v_uid
     and usage_date < p_date
     and is_finalized = true
     and is_measured = true
     and is_anomaly = false;
  -- baselines.stage は enum（warmup/provisional/confirmed）。申告・実測済みなら confirmed、
  -- 既定値のままなら provisional と記録する（監査用の互換。計算には使わない）。
  if v_usual_source in ('reported', 'measured') then
    v_stage := 'confirmed';
  else
    v_stage := 'provisional';
  end if;

  -- 1日上限（倍率は廃止＝ v_mult は 1.0 固定）。
  v_final_points := v_base_points;
  if v_final_points > v_cap then
    v_final_points := v_cap;
    v_capped := true;
  end if;
"""
    fn = fn[:s] + core_new + fn[e:]

    # --- (e) 台帳 meta に評価を記録する ---
    fn = replace_once(
        fn,
        """      jsonb_build_object(
        'reduced_minutes', v_reduced,
        'baseline_minutes', v_applied_min,
        'today_minutes', v_today_minutes,
        'base_points', v_base_points,
        'multiplier', v_mult,
        'capped', v_capped,
        'stage', v_stage))""",
        """      jsonb_build_object(
        'reduced_minutes', v_reduced,
        'baseline_minutes', v_applied_min,
        'today_minutes', v_today_minutes,
        'base_points', v_base_points,
        'multiplier', v_mult,
        'capped', v_capped,
        'stage', v_stage,
        'band', v_band,
        'is_measured', true,
        'usual_minutes', v_usual,
        'usual_minutes_source', v_usual_source))""",
        'finalize/ledger meta')

    # --- (f) 連続日数: ◎/○ で +1、△ で 0 に戻す（計測なしは上で据え置き済み） ---
    fn = replace_once(
        fn,
        """  -- ストリーク更新 (S2,S14): その日の削減プラス(reduced>0)なら継続、0/マイナスならリセット。
  if v_streak_last is distinct from p_date then
    if v_reduced > 0 then""",
        """  -- ストリーク更新: ★0018 ◎/○ なら継続、△ ならリセット（計測なしは上で据え置き）。
  if v_streak_last is distinct from p_date then
    if v_band in ('great', 'good') then""",
        'finalize/streak update')

    # --- (g) R の実測上方修正（計測ありの確定日が 7 日たまったら、直近 7 日の中央値で上げる） ---
    fn = replace_once(
        fn,
        """  -- 連動: 確定ptをアクティブ卵へ反映 (新規確定時のみ / 二重反映しない)。""",
        """  -- ★0018: R の実測上方修正（上げる方向だけ / 自動では下げない）。
  --   計測ありの確定日（今日を含む）が window 日（7）以上たまったら、直近 window 日の
  --   中央値が R より大きいときだけ R をその値に上げる。一度 'measured' になったら再修正しない。
  --   下げない理由: 減らした状態が続いて基準が下がると報われなくなる（本設計の核心）。
  if v_inserted and v_usual_source is distinct from 'measured' then
    select percentile_cont(0.5) within group (order by t.total_minutes)
      into v_median
      from (
        select total_minutes
          from public.usage_daily
         where user_id = v_uid
           and usage_date <= p_date
           and is_finalized = true
           and is_measured = true
           and is_anomaly = false
         order by usage_date desc
         limit v_window_days
      ) t;
    if (select count(*) from public.usage_daily
         where user_id = v_uid and usage_date <= p_date
           and is_finalized = true and is_measured = true and is_anomaly = false) >= v_window_days
       and v_median is not null
       and round(v_median)::integer > v_usual then
      update public.profiles
        set usual_minutes = round(v_median)::integer,
            usual_minutes_source = 'measured',
            usual_minutes_updated_at = now()
        where id = v_uid;
    end if;
  end if;

  -- 連動: 確定ptをアクティブ卵へ反映 (新規確定時のみ / 二重反映しない)。""",
        'finalize/usual revision')

    # --- (h) 戻り値に評価を足す ---
    fn = replace_once(
        fn,
        """    'already_finalized', not v_inserted and v_final_points > 0
  );""",
        """    'already_finalized', not v_inserted and v_final_points > 0,
    'band', v_band,
    'is_measured', true,
    'usual_minutes', v_usual,
    'usual_minutes_source', v_usual_source,
    'today_minutes', v_today_minutes
  );""",
        'finalize/return')

    # 旧ロジックの残骸が無いことを機械的に確かめる。
    for forbidden in ('v_floor_min', 'v_ppm', 'streak_multiplier(', 'avg(total_minutes)'):
        assert forbidden not in fn, 'fn_finalize_day に旧ロジックが残っている: %s' % forbidden
    return fn


# ============================================================================
# 2. fn_claim_warmup（0016 版を土台に、2日目を「孵化までの残り全部」へ）
# ============================================================================
def build_claim_warmup(src_0016: str) -> str:
    fn = extract_function(src_0016, 'fn_claim_warmup')

    fn = replace_once(
        fn,
        "  v_egg_result   jsonb := 'null'::jsonb;\n",
        """  v_egg_result   jsonb := 'null'::jsonb;
  v_hatch        integer;              -- ★0018: 孵化しきい値（残り全部の計算用）
  v_starter_pts  integer;              -- ★0018: 初回ボーナス卵の現在の成長pt
  v_starter_loc  public.egg_location;  -- ★0018: 初回ボーナス卵の所在
  v_mode         text := 'day1';       -- ★0018: 'day1' / 'top_up' / 'active'
  v_target_egg   uuid;                 -- ★0018: 充当先（null = アクティブ卵 or プール）
  v_warmup_total integer := 0;         -- ★0018: これまでの初回ボーナス付与の合計（生涯上限用）
""",
        'warmup/declare')

    # ★0018（第三者レビュー #1）: 同じユーザーの day1 / day2 の同時呼び出しを直列化する。
    #   生涯合計の読み取りと台帳への挿入が競合すると上限をすり抜けるため、profiles 行をロックする
    #   （fn_submit_and_finalize_day と同じ作法 / 0011）。
    fn = replace_once(
        fn,
        """  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid;
""",
        """  select coalesce(timezone, 'Asia/Tokyo') into v_tz
    from public.profiles where id = v_uid
    for update;  -- ★0018: 同一ユーザーの day1/day2 同時呼び出しを直列化（生涯上限の読み書きを守る）
""",
        'warmup/profile lock')

    fn = replace_once(
        fn,
        """  -- SSOT: 付与額を app_config.warmup_grants から読む (マジックナンバー禁止)。
  v_grants := public.cfg('warmup_grants', '{"day1":200,"day2":300}'::jsonb);
  if p_day = 1 then
    v_grant := coalesce((v_grants->>'day1')::integer, 0);
  else
    v_grant := coalesce((v_grants->>'day2')::integer, 0);
  end if;
""",
        """  -- SSOT: 付与額を app_config.warmup_grants から読む (マジックナンバー禁止)。
  -- ★0018: day1 は固定値。day2 の量は初回ボーナス卵の状態で決める（下記）。
  v_grants := public.cfg('warmup_grants', '{"day1":300,"day2":200}'::jsonb);
  v_hatch  := coalesce(
    (public.cfg('egg_thresholds', '{"hatch":500}'::jsonb)->>'hatch')::integer, 500);
""",
        'warmup/grants read')

    fn = replace_once(
        fn,
        """  select id into v_egg_id
    from public.eggs
   where user_id = v_uid and acquired_source = 'starter'
   limit 1;
""",
        """  select id, growth_points, location
    into v_egg_id, v_starter_pts, v_starter_loc
    from public.eggs
   where user_id = v_uid and acquired_source = 'starter'
   order by created_at
   limit 1;

  -- ★0018: 付与額と充当先を決める。
  --   day1    … 固定（300）。初回ボーナス卵へ（無ければ下で生成 / それも無理ならアクティブ卵）。
  --   day2    … 初回ボーナス卵が育成中なら「孵化までの残り全部」= max(hatch − 成長pt, 0) を
  --             その卵へ（初日で止まっている既存ユーザーの卵もこれで孵る＝移行SQL不要）。
  --             初回ボーナス卵が無い／孵化済み／保管中なら warmup_grants.day2 をアクティブ卵へ。
  if p_day = 1 then
    v_mode  := 'day1';
    v_grant := coalesce((v_grants->>'day1')::integer, 0);
  elsif v_egg_id is not null and v_starter_loc = 'incubating' then
    v_mode  := 'top_up';
    v_grant := greatest(v_hatch - coalesce(v_starter_pts, 0), 0);
  else
    v_mode  := 'active';
    v_grant := coalesce((v_grants->>'day2')::integer, 0);
  end if;

  -- ★0018（第三者レビュー #1）: 初回ボーナスの生涯合計は hatch（500）を超えない。
  --   day2 を day1 より先に呼ぶ（RPC を直接叩けば可能）と、残り全部(500)+day1(300)=800 に
  --   なるのを防ぐ。上の profiles 行ロックで同時呼び出しも直列化される。
  select coalesce(sum(amount), 0) into v_warmup_total
    from public.point_ledger
   where user_id = v_uid and source = 'warmup';
  v_grant := least(v_grant, greatest(v_hatch - v_warmup_total, 0));
""",
        'warmup/starter lookup')

    fn = replace_once(
        fn,
        """      jsonb_build_object('day', p_day))""",
        """      jsonb_build_object(
        'day', p_day,
        'mode', v_mode,
        'starter_points_before', v_starter_pts))""",
        'warmup/ledger meta')

    fn = replace_once(
        fn,
        """      -- 付与pt を starter 卵へ充当 (= 卵成長へ積む / S1)。
      -- fn_apply_growth は対象卵明示 (v_egg_id) で incubating の卵へ加算する。
      if v_egg_id is not null then
        -- ★0016: v_idem = uid:warmup:N (日付非依存の生涯1回キー)。これにより
        --   Day1/Day2 が同じ暦日に落ちても互いを打ち消さない。
        v_egg_result := public.fn_apply_growth(v_egg_id, v_grant, v_today, v_idem);
      end if;""",
        """      -- 付与pt を充当する (= 卵成長へ積む / S1)。
      -- ★0018: 'active' モード（初回ボーナス卵が無い/孵化済み/保管中）は対象を明示せず、
      --   fn_apply_growth にアクティブ卵（無ければプール）を選ばせる。
      --   ★0016: v_idem = uid:warmup:N (日付非依存の生涯1回キー)。これにより
      --   Day1/Day2 が同じ暦日に落ちても互いを打ち消さない。
      v_target_egg := case when v_mode = 'active' then null else v_egg_id end;
      v_egg_result := public.fn_apply_growth(v_target_egg, v_grant, v_today, v_idem);""",
        'warmup/apply')

    # ★0018（第三者レビュー再確認 #4）: already_claimed は「今回は何も付与しなかった」。
    #   受取済み（キーあり）だけでなく、生涯上限や「残り全部が 0」（初回ボーナス卵が既に hatch）
    #   で付与が 0 の日も true にして、端末が起動のたびに同じ RPC を呼び続けないようにする。
    #   どちらも後から呼び直して付与が増えることは無い（上限は生涯、残り全部は孵化で消える）。
    fn = replace_once(
        fn,
        """  return jsonb_build_object(
    'claimed', true,
    'day', p_day,""",
        """  -- ★0018: already_claimed = 今回は何も付与しなかった（受取済み / 生涯上限 / 残り全部が 0）。
  --   端末はこれを見て day2 を「受取済み」と記録し、起動のたびに呼び直さない。
  return jsonb_build_object(
    'claimed', true,
    'day', p_day,""",
        'warmup/return comment')

    fn = replace_once(
        fn,
        """    'egg_applied', v_egg_result,
    'balance_after', v_balance,
    'already_claimed', (v_grant > 0 and not v_inserted));""",
        """    'egg_applied', v_egg_result,
    'balance_after', v_balance,
    'mode', v_mode,
    'already_claimed', (not v_inserted));""",
        'warmup/return')
    return fn


# ============================================================================
# 3. fn_submit_and_finalize_day（0011 版を土台に、p_is_measured を追加）
# ============================================================================
def build_submit(src_0011: str) -> str:
    fn = extract_function(src_0011, 'fn_submit_and_finalize_day')

    fn = replace_once(
        fn,
        """create or replace function public.fn_submit_and_finalize_day(
  p_date            date,
  p_total_minutes   integer,
  p_per_app_minutes jsonb,
  p_source_mode     text
)""",
        """create or replace function public.fn_submit_and_finalize_day(
  p_date            date,
  p_total_minutes   integer,
  p_per_app_minutes jsonb,
  p_source_mode     text,
  p_is_measured     boolean default null
)""",
        'submit/signature')

    fn = replace_once(
        fn,
        "  v_finalized    boolean;\nbegin",
        """  v_finalized    boolean;
  v_measured     boolean;   -- ★0018: その日を評価してよいか（計測できていたか）
begin""",
        'submit/declare')

    fn = replace_once(
        fn,
        """  if p_source_mode is null
     or p_source_mode not in ('exact-minutes', 'threshold-achievement') then
    return jsonb_build_object('finalized', false, 'reason', 'invalid_source_mode');
  end if;
""",
        """  if p_source_mode is null
     or p_source_mode not in ('exact-minutes', 'threshold-achievement') then
    return jsonb_build_object('finalized', false, 'reason', 'invalid_source_mode');
  end if;

  -- ★0018: 計測できていたか。新しいアプリは明示で送る（iOS = 対象アプリ選択済みか、
  --   Android = true）。送ってこない古いアプリは source_mode で決める:
  --     exact-minutes（Android）     … 分が正確なので計測あり
  --     threshold-achievement（iOS） … 対象未選択の「永久0分」と区別できないので計測なし
  --                                   （fail-closed。更新後のアプリは選択済みなら true を送る）
  v_measured := coalesce(p_is_measured, p_source_mode = 'exact-minutes');
""",
        'submit/measured')

    fn = replace_once(
        fn,
        """  insert into public.usage_daily(
    user_id, usage_date, total_minutes, per_app_minutes, source_mode)
  values (
    v_uid, v_target, p_total_minutes,
    coalesce(p_per_app_minutes, '{}'::jsonb), p_source_mode)
  on conflict (user_id, usage_date) do nothing;""",
        """  insert into public.usage_daily(
    user_id, usage_date, total_minutes, per_app_minutes, source_mode, is_measured)
  values (
    v_uid, v_target, p_total_minutes,
    coalesce(p_per_app_minutes, '{}'::jsonb), p_source_mode, v_measured)
  on conflict (user_id, usage_date) do nothing;""",
        'submit/insert')

    fn = replace_once(
        fn,
        """     set total_minutes   = p_total_minutes,
         per_app_minutes = coalesce(p_per_app_minutes, '{}'::jsonb),
         source_mode     = p_source_mode
   where user_id = v_uid and usage_date = v_target;""",
        """     set total_minutes   = p_total_minutes,
         per_app_minutes = coalesce(p_per_app_minutes, '{}'::jsonb),
         source_mode     = p_source_mode,
         is_measured     = v_measured
   where user_id = v_uid and usage_date = v_target;""",
        'submit/update')
    return fn


# ============================================================================
# 4. quest_condition_met（0015 版を土台に、reduce_total の「計測なし」判定を is_measured へ）
# ============================================================================
def build_quest_condition(src_0015: str) -> str:
    fn = extract_function(src_0015, 'quest_condition_met')

    fn = replace_once(
        fn,
        "  v_source_mode text;\n  v_tz        text;\nbegin",
        "  v_source_mode text;\n  v_measured  boolean;   -- ★0018\n  v_tz        text;\nbegin",
        'quest/declare')

    fn = replace_once(
        fn,
        """      select b.applied_minutes, u.total_minutes, u.is_finalized, u.source_mode
        into v_baseline, v_today, v_finalized, v_source_mode""",
        """      select b.applied_minutes, u.total_minutes, u.is_finalized, u.source_mode,
             u.is_measured
        into v_baseline, v_today, v_finalized, v_source_mode, v_measured""",
        'quest/select')

    s, e = between(fn,
                   '      -- ★0015: 「計測できていない日」を「利用 0 分の日」と読み替えない。',
                   """      if v_today = 0 and v_source_mode = 'threshold-achievement' then
        return false;
      end if;
""", 'quest/unmeasured rule')
    fn = fn[:s] + """      -- ★0018: 「計測できていない日」は usage_daily.is_measured で判定する。
      --   0015 は iOS の 0 分を一律「計測なし」と読んでいた（対象アプリ未選択の永久0分と
      --   区別できなかったため）。0018 からは端末が is_measured を送る（iOS は対象アプリ
      --   選択済みなら true）ので、**計測ありの 0 分（15分未満）は本当に離れた日**として
      --   達成させる。計測なし（権限なし / 未選択 / 古い iOS アプリ）は未達のまま。
      --   ⚠️ is_measured も端末申告なので細工した端末への防御ではない（0015 と同じ前提）。
      if v_measured is not true then
        return false;
      end if;
""" + fn[e:]
    return fn


HEADER = """-- ============================================================================
-- 0018: たまごの孵化ペースと5段階の見た目（評価制 ◎/○/△・計測なし・R・2日目「残り全部」）
-- ============================================================================
-- 仕様: docs/design/EGG_PACING_DESIGN.md（§2 評価 / §3 数値 / §5 移行 / §6 変更範囲）
-- 前提: docs/design/EGG_PACING_REDESIGN.md（現状の式と数字はコードで確認済み）
--
-- 何を変えるか（オーナー決定 2026-10-21）:
--   * 数え方を「前の週より何分減らしたか（変化）」から「ふだんよりどれだけ離れていたか
--     （状態）」へ。基準 R = 「ふだんのSNS時間」は本人申告（30/60/120/180/300 分・既定 120）。
--     実測で**上げる方向にだけ**直す（計測ありの確定日が 7 日たまったら直近 7 日の中央値）。
--     → 減らした状態が続く限り、毎日報われる。
--   * 1日の評価: ◎ (m <= max(30, R/2)) = 100pt / ○ (m <= max(60, R*3/4)) = 70pt /
--     △ = 15pt / 計測なし = 0pt（卵は進まない・連続日数は据え置き）。
--   * 孵化は 500pt のまま。段階の区切りは 0/100/200/300/500（egg_thresholds.stages）。
--     既存の卵は**換算しない**（しきい値が変わらないので移行SQLは不要 / §5-1）。
--   * 連続倍率は廃止（×1.0 固定）。連続日数の表示とクエスト streak_keep は残る。
--   * 初回ボーナス: 1日目 300 → 2日目「孵化までの残り全部」（初回ボーナス卵が育成中なら）。
--     初日の 200pt で止まっている既存ユーザーの卵も、次に開いた日に残り 300 が入って孵る。
--   * 「計測なし」を usage_daily.is_measured で明示する（iOS で対象アプリ未選択の
--     「永久0分」から出続けていた幻の 30pt/日が消える）。
--
-- 変更一覧:
--   DDL   profiles.usual_minutes / usual_minutes_source / usual_minutes_updated_at
--         usage_daily.is_measured（default true = 既存行は計測あり扱い）
--   設定  app_config: egg_thresholds(+stages) / daily_bands / usual_minutes_default /
--         usual_minutes_choices / warmup_grants / streak_multipliers / daily_point_cap
--   関数  fn_submit_and_finalize_day(+p_is_measured) … 0011 版を抽出して置換
--         fn_finalize_day（評価制）                     … 0016 版を抽出して置換
--         fn_claim_warmup（2日目=残り全部・生涯合計は hatch まで・行ロック）… 0016 版を抽出して置換
--         quest_condition_met（reduce_total の計測なし判定 → is_measured）… 0015 版を抽出して置換
--         fn_set_usual_minutes（新設 / 本人申告の保存）
--
-- ⚠️ このファイルは tools/db/gen_migration_0018.py が生成する。
--    既存関数の本体は 0011 / 0015 / 0016 からスクリプトで機械抽出し、★0018 と注記した
--    箇所だけを置換した（手で転記していない）。直すときはスクリプトを直して再生成する。
--
-- 既存データへの影響:
--   * 台帳・残高・卵の growth_points は**1行も書き換えない**（データ行への UPDATE は無い。
--     add column の default による埋めのみ）。
--   * 古いアプリ（1.2.1）との共存: fn_submit_and_finalize_day の新引数にはデフォルトがあり、
--     4引数の既存呼び出しはそのまま通る（PostgREST は同名の関数が1本なら既定値で解決する。
--     **そのため旧4引数版は drop する**＝2本並ぶと呼び出しが曖昧になる）。
--     egg_thresholds の新キー stages は古いアプリに無視される。hatch は 500 のまま。
--   * 適用の順序: **アプリ更新と同時に当てる**（§5-3）。値だけ先に当てると、古いアプリの
--     端末側の暫定表示（分×倍率）が確定値と食い違う期間が長くなるだけで、確定値は常にこの
--     サーバーが正。逆にアプリだけ先に出すと、新アプリが送る p_is_measured が無い関数に
--     当たって提出が失敗する（PostgREST が未知の引数名を 404 にする）ため、**DB が先**。
--
-- ロールバック手順（この順で実行すること）:
--   ① drop function if exists public.fn_set_usual_minutes(integer);
--   ② drop function if exists public.fn_submit_and_finalize_day(date, integer, jsonb, text, boolean);
--      → 0011 の4引数版 fn_submit_and_finalize_day を create or replace で復元し、
--        revoke all from public, anon, authenticated → grant execute to authenticated を再実行
--   ③ 0016 の fn_finalize_day / fn_claim_warmup を create or replace で復元
--      → revoke execute on function public.fn_finalize_day(date) from public, anon, authenticated;
--        （0002 が grant しているので、復元しただけだと剥奪が外れる / 0016 末尾の注意）
--   ④ 0015 の quest_condition_met を create or replace で復元
--   ⑤ app_config を戻す:
--        egg_thresholds     = {"crack1":100,"crack2":250,"hatch":500}
--        warmup_grants      = {"day1":200,"day2":300}
--        streak_multipliers = [{"days":1,"mult":1.0},{"days":3,"mult":1.2},{"days":7,"mult":1.5},{"days":30,"mult":2.0}]
--        daily_point_cap    = 480
--        daily_bands / usual_minutes_default / usual_minutes_choices は delete してよい（旧関数は読まない）
--   ⑥ 追加した列（profiles.usual_minutes* / usage_daily.is_measured）は残して無害
--      （旧関数は読まない。消すなら alter table ... drop column）。
--
-- 冪等: add column if not exists / create or replace / drop if exists / on conflict do update /
--       revoke・grant は再実行安全。
-- 適用: .github/workflows/db-apply-0018.yml（手動 / 1トランザクション / 適用前スナップショット）
-- 前提: 0001〜0017 適用済み。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. DDL
-- ----------------------------------------------------------------------------
-- R = ふだんのSNS時間（分）。null = 未申告（関数側で usual_minutes_default に倒す）。
alter table public.profiles
  add column if not exists usual_minutes integer
    check (usual_minutes is null or usual_minutes > 0);
alter table public.profiles
  add column if not exists usual_minutes_source text not null default 'default'
    check (usual_minutes_source in ('default', 'reported', 'measured'));
alter table public.profiles
  add column if not exists usual_minutes_updated_at timestamptz;

comment on column public.profiles.usual_minutes is
  '0018: ふだんのSNS時間(分)。本人申告(reported)→実測で上方修正のみ(measured)。null=未申告';
comment on column public.profiles.usual_minutes_source is
  '0018: usual_minutes の出どころ。default / reported / measured';

-- その日を評価してよいか。false = 権限なし / iOS で対象アプリ未選択 / 古い iOS アプリ。
-- 既存行は true（計測あり扱い）。0pt の既存日を遡って消すことはしない。
alter table public.usage_daily
  add column if not exists is_measured boolean not null default true;

comment on column public.usage_daily.is_measured is
  '0018: 計測できていた日か。false の日は 0pt・卵は進まない・連続日数は据え置き';

-- 列権限: profiles の新列はクライアントから書けない（0011 で UPDATE は display_name のみ /
-- INSERT は剥奪済み）。読むのは本人 select で可。usage_daily は 0011 で書込全面剥奪済み。


-- ----------------------------------------------------------------------------
-- 2. app_config（設計書 §3-4）
-- ----------------------------------------------------------------------------
insert into public.app_config (key, value, description) values
  ('egg_thresholds',
    '{"crack1":100,"crack2":250,"stages":[0,100,200,300,500],"hatch":500}'::jsonb,
    '§4-5 卵成長しきい値(累積pt)。stages=5段階の区切り(0018)。crack1/2 は古いアプリ向けに残す'),
  ('daily_bands',
    '{"great":{"abs_min":30,"ratio":0.5,"points":100},"good":{"abs_min":60,"ratio":0.75,"points":70},"poor":{"points":15}}'::jsonb,
    '0018 1日の評価。great: m<=max(abs_min,R*ratio) / good: 同 / poor: それ以外。points は卵に入るpt'),
  ('usual_minutes_default', '120'::jsonb,
    '0018 未申告ユーザーの「ふだんのSNS時間」(分)'),
  ('usual_minutes_choices', '[30,60,120,180,300]'::jsonb,
    '0018 本人申告の選択肢(分)。iOS のしきい値と同じ刻み。fn_set_usual_minutes が検証に使う'),
  ('warmup_grants', '{"day1":300,"day2":200}'::jsonb,
    'S1 初回ボーナス。day1=固定 / day2=初回ボーナス卵が無いときの値(育成中なら孵化までの残り全部 / 0018)'),
  ('streak_multipliers', '[{"days":1,"mult":1.0}]'::jsonb,
    'S14 ストリーク倍率。0018 で廃止(全段×1.0)。連続日数の表示とクエストは残る'),
  ('daily_point_cap', '100'::jsonb,
    'S4 1日ポイント上限。0018: ◎の100pt と同値')
on conflict (key) do update
  set value = excluded.value,
      description = excluded.description,
      updated_at = now();


-- ----------------------------------------------------------------------------
-- 3. fn_set_usual_minutes — 本人申告の保存（新設）
-- ----------------------------------------------------------------------------
-- 選択肢（usual_minutes_choices）の値だけを受け付ける。source は 'reported'。
-- 実測で 'measured' に上がった後に再申告すると 'reported' に戻る（Phase 3 の設定画面用）。
create or replace function public.fn_set_usual_minutes(p_minutes integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  v_choices jsonb;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
  v_choices := public.cfg('usual_minutes_choices', '[30,60,120,180,300]'::jsonb);
  if p_minutes is null
     or not exists (
       select 1 from jsonb_array_elements_text(v_choices) e
        where e::integer = p_minutes) then
    raise exception 'invalid_usual_minutes' using errcode = '22023';
  end if;

  update public.profiles
     set usual_minutes = p_minutes,
         usual_minutes_source = 'reported',
         usual_minutes_updated_at = now()
   where id = v_uid;
  if not found then
    raise exception 'profile_not_found' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'usual_minutes', p_minutes,
    'usual_minutes_source', 'reported');
end;
$$;

revoke all on function public.fn_set_usual_minutes(integer) from public, anon, authenticated;
grant execute on function public.fn_set_usual_minutes(integer) to authenticated;


"""


def main() -> None:
    src_0011 = read('0011_server_authoritative_finalize_date.sql')
    src_0015 = read('0015_quest_condition_hardening.sql')
    src_0016 = read('0016_ledger_source_key.sql')

    parts = [HEADER]

    parts.append("""-- ----------------------------------------------------------------------------
-- 4. fn_submit_and_finalize_day — p_is_measured を追加（0011 版を機械抽出して置換）
-- ----------------------------------------------------------------------------
-- 旧4引数版は drop する（同名2本だと PostgREST の解決が曖昧になる）。4引数の既存呼び出しは
-- 新版のデフォルト（null → source_mode で決める）で通る。
drop function if exists public.fn_submit_and_finalize_day(date, integer, jsonb, text);

""")
    parts.append(build_submit(src_0011))
    parts.append("""

revoke all on function public.fn_submit_and_finalize_day(date, integer, jsonb, text, boolean)
  from public, anon, authenticated;
grant execute on function public.fn_submit_and_finalize_day(date, integer, jsonb, text, boolean)
  to authenticated;


-- ----------------------------------------------------------------------------
-- 5. fn_finalize_day — 評価制（0016 版を機械抽出して置換）
-- ----------------------------------------------------------------------------
""")
    parts.append(build_finalize_day(src_0016))
    parts.append("""

-- ⚠️ 0012:288 / 0016 の剥奪を必ず再掲する。create or replace は ACL を保持するが、
--    0002:876 が authenticated に grant しているため、ここを書き忘れると
--    「本体を直接呼んで任意の過去日を確定させる」経路 (0011 の日付境界ガード迂回) が復活する。
revoke execute on function public.fn_finalize_day(date)
  from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 6. fn_claim_warmup — 2日目を「孵化までの残り全部」へ（0016 版を機械抽出して置換）
-- ----------------------------------------------------------------------------
""")
    parts.append(build_claim_warmup(src_0016))
    parts.append("""

-- fn_claim_warmup の権限は 0003 のまま (authenticated が呼ぶ入口)。再掲。
grant execute on function public.fn_claim_warmup(integer) to authenticated;


-- ----------------------------------------------------------------------------
-- 7. quest_condition_met — reduce_total の「計測なし」判定を is_measured へ
--    （0015 版を機械抽出して置換）
-- ----------------------------------------------------------------------------
""")
    parts.append(build_quest_condition(src_0015))
    parts.append("""

-- 内部専用（0005 / 0015 と同方針）。再掲。
revoke all on function public.quest_condition_met(uuid, jsonb, public.quest_kind, date)
  from public, anon, authenticated;
""")

    out = ''.join(parts)
    with io.open(OUT, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out)
    print('wrote %s (%d bytes)' % (os.path.relpath(OUT, ROOT), len(out.encode('utf-8'))))


if __name__ == '__main__':
    try:
        main()
    except AssertionError as e:
        print('生成を中止しました: %s' % e, file=sys.stderr)
        sys.exit(1)

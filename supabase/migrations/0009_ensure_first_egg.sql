-- ============================================================================
-- Moffy 追補マイグレーション (0009_ensure_first_egg.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-07-09
-- 準拠: docs/PRD.md (§S1 初日体験 / §S6 育成枠) / ORG_STATE.md RESUME (FTUE ブロッカー)
--       supabase/migrations/0001_init.sql (eggs / uq_eggs_one_active / uq_eggs_slot)
--       supabase/migrations/0003_warmup_grants.sql (fn_claim_warmup / starter 卵)
--       supabase/migrations/0005_economy_exploit_fix.sql (eggs トリガー = BEFORE UPDATE のみ)
--
-- このマイグレーションが解決する FTUE ブロッカー:
--   新規ユーザーの巣が空のまま手詰まりになる問題を根治する。既存の初回卵付与
--   (fn_claim_warmup / 0003) は「ローカル初回起動から 2 日以内 (Day1/Day2)」かつ
--   「ホーム初回ロードが baseline.isWarmup を満たした時」にしか発火しない。初回2ロードが
--   オフライン等で失敗しウォームアップ窓 (2日) を過ぎると starter 卵が二度と作られず、
--   「まだ卵がありません」の空の巣で詰む。
--
-- 解決 = 堅牢な「最初の卵保証」RPC (fn_ensure_first_egg):
--   * ウォームアップ窓・baseline・ローカル日付に一切依存しない。
--   * 巣 (育成枠) が完全に空 かつ 保管枠も空 (= 未孵化の卵を1つも持たない) のとき、
--     標準 (normal) 卵を1つだけ育成枠1にアクティブ生成する。
--   * 冪等: 未孵化の卵が既に1つでもあれば no-op (何度呼んでも増えない)。
--     これは先の設計決定「復帰フォールバック (巣空&保管0でログイン時1個)」(2026-07-07) と一致。
--   * クライアントは「巣が空なら保証して」と要求するだけで、生成するか否か・何を生成するかは
--     サーバーが決める (信頼境界 / ARCHITECTURE §2-3)。ホーム/たまごの初回ロードから呼ぶ。
--
-- 信頼境界 (0002/0003 と同方針):
--   * security definer + set search_path = '' + 完全修飾。auth.uid() 起点で本人限定。
--   * 卵付与はサーバー RPC の責務 (eggs の INSERT ポリシーは 0001 で敢えて未作成)。
--     definer が所有者権限で RLS をバイパスして本人の卵を1つ作る。
--   * レアリティは標準 (normal) 固定。抽選しない (孵化時に drop_tables['normal'] で Mofi 抽選)。
--
-- 冪等性 (このマイグレーション自体の再適用安全性):
--   * 関数は create or replace。revoke/grant は再実行しても安全 (現在の権限状態に収束)。
--   * INSERT は eggs のみ。0005 の BEFORE UPDATE トリガー (孵化不変) には抵触しない (INSERT のため)。
--
-- fn_claim_warmup (0003) との関係 (二重付与しない):
--   * 本 RPC の guard 「未孵化卵ゼロ」と、fn_claim_warmup の guard 「starter 卵あり or
--     アクティブ卵あり」は相互排他。どちらが先に走っても、他方は自分の guard で no-op になる。
--       - fn_claim_warmup が先 → starter 卵 (incubating/active) を作る → 本 RPC は
--         「未孵化卵あり」で no-op。
--       - 本 RPC が先 → starter 卵 (incubating/active) を作る → fn_claim_warmup は
--         「starter 卵あり」で再生成せず、その卵へウォームアップ pt を充当する。
--   * どちらも acquired_source='starter' で作るため、両経路の生成物は区別なく相互に guard で
--     捕捉される (= 同一ユーザーで starter 卵が2つ作られない)。
--   * 万一の並行競合 (別経路が同時に卵を作る) は eggs の部分一意インデックス
--     (uq_eggs_one_active / uq_eggs_slot) が物理担保する。本 RPC は unique_violation を
--     捕捉して「作らず既存へ収束 (granted=false)」する (= 例外で落とさない)。
-- ============================================================================

-- ============================================================================
-- fn_ensure_first_egg() — 最初の卵保証 (FTUE / 復帰フォールバック)
-- ----------------------------------------------------------------------------
-- 責務:
--   1. 本人 (auth.uid()) のみ。引数なし (状態から判断)。
--   2. guard (= 「空」の SSOT): 本人が location in ('incubating','storage') の卵を
--      1つも持たないとき「完全に空」と判定する (孵化済み hatched は数えない = 既に Mofi に
--      なった卵。クライアント EggsState.isCompletelyEmpty と同義)。
--   3. 空でなければ no-op で {granted:false, reason:'already_has_egg'} を返す (冪等)。
--   4. 空なら normal 卵を育成枠1・アクティブで1つ生成し {granted:true} を返す。
--      並行競合は unique_violation を捕捉して granted=false に収束 (落とさない)。
-- 戻り値: jsonb {granted, reason, egg_id, rarity, is_first_ever}
--   * granted        … 今回新規に卵を生成したか (true=巣に卵が出た)。
--   * reason         … 'granted' | 'already_has_egg'。
--   * egg_id         … 生成 or 既存のアクティブ卵 id (無ければ null)。
--   * rarity         … 生成した卵のレア (常に 'normal')。no-op 時も 'normal' を返す (表示用)。
--   * is_first_ever  … 生成が「生涯で最初の卵」か (孵化履歴も無い新規)。孵化済みがある復帰
--                      ユーザーへの refill は false。クライアントは FTUE ファネル計測
--                      (first_egg_granted イベント) を「初回のみ」に保つため使う。
--
-- 防御的正規化 (heal / 堅牢性):
--   guard を通す前に、raw なクライアント書込 (0004 の列GRANT で is_active/location を直接更新
--   可能) でしか到達しない不整合を正す。正常なアプリ経路では下記いずれも no-op なので通常
--   ユーザーには無影響。目的は「巣が空なのに保証が永久に成立しない」失敗モードの根絶:
--     (1) 非育成 (hatched/storage) 卵に is_active が立っていたら降ろす。孵化卵/保管卵は
--         アクティブになり得ない (fn_hatch_egg は必ず is_active=false / setActiveEgg は育成中
--         のみ)。stray is_active があると新しい卵の INSERT が uq_eggs_one_active に衝突して
--         保証が成立しない。BEFORE UPDATE トリガー (0005) は location 不変のこの更新を通す。
--     (2) slot_index が NULL の育成卵はクライアントに描画されない (枠1..3 のみ描画)。サーバー
--         guard だけが数えて「クライアントは空表示・サーバーは非空判定」の乖離を生む。保管枠へ
--         退避し双方の「空」判定を一致させる (ユーザーが枠へ置き直せる)。
-- ============================================================================
create or replace function public.fn_ensure_first_egg()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid         uuid := auth.uid();
  v_has_any     boolean;
  v_egg_id      uuid;
  v_granted     boolean := false;
  v_first_ever  boolean := false;
begin
  if v_uid is null then
    raise exception 'unauthorized' using errcode = '28000';
  end if;

  -- 防御的正規化 (heal) — 詳細は上のヘッダ参照。正常経路では no-op。
  --   (1) 非育成卵の stray is_active を降ろす (uq_eggs_one_active 衝突で保証不成立を防ぐ)。
  update public.eggs set is_active = false
   where user_id = v_uid and location <> 'incubating' and is_active = true;
  --   (2) slot_index NULL の孤児育成卵を保管枠へ退避 (クライアント/サーバーの「空」を一致)。
  update public.eggs set location = 'storage', is_active = false
   where user_id = v_uid and location = 'incubating' and slot_index is null;

  -- guard (= 「空」の SSOT): 本人が「未孵化の卵 (育成枠 or 保管枠)」を1つでも持つか。
  --   持つ → 空ではない (巣にセットするか保管から出せる) ので付与しない。
  --   持たない → 完全に空 (新規 or 全孵化して手詰まり) なので下で1つ保証する。
  --   hatched は数えない (= 既に孵化して Mofi になった卵。巣の空き状況とは無関係)。
  --   heal 後は「incubating = 必ず slot 1..3」なのでクライアント描画 (isCompletelyEmpty) と一致。
  select exists(
    select 1 from public.eggs
     where user_id = v_uid and location in ('incubating', 'storage')
  ) into v_has_any;

  if v_has_any then
    -- 既に卵を持つ (= 空でない)。no-op。アクティブ卵 id があれば返す (表示整合用)。
    select id into v_egg_id
      from public.eggs
     where user_id = v_uid and is_active = true
     limit 1;
    return jsonb_build_object(
      'granted', false,
      'reason', 'already_has_egg',
      'egg_id', v_egg_id,
      'rarity', 'normal',
      'is_first_ever', false);
  end if;

  -- first-ever 判定: 未孵化卵ゼロ (guard) かつ 孵化卵も無い = 生涯で最初の卵。
  --   孵化卵があれば「全孵化して空になった復帰ユーザー」= refill (first_ever=false)。
  v_first_ever := not exists(select 1 from public.eggs where user_id = v_uid);

  -- 完全に空 → 標準 (normal) 卵を1つ、育成枠1・アクティブで生成する。
  --   guard 通過時点で育成枠の卵は無い (= slot 1 は空) ため slot_index=1/is_active=true は安全。
  --   並行競合 (別経路が同時に卵を作る = fn_claim_warmup 等) は eggs の部分一意インデックス
  --   (uq_eggs_one_active / uq_eggs_slot) が捕捉する。unique_violation なら「作らず既存へ収束」
  --   (例外で落とさない / クライアント体験を止めない)。plpgsql の例外ブロックは暗黙 savepoint
  --   のため、失敗した INSERT はロールバックされ Tx は継続する。
  begin
    insert into public.eggs(
      user_id, rarity, growth_points, location, slot_index, is_active, acquired_source)
    values (
      v_uid, 'normal', 0, 'incubating', 1, true, 'starter')
    returning id into v_egg_id;
    v_granted := true;
  exception when unique_violation then
    -- 別 Tx が同時に卵を作った (実運用ではほぼ発生しない = 匿名認証は端末1人)。
    -- 既存のアクティブ卵へ収束する (READ COMMITTED のため直近コミット分を参照可能)。
    v_granted := false;
    v_first_ever := false;
    select id into v_egg_id
      from public.eggs
     where user_id = v_uid and is_active = true
     limit 1;
  end;

  return jsonb_build_object(
    'granted', v_granted,
    'reason', case when v_granted then 'granted' else 'already_has_egg' end,
    'egg_id', v_egg_id,
    'rarity', 'normal',
    'is_first_ever', v_first_ever);
end;
$$;

-- ============================================================================
-- 権限 (revoke / grant) — 0002/0003 と同方針 (authenticated 最小権限)
-- ----------------------------------------------------------------------------
--   * fn_ensure_first_egg: クライアント (authenticated) から呼ぶ公開RPC。
--     anon には付与しない (匿名認証後 = authenticated で呼ぶ)。
-- ============================================================================
revoke all on function public.fn_ensure_first_egg() from public, anon, authenticated;
grant execute on function public.fn_ensure_first_egg() to authenticated;

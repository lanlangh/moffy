-- ============================================================================
-- Moffy 追補マイグレーション (0010_storage_cap.sql)
-- ----------------------------------------------------------------------------
-- 設計責任: 開発部署 (engineer) / 日付: 2026-07-09
-- 準拠: docs/PRICING.md (§2 保管枠 20/200) / lib/core/constants/pricing.dart (StorageLimits)
--       supabase/migrations/0001_init.sql (eggs / entitlements / app_config)
--       supabase/migrations/0005_economy_exploit_fix.sql (eggs BEFORE UPDATE トリガー整合)
--
-- このマイグレーションが解決する問題（磨き込み②の正直化レビュー指摘 = 景表法/3.1.2）:
--   ペイウォールは「保管枠が 20 → 200」をプレミアム特典として宣伝し、たまご画面は
--   「保管庫がいっぱいです」と満杯を提示して課金へ誘導するが、**保管枠の上限がサーバー/
--   クライアントのどこにも強制されていなかった**（eggs に件数制約なし・is_premium を参照する
--   ガードなし）。= 無料ユーザーも無制限に保管でき、プレミアムの機能差分ゼロ・満杯表示は虚偽。
--   → 未提供特典の宣伝（優良誤認・有利誤認）。
--
-- 解決 = 保管枠上限をサーバー権威で強制する（= 特典を本物にする）:
--   * app_config に上限値（無料20/プレミアム200・SSOT）を追加。UI(pricing.dart)と一致。
--   * eggs の BEFORE INSERT OR UPDATE トリガーで「卵が保管枠(location='storage')に**入る**」
--     全経路を捕捉し、本人の現在保管数が上限以上なら弾く。
--       - UPDATE（moveToStorage = ユーザーが育成枠→保管へ移す）: **例外 storage_full** を送出
--         → クライアントが「満杯（プレミアムで拡張）」を表示する。
--       - INSERT（クエスト報酬など server 生成の保管卵）: **黙ってスキップ**（return null）
--         → 報酬 Tx（pt/ジェム）を巻き込んで失敗させない。満杯時は卵だけ入らない（= 満杯圧）。
--         ※無料在庫は通常 0〜1（財務監査 2026-07-07）でこの経路は稀。
--   * is_premium は **entitlements（サーバー権威 / クライアント書込不可）** から読む。
--     プレミアム判定の偽装は不可（信頼境界）。上限もサーバーが決める。
--
-- 影響しない経路（設計確認）:
--   * fn_claim_warmup(0003) は **育成枠(incubating)** に卵を作るため本トリガーの条件
--     (new.location='storage') に非該当 → 無影響。
--   * fn_ensure_first_egg(0009) の生成 INSERT も incubating → 非該当。ただし同関数の防御的 heal(2)
--     は「slot_index NULL の孤児育成卵を storage へ退避」= incubating→storage の UPDATE で、
--     本トリガーの対象になり得る。実運用では無害:
--       - クライアントは isCompletelyEmpty（= 保管枠が空）のときだけ ensure を呼ぶため、その時点の
--         保管数は 0 → heal(2) で 0→1 になっても上限(20)未満 → 弾かれない。
--       - 直接 RPC 呼び出しで保管が満杯(≥20)＋孤児卵がある稀な状態のみ、heal(2) が storage_full で
--         Tx を中断し得るが、その場合 guard は元々 already_has_egg（非空）で卵を配らない＝
--         「必要な最初の卵の付与」を妨げない（クライアントは notGranted を受けて通常表示）。
--   * moveToIncubator（storage→incubating）は new.location≠'storage' → 無影響（枠を空ける方向）。
--   * fn_hatch_egg は location='hatched' → 非該当。
--
-- 冪等性（再適用安全）:
--   * app_config は on conflict do nothing。関数は create or replace。
--   * トリガーは drop trigger if exists 先行で create。
-- ============================================================================

-- ============================================================================
-- SSOT: 保管枠上限（無料/プレミアム）を app_config へ（pricing.dart StorageLimits と一致）。
-- ============================================================================
insert into public.app_config (key, value, description) values
  ('storage_slots_free',    '20'::jsonb,
   'S6 無料プランの保管枠上限（卵の保管数）。pricing.dart StorageLimits.freeStorageSlots と一致'),
  ('storage_slots_premium', '200'::jsonb,
   'S6 プレミアムの保管枠上限。pricing.dart StorageLimits.premiumStorageSlots と一致')
on conflict (key) do nothing;

-- ============================================================================
-- fn_eggs_enforce_storage_cap — 保管枠上限のサーバー強制（BEFORE INSERT OR UPDATE）
-- ----------------------------------------------------------------------------
-- security definer: entitlements（RLS select-own）と app_config を文脈に依らず読む。
-- 「保管枠に入る」瞬間だけ判定する（既に storage の行の他列更新や、storage から出る移動は素通し）。
-- ============================================================================
create or replace function public.fn_eggs_enforce_storage_cap()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_is_premium boolean;
  v_limit      integer;
  v_count      integer;
begin
  -- 対象は「この更新/挿入で location が storage に**なる**」ケースのみ。
  --   INSERT: new.location='storage'。
  --   UPDATE: storage 以外 → storage への遷移（old.location が storage でない）。
  --   （既に storage の行の他列更新や storage→他所 への移動は上限に無関係なので素通し。）
  if new.location <> 'storage' then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.location = 'storage' then
    return new;  -- 既に保管枠内の行の更新（枠数は増えない）。
  end if;

  -- is_premium はサーバー権威（entitlements / クライアント書込不可）。行が無ければ無料扱い。
  select coalesce(
           (select e.is_premium from public.entitlements e where e.user_id = new.user_id),
           false)
    into v_is_premium;

  -- 上限は SSOT（app_config）。マジックナンバー禁止。
  if v_is_premium then
    v_limit := public.cfg_int('storage_slots_premium', 200);
  else
    v_limit := public.cfg_int('storage_slots_free', 20);
  end if;

  -- 本人の現在の保管数（この行はまだ storage ではないので分母に含まれない）。
  select count(*)::integer into v_count
    from public.eggs
   where user_id = new.user_id and location = 'storage';

  if v_count >= v_limit then
    if tg_op = 'UPDATE' then
      -- ユーザー操作（moveToStorage）: 明示エラーでクライアントが案内（プレミアムで拡張）。
      raise exception 'storage_full'
        using errcode = '23514',  -- check_violation 相当
              detail  = 'Storage is full for this plan; hatch an egg or upgrade to premium.';
    else
      -- サーバー生成（クエスト報酬など）: 報酬 Tx を壊さないよう卵だけ黙ってスキップ。
      return null;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_eggs_enforce_storage_cap on public.eggs;
create trigger trg_eggs_enforce_storage_cap
  before insert or update on public.eggs
  for each row execute function public.fn_eggs_enforce_storage_cap();

-- ============================================================================
-- 権限: トリガー関数はトリガー専用（クライアントから直接呼べない）。grant しない。
--   （0005 の fn_eggs_block_hatched_mutation と同方針。）
-- ============================================================================

-- ============================================================================
-- 0015: クエスト達成条件の fail-closed 化 (v1.1 / 順0 の追補)
-- ============================================================================
-- 背景 (2026-08-07 第三者レビュー3レンズ + 症状別調査で確定):
--   0013 は app_under のキー欠落だけを塞いだが、**報酬額の大きい経路が開いたまま**
--   だった。fn_evaluate_quest / fn_grant_quest_reward は 0005:727,729 で
--   authenticated に grant 済みのため、v1.1 順2 (クエスト自動評価の配線) を待たず
--   **現在すでにクライアントから直接叩ける**。
--
--   | 経路          | 報酬       | 発火条件                                   |
--   |---------------|-----------|--------------------------------------------|
--   | reduce_total  | 50pt/日    | iOS でしきい値が発火しない日 = 通常状態      |
--   | streak_keep   | 20pt/日    | ストリークを切った日                        |
--   | hatch_count   | 100pt+10ジェム/週 | PATCH eggs {is_active} を1回投げるだけ |
--   | app_under     | 30pt/日    | per_app に null 値を入れる (現在は到達不能)  |
--
-- 本マイグレーションの原則は 0005 の C-2 と同じ:
--   **「計測できていないもの」を「0」と読み替えて達成にしない (fail-closed)。**
--
-- ----------------------------------------------------------------------------
-- 各対処の根拠
-- ----------------------------------------------------------------------------
-- (1) app_under — キーの「存在」ではなく「数値であること」を要求する
--     0013 は `per_app_minutes ? key` を追加したが、`?` はキーの存在しか見ない。
--     `'{"k":null}'::jsonb ? 'k'` は true で、`->>` は SQL NULL を返し coalesce で
--     0 になる ＝ 0 < 20 で達成。さらに `'{"k":"abc"}'` では `::integer` キャストが
--     v_has_key 判定より先に評価されて 22P02 (invalid_text_representation) で落ちる。
--     `jsonb_typeof(...) = 'number'` に一本化すると、両方が同時に解決する。
--     入力側 (0011:174-177) は per_app_minutes の中身を一切検証せず格納するため、
--     読み取り側で型を要求するのが正しい防御位置。
--
-- (2) reduce_total — 「何も計測できていない日」に削減を認めない
--     iOS は DeviceActivity のしきい値が発火しない日、per_app も total も 0 で提出する
--     (ios_usage_provider.dart:93,140-143)。daily_submission.dart には 0 分を提出しない
--     分岐が無く、0012:167 が基準値を下限 30 分にクランプするため
--     `reduced = 30 - 0 = 30` となり `daily_reduce_30` (50pt) が毎日達成される。
--     これは「SNSを1分も使わなかった人」と区別できないが、**区別できない以上は
--     報酬を出さない**側に倒す (0005 C-2 と同じ判断。誤付与のほうが害が大きい)。
--     ※ 合計が 0 でも per_app に数値があれば計測はできているので達成を認める。
--
-- (3) streak_keep — 「切った日」を「維持した日」と数えない
--     0012:245-263 は、削減が 0/マイナスでストリークをリセットする場合にも
--     `last_progress_date = p_date` を立てる。0013 の判定は last_progress_date の
--     一致だけを見ていたため、**切った日でも達成**になっていた (20pt)。
--     `current_streak > 0` を要求して「維持できた日」だけを達成にする。
--
-- (4) hatch_count — updated_at ではなく hatched_at で数える
--     0013 は `eggs.updated_at` を孵化日時の代理にしていたが、
--       * set_updated_at (0001:27-35) は無条件に now() を入れる
--       * 0004:97 が authenticated に `update (slot_index, location, is_active)` を許可
--       * 孵化済み卵の no-mutate トリガー (0005) は「location が変わる UPDATE」だけを
--         拒否するので、`{"is_active": false}` の no-op UPDATE は通過する
--     ＝ `PATCH /rest/v1/eggs?location=eq.hatched` に is_active を投げるだけで、
--     何年も前に孵化した卵が「今週孵化した」と数え直され、weekly_hatch_3
--     (100pt + 10ジェム) を毎週 farm できた。
--     不変の `hatched_at` 列を新設し、**クライアントが書けない経路** (トリガー) で
--     のみ立てる。列GRANT に追加しないので UPDATE 不可のまま。
--
-- ----------------------------------------------------------------------------
-- あえてやらないこと (v1.2 へ / 判断の記録)
-- ----------------------------------------------------------------------------
--   * fn_evaluate_quest / fn_grant_quest_reward への is_active ガード追加。
--     多層防御としては正しいが、両関数 (特に後者は約130行) の全文 create or replace が
--     必要で、**転記ミスのリスクが利得を上回る**。現時点では
--       - fn_sync_quests (0005:441-455) が is_active=true しかインスタンス化しない
--       - 0013 が停止済みクエストの未受取行を削除済み
--       - user_quests への client INSERT は 0005:58 で剥奪済み
--     の3点で到達不能。同じ理由で fn_hatch_egg も触らず、hatched_at はトリガーで立てる。
--   * app_under の「合計型」(condition に package を持たない形) はサーバー未実装
--     (下の `v_package is null` で未達に倒れる)。MockQuestRepository には
--     'daily_sns_under_60' として存在するが **DB には seed されていない**。
--     seed する前に quest_condition_met の拡張が必要。
--
-- 冪等: 関数は create or replace / 列は add column if not exists /
--       バックフィルは where hatched_at is null / トリガーは drop if exists 先行。
-- 適用: .github/workflows/db-apply-v11.yml (0013→0014→0015→0016 を順に適用)
-- 前提: 0001〜0014 適用済み。**0013 より後に適用すること** (quest_condition_met を
--       全文置換するため、順序が逆だと 0013 の内容が復活して上書きされる)。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. eggs.hatched_at — 孵化日時の不変記録 (クライアント書込不可)
-- ----------------------------------------------------------------------------
alter table public.eggs
  add column if not exists hatched_at timestamptz;

comment on column public.eggs.hatched_at is
  '孵化が確定した時刻。トリガー trg_eggs_stamp_hatched_at のみが書く（列GRANT外＝クライアントは更新不可）。hatch_count クエストの計数はこの列だけを見る（updated_at は no-op UPDATE で動かせるため使わない / 0015）。';

-- 既存の孵化済み卵をバックフィルする。updated_at は上記のとおり汚染され得るが、
-- 過去の孵化について他に手がかりが無く、かつ「過去に孵化した」事実は動かない。
-- （今週の窓に入る値が入っていた場合は、それ自体が farm 済みの痕跡。Verify で件数を出す）
update public.eggs
   set hatched_at = updated_at
 where location = 'hatched'
   and hatched_at is null;


-- ----------------------------------------------------------------------------
-- 2. hatched_at を立てるトリガー (fn_hatch_egg を書き換えずに済ませる)
-- ----------------------------------------------------------------------------
--   * 孵化への遷移 (location が hatched 以外 → hatched) のときだけ now() を刻む。
--   * 既に hatched_at がある行は上書きしない (再孵化は 0005 の H-1 で不可能だが、
--     万一の経路でも「最初の孵化日時」を保持する)。
--   * security definer は不要 (トリガーはテーブル所有者権限で走る)。
--   * 0005 の trg_eggs_block_hatched_mutation と併存する。あちらが不正な遷移を
--     例外で止めるので、拒否された UPDATE でこの列が動くことはない
--     (例外が出れば Tx 全体がロールバックする)。
-- ----------------------------------------------------------------------------
create or replace function public.fn_eggs_stamp_hatched_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.location = 'hatched'
     and old.location is distinct from 'hatched'
     and new.hatched_at is null then
    new.hatched_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_eggs_stamp_hatched_at on public.eggs;
create trigger trg_eggs_stamp_hatched_at
  before update on public.eggs
  for each row execute function public.fn_eggs_stamp_hatched_at();


-- ----------------------------------------------------------------------------
-- 3. quest_condition_met — 全条件タイプの fail-closed 化
--    (0013 版を土台に app_under / reduce_total / streak_keep / hatch_count を修正)
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
  v_per_app   jsonb;
  v_streak    integer;
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
      -- 合計型 (package なし) はサーバー未実装。実装するまで未達に倒す (0015 ヘッダ参照)。
      if v_package is null then
        return false;
      end if;
      -- fail-closed 3段:
      --   ① usage_daily 行が存在すること         (未提出の日で報酬を得させない / 0005 C-2)
      --   ② サーバーが確定した日であること        (端末の暫定値で判定しない / 0005 C-2)
      --   ③ per_app_minutes[package] が**数値**であること (0015)
      --      キー欠落・null 値・文字列を「0分」と読み替えない。iOS は per-app キーを
      --      構造的に持たないので、この判定で常に未達になる (＝正しい)。
      select is_finalized, per_app_minutes
        into v_finalized, v_per_app
        from public.usage_daily
       where user_id = p_uid and usage_date = p_period;
      if not found or v_finalized is not true then
        return false;
      end if;
      if jsonb_typeof(v_per_app -> v_package) is distinct from 'number' then
        return false;
      end if;
      v_used := (v_per_app ->> v_package)::integer;
      return v_used < v_target;

    when 'reduce_total' then
      -- 削減量 = その日の適用基準(baselines.applied_minutes) - その日の利用(total_minutes)。
      -- fail-closed: usage_daily 行が確定済みで baselines も存在する場合のみ判定。
      select b.applied_minutes, u.total_minutes, u.is_finalized, u.per_app_minutes
        into v_baseline, v_today, v_finalized, v_per_app
        from public.usage_daily u
        join public.baselines b
          on b.user_id = u.user_id and b.baseline_date = u.usage_date
       where u.user_id = p_uid and u.usage_date = p_period;
      if not found or v_finalized is not true
         or v_baseline is null or v_today is null then
        return false;
      end if;
      -- ★0015: 「何も計測できていない日」を「利用 0 分の日」と読み替えない。
      --   合計 0 かつ per_app も空 = OS から何も取れていない状態 (iOS でしきい値が
      --   発火しない日の通常形)。基準値が下限 30 分にクランプされる (0012:167) ため、
      --   このままだと毎日 30 分の削減が成立して 50pt が出てしまう。
      --   合計が 0 でも per_app に数値があれば計測はできているので通す。
      if v_today = 0 and coalesce(v_per_app, '{}'::jsonb) = '{}'::jsonb then
        return false;
      end if;
      return greatest(v_baseline - v_today, 0) >= v_target;

    when 'streak_keep' then
      -- その period にストリークが**維持された**こと。
      -- ★0015: last_progress_date の一致だけでは足りない。0012:245-263 は削減が
      --   0/マイナスでストリークをリセットする場合にも last_progress_date を立てるため、
      --   「切った日」まで達成になっていた。current_streak > 0 を要求する。
      select current_streak into v_streak
        from public.streaks
       where user_id = p_uid and last_progress_date = p_period;
      return found and coalesce(v_streak, 0) > 0;

    when 'hatch_count' then
      -- 当該 period 窓内に孵化した卵数。
      -- ★0015: updated_at ではなく hatched_at で数える。updated_at は
      --   set_updated_at (0001:27-35) が無条件に now() を入れるうえ、authenticated は
      --   is_active を UPDATE できる (0004:97) ため、no-op UPDATE 1回で過去の卵を
      --   「今週孵化した」ことにできた (weekly_hatch_3 = 100pt + 10ジェムの farm)。
      --   hatched_at はトリガー専管で列GRANT外＝クライアントから動かせない。
      select count(*)::integer into v_val
        from public.eggs
       where user_id = p_uid
         and location = 'hatched'
         and hatched_at is not null
         and (hatched_at at time zone 'UTC')::date between v_period_lo and v_period_hi;
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

-- 権限は 0005/0013 のまま (内部専用)。create or replace は ACL を保持するが、
-- 初適用環境との差異を無くすため明示的に収束させる。
revoke all on function public.quest_condition_met(uuid, jsonb, public.quest_kind, date)
  from public, anon, authenticated;

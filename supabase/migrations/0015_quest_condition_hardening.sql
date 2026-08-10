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
--     `jsonb_typeof(...) = 'number'` で**文字列と null は**解決する。ただし jsonb の
--     number は numeric なので `{"k":0.5}` は型チェックを通り `'0.5'::integer` が
--     やはり 22P02 になる ＝ **非整数は numeric 経由の範囲検証と切り捨てが別途必要**。
--     入力側 (0011) は per_app_minutes の中身を一切検証せず格納するため、
--     読み取り側で型と範囲を要求するのが正しい防御位置。
--
-- (2) reduce_total — 「計測できていない日」に削減を認めない
--     iOS は DeviceActivity のしきい値が発火しない日、total=0 で提出する。
--     daily_submission.dart には 0 分を提出しない分岐が無く、0012:167 が基準値を
--     下限 30 分にクランプするため `reduced = 30 - 0 = 30` となり
--     `daily_reduce_30` (50pt) が毎日達成される。
--     ⚠️ 判別子は **source_mode**（per_app の非空ではない）。両OSとも 0 分のアプリは
--     キーごと落とすので `total=0 ⟺ per_app={}` が恒真になり、per_app では
--     「計測できなかった日」と「1分も使わなかった日」を区別できない。per_app で弾くと
--     最も報いたい「完全に断てた Android ユーザー」だけが 50pt を失う。
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
--   * 🔴 **基礎pt 経路は本 migration では未対処のまま残る**（v1.2 の必須項目）。
--     0015 が塞ぐのは「クエスト報酬」だけ。同じ「計測できていない日」から出る
--       - 基礎pt（fn_finalize_day: floor 30 - total 0 = 30pt/日 × ストリーク倍率・上限480）
--       - ストリーク継続（→ streak_keep 20pt/日も 0015 の current_streak>0 を満たす）
--     は出続ける。**金額としては 0015 が塞ぐ 50pt より大きい**。
--     同梱しなかった理由: (a) 0002 以来の既存挙動で 0015/0016 が持ち込んだ回帰ではない
--     (b) 修正は基準値の母集団から計測ゼロ日を除外する話まで含み、コアループの経済式
--     そのものを変える＝本番適用の直前に入れる変更ではない
--     (c) 何より 0016 の唯一の安全根拠「元定義から1行しか変えていない（機械抽出＋diffで
--     検証可能）」を失う。
--     ⚠️ 0016 適用後は、この phantom pt が**確実に卵へ届くようになる**
--     （従来は冪等キー衝突で一部が消えていた）。v1.2 で必ず塞ぐこと。
--
--   * Android(exact-minutes) の「計測に失敗して0分を提出した日」は素通りする。
--     0分が「本当に使わなかった」のか「取得に失敗した」のかを Android 側は区別できず、
--     区別できない以上は**達成させる側**に倒した（最も報いたい「完全に断てた人」を
--     弾かないため）。iOS と非対称なのは意図的。
--
--   * 攻撃者への防御ではない点の明示: source_mode も per_app_minutes も等しく
--     クライアント入力で、0011 は total と source_mode の**値域**しか検証しない。
--     細工した端末は依然として通せる。入力側のホワイトリスト化／値型・範囲検証、
--     またはサーバー専管の measured フラグが正しい防御位置で、これは別 migration の仕事。
--     ここでいう fail-closed は「事故で誤付与しない」という意味であって耐攻撃性ではない。
--
-- 冪等: 関数は create or replace / 列は add column if not exists /
--       バックフィルは where hatched_at is null / トリガーは drop if exists 先行。
-- 適用: .github/workflows/db-apply-v11.yml (0013→0014→0015→0016 を1トランザクションで適用)
-- 前提: 0001〜0012 適用済み。0013〜0016 は db-apply-v11.yml が同時に当てる。
--       **0013 より後に適用すること** (quest_condition_met を全文置換するため、
--       順序が逆だと 0013 の内容が復活して上書きされる)。
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. eggs.hatched_at — 孵化日時の不変記録 (クライアント書込不可)
-- ----------------------------------------------------------------------------
alter table public.eggs
  add column if not exists hatched_at timestamptz;

comment on column public.eggs.hatched_at is
  '孵化が確定した時刻。トリガー trg_eggs_stamp_hatched_at のみが書く（列GRANT外＝クライアントは更新不可）。hatch_count クエストの計数はこの列だけを見る（updated_at は no-op UPDATE で動かせるため使わない / 0015）。';

-- 既存の孵化済み卵をバックフィルする。
--   * ★updated_at は使わない。no-op な PATCH {is_active} で now() に動かせるため、
--     farm の痕跡を「正規の孵化日時」として権威列に昇格させてしまう
--     （＝farm した人にだけ、もう1週ぶんの weekly_hatch_3 を配って締めることになる）。
--   * 代わりにクライアントが書けない列だけを使う:
--       ① hatched_into → mofi_collection.discovered_at（書くのは fn_hatch_egg のみ）
--       ② 無ければ eggs.created_at（列GRANT外・not null / 孵化時刻より必ず古い）
--     どちらも「実際の孵化より古い方向」にしかズレない＝週窓に入りにくい fail-closed 側。
--   * ★この UPDATE は trg_eggs_updated_at（0001:265-267）を発火させ、
--     set_updated_at（0001:27-35 の無条件 `new.updated_at = now()`）が
--     **全孵化卵の updated_at を適用時刻で塗り潰す**。updated_at は事後調査の唯一の
--     材料なので、バックフィルの間だけトリガーを外す。
--     同一Tx・直前の add column が ACCESS EXCLUSIVE を保持中なので、他セッションから
--     中間状態は見えない。所有者権限が無ければこの文で失敗し、適用ごとロールバックされる
--     （安全側に倒れる）。
--   * ⚠️ **このファイルは必ずトランザクション内で流すこと**（db-apply-v11.yml は
--     psql --single-transaction を使っている）。SQL エディタや素の `psql -f` で
--     単体実行すると、途中で失敗したときに trg_eggs_updated_at が**無効のまま残る**。
--     その状態では以後 eggs.updated_at が一切更新されなくなる。
alter table public.eggs disable trigger trg_eggs_updated_at;

--   ※ 図鑑行は「種×色違い」で1行しか無く(uq_collection_dex)、同じ種を2回目に孵しても
--     discovered_at は**初回発見時刻のまま**更新されない。よって重複入手の卵は
--     discovered_at < 自分の created_at になる。そのまま入れると「卵が作られる前に
--     孵化した」ことになり、整合性検査に引っかかる（かつ再実行では直せない）。
--     自分の created_at で下限クランプする。
update public.eggs e
   set hatched_at = greatest(
         coalesce(
           (select c.discovered_at from public.mofi_collection c where c.id = e.hatched_into),
           e.created_at),
         e.created_at)
 where e.location = 'hatched'
   and e.hatched_at is null;

alter table public.eggs enable trigger trg_eggs_updated_at;


-- ----------------------------------------------------------------------------
-- 2. hatched_at を立てるトリガー (fn_hatch_egg を書き換えずに済ませる)
-- ----------------------------------------------------------------------------
--   * 孵化への遷移 (location が hatched 以外 → hatched) のときだけ now() を刻む。
--   * 既に hatched_at がある行は上書きしない (再孵化は 0005 の H-1 で不可能だが、
--     万一の経路でも「最初の孵化日時」を保持する)。
--   * security definer は不要 (NEW を書き換えるだけで、他テーブルを読み書きしないため)。
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
  v_source_mode text;
  v_tz        text;
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
      -- ★型が number でも整数とは限らない。jsonb の number は numeric なので
      --   {"pkg": 0.5} は typeof='number' を通り、'0.5'::integer が 22P02 で落ちる
      --   （落ちると受取が「受け取りに失敗しました」になり、その期間ずっと詰まる）。
      --   numeric 経由で受けて範囲を検証し、切り捨てて整数化する。
      if (v_per_app ->> v_package)::numeric
           not between 0 and public.cfg_int('daily_minutes_max', 1440) then
        return false;
      end if;
      v_used := floor((v_per_app ->> v_package)::numeric)::integer;
      return v_used < v_target;

    when 'reduce_total' then
      -- 削減量 = その日の適用基準(baselines.applied_minutes) - その日の利用(total_minutes)。
      -- fail-closed: usage_daily 行が確定済みで baselines も存在する場合のみ判定。
      select b.applied_minutes, u.total_minutes, u.is_finalized, u.source_mode
        into v_baseline, v_today, v_finalized, v_source_mode
        from public.usage_daily u
        join public.baselines b
          on b.user_id = u.user_id and b.baseline_date = u.usage_date
       where u.user_id = p_uid and u.usage_date = p_period;
      if not found or v_finalized is not true
         or v_baseline is null or v_today is null then
        return false;
      end if;
      -- ★0015: 「計測できていない日」を「利用 0 分の日」と読み替えない。
      --   判別子は per_app の非空**ではない**。両OSとも 0 分のアプリはキーごと落とす実装
      --   （android_usage_provider.dart / ios_usage_provider.dart）なので
      --   `total=0 ⟺ per_app={}` が恒真になり、per_app では
      --   「計測できなかった日」と「対象SNSを1分も使わなかった日」を区別できない。
      --   それで弾くと、アプリが最も報いたい「完全に断てた Android ユーザー」だけが
      --   毎回 50pt を失う（しかも画面に理由が出ない）。
      --   正しい判別子は source_mode:
      --     * exact-minutes(Android)      … 0 分は「本当に使わなかった」＝達成させる
      --     * threshold-achievement(iOS)  … 0 分は「しきい値が発火しなかった」＝
      --       利用が無かった証拠にならない。基準値は下限30分にクランプされる(0012:167)ため
      --       このままだと毎日 30 分の削減が成立して 50pt が出てしまう＝未達に倒す。
      --   ⚠️ source_mode もクライアント入力なので、これは**細工した端末への防御ではない**
      --      （入力側の検証は別 migration の仕事）。ここで直るのは
      --      「正直なユーザーの誤爆」と「iOS の構造的な誤付与」。
      if v_today = 0 and v_source_mode = 'threshold-achievement' then
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
      --   ★週窓はユーザーTZで切る。period 側は fn_sync_quests が
      --     (now() at time zone <profiles.timezone>)::date を週初日にして作るのに、
      --     判定を UTC 日付でしていたため JST 月曜 00:00〜09:00 の孵化が前週に落ちていた。
      --     hatched_at が権威列になるぶん、このズレは恒久化する。
      select coalesce(timezone, 'Asia/Tokyo') into v_tz
        from public.profiles where id = p_uid;   -- definer なので RLS に妨げられない
      select count(*)::integer into v_val
        from public.eggs
       where user_id = p_uid
         and location = 'hatched'
         and hatched_at is not null
         and (hatched_at at time zone coalesce(v_tz, 'Asia/Tokyo'))::date
             between v_period_lo and v_period_hi;
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

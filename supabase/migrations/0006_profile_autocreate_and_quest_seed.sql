-- ============================================================================
-- 0006: profiles 自動作成トリガー + 既存ユーザーのバックフィル + quest_definitions seed
-- ============================================================================
-- 真因(2026-06-30 実機テストで発覚):
--   新規(匿名)ユーザーに public.profiles 行が一切作られていなかった。
--   * 0001 のコメント(L71)は「匿名認証で行が作られ」と想定していたが、
--     auth.users 追加時に profiles を作る標準トリガー(handle_new_user)が未実装だった。
--   * fn_claim_warmup は profiles を UPDATE するだけ(行を作らない)。
--   結果: profiles 行が無い → warmup(卵/pt)も loadServerSnapshot も失敗(空の巣)、
--         fn_sync_quests は profile_not_found(P0002)で例外 → クエスト「読み込み失敗」。
-- さらに quest_definitions が空だったため、クエストの中身も存在しなかった。
-- 本マイグレーションは冪等(再実行可能)。本番(moffy-prod)へ "DB Apply 0006" で適用する。
-- ============================================================================

-- 1. handle_new_user: auth.users 追加時に profiles 行を作る(Supabase 標準パターン)。
--    全列にデフォルトがあるので id だけ指定すればよい(timezone=Asia/Tokyo 等)。
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2. 既存ユーザーのバックフィル(プロフィール欠損を補う = 既にサインイン済みの匿名ユーザー)。
insert into public.profiles (id)
select u.id
  from auth.users u
 where not exists (select 1 from public.profiles p where p.id = u.id)
on conflict (id) do nothing;

-- 3. quest_definitions の seed(MVP 5件)。
--    condition は {type, target, package?}。client(QuestCondition.fromJson)と
--    server(quest_condition_met: target→minutes coalesce)の双方が読める形。
--    reward は {points, gems, egg_rarity}。固定報酬(S14: ストリーク倍率は掛けない)。
insert into public.quest_definitions (id, kind, title, description, condition, reward, is_active) values
  ('daily_reduce_30', 'daily', '30分減らそう', '対象SNSの合計を昨日より30分減らす',
   '{"type":"reduce_total","target":30}'::jsonb,
   '{"points":50,"gems":0,"egg_rarity":null}'::jsonb, true),
  ('daily_tiktok_under_20', 'daily', 'TikTokは20分まで', 'TikTokの利用を20分未満におさえる',
   '{"type":"app_under","target":20,"package":"com.zhiliaoapp.musically"}'::jsonb,
   '{"points":30,"gems":0,"egg_rarity":null}'::jsonb, true),
  ('daily_streak_keep', 'daily', '今日もキープ', 'ストリークを今日も維持する',
   '{"type":"streak_keep","target":1}'::jsonb,
   '{"points":20,"gems":0,"egg_rarity":null}'::jsonb, true),
  ('weekly_hatch_3', 'weekly', '今週3個孵そう', '今週中に卵を3個孵化させる',
   '{"type":"hatch_count","target":3}'::jsonb,
   '{"points":100,"gems":10,"egg_rarity":null}'::jsonb, true),
  ('weekly_points_1000', 'weekly', '今週1000pt', '今週の基礎ポイントを累計1000pt獲得',
   '{"type":"points_earn","target":1000}'::jsonb,
   '{"points":0,"gems":20,"egg_rarity":"rare"}'::jsonb, true)
on conflict (id) do nothing;

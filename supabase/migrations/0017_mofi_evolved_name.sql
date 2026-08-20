-- 0017: Mofi の「進化後の名前」を追加する。
--
-- 背景（オーナー判断 2026-08-19）:
--   収集ゲームで進化しても名前が変わらないのは不自然、という指摘。
--   進化前は略した子ども言葉（ぽてうさ・とかげり）なので、進化後は
--   カタカナの力強い名前に切り替える（ひらがな=やわらかい / カタカナ=成長した、の対比）。
--
-- 安全性:
--   * 列は nullable。未設定なら アプリ側が name に倒れるので、
--     この migration を当てる前でも後でもアプリは壊れない。
--   * 既存データの更新のみ。ユーザーデータ（mofi_collection）には触れない。

alter table public.mofi_species
  add column if not exists evolved_name text;

comment on column public.mofi_species.evolved_name is
  '進化後(stage2)の表示名。null なら name をそのまま使う（docs/EVOLUTION.md）';

update public.mofi_species set evolved_name = v.evolved_name
from (values
  ('slime_01',   'プルミエ'),
  ('slime_02',   'モチルド'),
  ('slime_03',   'キラーレ'),
  ('slime_04',   'ニジェンテ'),
  ('slime_05',   'シズクレイ'),
  ('critter_01', 'コロミナ'),
  ('critter_02', 'ポテラビス'),
  ('critter_03', 'マメキーゼ'),
  ('critter_04', 'フワリスタ'),
  ('critter_05', 'コンルナ'),
  ('dragon_01',  'トカゲイル'),
  ('dragon_02',  'ホノーガ'),
  ('dragon_03',  'ライドール'),
  ('dragon_04',  'コオリバル'),
  ('dragon_05',  'テンドラ'),
  ('beast_01',   'トラガル'),
  ('beast_02',   'ウルガン'),
  ('beast_03',   'レオンド'),
  ('beast_04',   'クロバルド'),
  ('beast_05',   'ビャクレン')
) as v(id, evolved_name)
where public.mofi_species.id = v.id;

-- 適用後の目視確認用:
--   select id, name, evolved_name from public.mofi_species order by sort_order;

-- 0017: Mofi の「進化後の名前」を追加し、進化前の名前も一部を改める。
--
-- 背景（オーナー判断 2026-08-19〜20）:
--   1. 収集ゲームで進化しても名前が変わらないのは不自然、という指摘。
--   2. 幼く見える原因は名前そのものではなく **表記** だった。
--      「らいりゅう(雷竜)」「とらまる(虎丸)」「びゃっこ(白虎)」のように
--      **本来漢字で書く言葉をひらがなにしている**ものが幼く見えていた。
--      一方「ぷるりん」「もちすら」は最初から造語なので違和感が無い。
--   3. 漢字は使わない方針なので、該当するものを**造語に作り替えた**。
--      外来語の「れおん」はカタカナ「レオン」へ。
--   4. 進化後の絵を確認したところ、**族ごとに方向性が違った**:
--        ドラゴン・獣 = 本格的で迫力のある姿（竜／咆哮する白虎）
--        スライム・小動物 = かわいいまま格が上がる
--      名前もそれに合わせ、迫力族は重いカタカナ、かわいい族はやわらかいカタカナにした。
--
-- 安全性:
--   * evolved_name は nullable。未設定ならアプリが name に倒れるので、
--     当てる前でも後でもアプリは壊れない。
--   * 更新するのはマスタ（mofi_species）だけ。
--     ユーザーデータ（mofi_collection）には一切触れない。
--
-- 📌 このアプリでは Mofi の名前を **アプリ側の kMofiSpeciesSeed が保持**しており、
--    表示はそちらが使われる。この migration は **DB を実装に揃えるためのもの**で、
--    リリースの前提ではない（当てなくても名前は反映される）。

alter table public.mofi_species
  add column if not exists evolved_name text;

comment on column public.mofi_species.evolved_name is
  '進化後(stage2)の表示名。null なら name をそのまま使う（docs/EVOLUTION.md）';

update public.mofi_species set
    name         = v.name,
    evolved_name = v.evolved_name
from (values
  ('slime_01',   'ぷるりん', 'プルリーナ'),
  ('slime_02',   'もちすら', 'モチェルラ'),
  ('slime_03',   'きらすら', 'キラシュラ'),
  ('slime_04',   'にじすら', 'ニジェーラ'),
  ('slime_05',   'しずくら', 'シズクレア'),
  ('critter_01', 'ころみ',   'コロミア'),
  ('critter_02', 'ぽてうさ', 'ポテラビス'),
  ('critter_03', 'まめきつ', 'マメキーネ'),
  ('critter_04', 'ふわりす', 'フワリスタ'),
  ('critter_05', 'こんこ',   'コンルナ'),
  ('dragon_01',  'とかげり', 'ドラゴウル'),
  ('dragon_02',  'ほのり',   'ヴォルグレア'),
  ('dragon_03',  'らいむ',   'ライゼクス'),
  ('dragon_04',  'こおりん', 'フリーゼル'),
  ('dragon_05',  'てんら',   'セレスドラ'),
  ('beast_01',   'とらむ',   'ヴァルガ'),
  ('beast_02',   'うるが',   'ウルガンド'),
  ('beast_03',   'レオン',   'レオガルド'),
  ('beast_04',   'くろむ',   'クロヴァルグ'),
  ('beast_05',   'びゃくり', 'ビャクレイヴ')
) as v(id, name, evolved_name)
where public.mofi_species.id = v.id;

-- 適用後の目視確認用:
--   select id, name, evolved_name from public.mofi_species order by sort_order;

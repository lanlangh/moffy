-- ============================================================================
-- 0008: 獣(beast)5種を追加 + 図鑑総数 30→40（0007 で enum に 'beast' 追加済み前提）
-- ----------------------------------------------------------------------------
-- オーナー決定(2026-07-02): "かっこいい"枠（男性ユーザー訴求）をもう1系統。
--   スライム/小動物=かわいい、ドラゴン/獣=かっこいい で カワイイ10:カッコいい10。
-- 経済への影響: **なし**。抽選確率は drop_tables（卵レア→Mofiレア分布）で決まり、
--   種の追加は「同一レア度内の個体均等抽選」の枠が増えるだけ（rarity odds / points 不変）。
-- 冪等（on conflict do nothing / 決め打ち update）。本番へ 0007→0008 の順に適用。
-- ============================================================================

-- 獣5種（§4-1 / C2/R1/SR1/SSR1）。
insert into public.mofi_species (id, family, rarity, name, sort_order) values
  ('beast_01', 'beast', 'common', 'とらまる', 16),
  ('beast_02', 'beast', 'common', 'うるが',   17),
  ('beast_03', 'beast', 'rare',   'れおん',   18),
  ('beast_04', 'beast', 'sr',     'くろば',   19),
  ('beast_05', 'beast', 'ssr',    'びゃっこ', 20)
on conflict (id) do nothing;

-- 図鑑総エントリー数を 30→40（20種×2色）。コンプ率の分母。
update public.app_config
  set value = '40'::jsonb,
      description = 'S13 図鑑総エントリー数(20種×2色)。コンプ率の分母'
  where key = 'dex_total_entries';

-- 適用後の目視確認用:
--   select family, count(*) from public.mofi_species group by family order by family;
--   select value from public.app_config where key = 'dex_total_entries';

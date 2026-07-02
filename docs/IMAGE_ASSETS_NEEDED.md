# 生成が必要な画像アセット一覧（オーナー生成 → フォルダに配置）

見た目の方向は **C土台＋Aの手描きインク輪郭**（`docs/DESIGN_DIRECTION.md`）。**全アセット共通ルール**:
- **背景は完全透過（PNGアルファ）**・正方形1024×1024・地面影を落とさない（アプリが巣リング＋影を描く）。
- やわらか3D風・パステル・**光源は左上・単一**（全アセットで統一）。
- **シルエットに焦げ茶インク`#4A3B2E`の手描き風輪郭を1本**（＝Moffiの目印。生成後にこちらで輪郭処理を通してもOK）。
- 文字・枠・ロゴを入れない。

配置先フォルダ（無ければ作成／pubspecはこちらで登録します）:
- Mofi キャラ → `assets/images/mofi/`
- 卵 → `assets/images/egg/`（既存を上書き）

---

## 🥇 最優先：Mofi キャラ 15種 × 2進化段階 ＝ 30体（＝図鑑の主役・今は仮アイコン）

**進化仕様（`docs/EVOLUTION.md`）**: 各 Mofi は「ベビー→アダルト」の2段。**1種につき2枚**必要:
- ベビー … `mofi_<id>_1.png`
- アダルト … `mofi_<id>_2.png`
- 例: `mofi_slime_01_1.png`（ベビー）/ `mofi_slime_01_2.png`（アダルト）

- **巣なし・単体**（アプリが巣リング＋地面影を描く）。
- **色違い（shiny）は別アート不要**（プログラムで色替え）。
- **ベビー**＝丸く小さめ・赤ちゃん寄り／**アダルト**＝一回り大きく、特徴（角・翼・尻尾・宝石など）が
  はっきり。**種族・色の系統は両段で共通**にして「同じ子が育った」と一目で分かるように。
- まずは各種の**ベビー（_1）を15枚**そろえると図鑑が埋まり、進化演出も確認できます（_2 は後追い可）。

生成プロンプト（英語推奨）に足す共通文:
```
A cute original collectible creature, soft 3D-rendered kawaii mobile-game style, gentle pastel colors,
warm soft lighting from top-left, rounded friendly shapes, big expressive eyes, chibi proportions.
Full body, centered, plain transparent background (PNG alpha), NO ground shadow, NO text.
Square 1:1, 1024x1024.
```

| id | 種族 | レア | 名前 | ベビー `_1` のヒント | アダルト `_2` のヒント |
|---|---|---|---|---|---|
| slime_01 | スライム | N | ぷるりん | 水色の小さなぷるぷる、ほっぺ | 一回り大きく水しぶきの飾り |
| slime_02 | スライム | N | もちすら | 白〜クリームの小さな餅スライム | ふくらんで鏡餅風の段 |
| slime_03 | スライム | R | きらすら | 水色＋小さな宝石のきらめき | 全身が結晶化して光る |
| slime_04 | スライム | R | にじすら | 淡い虹色の小スライム | 虹の帯・オーラが強まる |
| slime_05 | スライム | SR | しずくおう | 雫型＋小さな王冠（紫系＝SR可） | 大きな王冠・宝珠をまとう |
| critter_01 | 小動物 | N | ころみ | 丸い茶色ハムスター風の赤ちゃん | 頬袋がふくらみ一回り大きく |
| critter_02 | 小動物 | N | ぽてうさ | ぽてっとした白い子うさぎ | 耳が伸び、りぼん等の飾り |
| critter_03 | 小動物 | R | まめきつ | 小さなキツネ、耳大きめ | 尾が増え/大きくなり凛々しく |
| critter_04 | 小動物 | R | ふわりす | ふわふわ子リス、尻尾ちょい大 | 尻尾が巨大にふさふさ |
| critter_05 | 小動物 | SSR | こんげつ | 月モチーフの子狐（金＝SSR配色） | 尾が複数・月の輪をまとう神秘 |
| dragon_01 | ドラゴン | N | とかげり | 小さな緑のトカゲ竜（赤ちゃん） | 角と小さな翼が生える |
| dragon_02 | ドラゴン | R | ほのおこ | オレンジの炎をまとう子竜 | 炎が大きく翼が広がる |
| dragon_03 | ドラゴン | SR | らいりゅう | 雷（黄/紫）をまとう子竜（紫可＝SR） | 雷をまとい角・翼が発達 |
| dragon_04 | ドラゴン | SR | こおりば | 氷・水色の子竜 | 氷の結晶の角・翼 |
| dragon_05 | ドラゴン | SSR | てんりゅう | 金色の子天竜（SSR＝金） | 荘厳な金の天竜・後光 |

> レア色の目安（`RarityToken`）: N=霧緑 / R=水色 / **SR=紫（キャラのSRだけ紫OK）** / SSR=金。
> **shiny は作らなくてOK**（プログラムで色替え）。まず通常色の30体（またはベビー15体）から。

### ★ 進化前後を「1回の生成で」出すプロンプト（推奨＝一貫性が高い）

1種ぶんの「ベビー＋アダルト」を **1回の生成で横並び1枚** に出す → こちらで2枚に切り分け。
同じ生成なので画風・配色・顔が確実に揃う（`mofi_<id>_1.png` / `mofi_<id>_2.png` に分割配置）。

英語プロンプト（`[BABY]` / `[ADULT]` を各種の説明に差し替え）:
```
A character reference sheet of ONE original cute collectible creature shown in its TWO
evolution stages, side by side with a clear gap, on a plain flat white background.
LEFT = BABY form: [BABY].
RIGHT = ADULT (evolved) form, clearly the SAME creature grown up: [ADULT].
Both full-body, centered in their own half, similar scale, facing the viewer. Keep the
SAME art style, SAME color palette, SAME face / eye style, and SAME soft lighting from the
upper-left for both. Soft 3D-rendered kawaii mobile-game style, gentle pastel colors, big
expressive eyes, chibi proportions, rounded friendly shapes, smooth soft shading.
Plain flat white background (easy to cut out), NO ground shadow, NO nest, NO text, NO
labels, NO frame, NO extra props. Wide 2:1 image, high detail.
```
- `[BABY]` / `[ADULT]` は上の表の「ベビー/アダルトのヒント」を使う。
- ツールが2枚同時出力できるなら左右でなく「2枚」でもOK。**1枚に含めてくれれば私が切り分け＋インク輪郭焼き込み＋リサイズ＋配線**します（卵と同じ工程）。
- インク輪郭・背景透過は**こちらで後処理**するので、プロンプトに入れなくてよい。

### 差し替え用 `[BABY]` / `[ADULT]` 英語（15種・そのまま貼れる）

**プロンプトは全部英語で統一**（英語テンプレに日本語を混ぜると精度・一貫性が落ちやすい）。
下をそのまま `[BABY]` / `[ADULT]` に入れる。ADULT は "the same ..." で始めて「同じ子の成長」を明示。

**スライム**
- `slime_01` ぷるりん(N) — BABY: `a tiny round pale sky-blue jelly slime with rosy cheeks, a big happy smile and simple dot eyes` / ADULT: `the same sky-blue jelly slime, a bit taller and shinier, with small water-droplet frills on top`
- `slime_02` もちすら(N) — BABY: `a tiny soft cream-white mochi-like slime, squishy and round, tiny dot eyes and a calm smile` / ADULT: `the same cream mochi slime, grown taller and puffier, formed of two stacked rounded mochi tiers`
- `slime_03` きらすら(R) — BABY: `a small aqua-blue jelly slime with a few tiny sparkling gem facets on its body and bright eyes` / ADULT: `the same aqua slime, now semi-crystalline and glossy, its body glinting like polished gemstone`
- `slime_04` にじすら(R) — BABY: `a small slime with a soft pastel rainbow gradient body and a cheerful face` / ADULT: `the same rainbow slime, larger, with brighter flowing rainbow bands and a gentle glow`
- `slime_05` しずくおう(SR) — BABY: `a small violet water-droplet-shaped slime wearing a tiny golden crown, cute` / ADULT: `the same violet droplet slime, taller and regal, with a larger ornate crown and a small floating orb`

**小動物**
- `critter_01` ころみ(N) — BABY: `a tiny round brown hamster-like critter with big cheeks, tiny paws and big sparkly eyes` / ADULT: `the same brown hamster, grown a little bigger with fuller cheeks and a soft cream tummy`
- `critter_02` ぽてうさ(N) — BABY: `a pudgy little white bunny with short round ears, pink cheeks and big eyes` / ADULT: `the same white bunny, grown with longer floppy ears and a small ribbon`
- `critter_03` まめきつ(R) — BABY: `a small orange fox kit with oversized pointy ears and a fluffy tail` / ADULT: `the same orange fox, grown sleeker with a larger bushy tail, looking dignified`
- `critter_04` ふわりす(R) — BABY: `a tiny fluffy brown squirrel with a small puffy tail and round cheeks` / ADULT: `the same squirrel, grown with an enormous ultra-fluffy tail curling over its back`
- `critter_05` こんげつ(SSR) — BABY: `a small mystical golden fox kit with crescent-moon markings and softly glowing eyes` / ADULT: `the same golden fox, grown with several flowing tails and a glowing moon halo, mystical`

**ドラゴン（＝“かっこいい”枠・男性ユーザー向け。下の「ドラゴン専用テンプレ」を使う）**
- `dragon_01` とかげり(N) — BABY: `a small spunky green baby dragon with tiny sharp horns and a determined look, cute but tough` / ADULT: `the same green dragon evolved into a sleek cool adult with sharp horns, spread wings, claws and a confident fierce pose`
- `dragon_02` ほのおこ(R) — BABY: `a small fiery orange baby dragon with a spark of flame and a bold brave look` / ADULT: `the same dragon evolved into a cool blazing adult, flames along its back, spikes, wings spread wide, powerful stance`
- `dragon_03` らいりゅう(SR) — BABY: `a small violet baby dragon crackling with tiny lightning sparks, sharp-eyed` / ADULT: `the same dragon evolved into a cool storm dragon, sleek body wreathed in yellow-and-purple lightning, sharp horns and wings`
- `dragon_04` こおりば(SR) — BABY: `a small pale ice-blue baby dragon with tiny ice spikes, cool-looking` / ADULT: `the same dragon evolved into a cool ice dragon with sharp crystalline horns, jagged icy wings and a proud stance`
- `dragon_05` てんりゅう(SSR) — BABY: `a small radiant golden baby dragon with a noble brave look` / ADULT: `the same dragon evolved into a majestic imposing golden celestial dragon, serpentine and powerful, divine and cool`

> **ドラゴン専用テンプレ**（共通テンプレの代わりに使う）。レンダリング・光・世界観は同じまま、
> キャラ設計だけ “kawaii/chibi” → “cool/sleek/fierce” に振る＝同じ世界の中に「かっこいい枠」を作る
> （ポケモンでピカチュウとリザードンが同居する感じ）:
> ```
> A character reference sheet of ONE original COOL collectible dragon shown in its TWO
> evolution stages, side by side with a clear gap, on a plain flat white background.
> LEFT = BABY form: [BABY].
> RIGHT = ADULT (evolved) form, clearly the SAME dragon grown up and much cooler: [ADULT].
> Both full-body, centered in their own half, in a confident dynamic pose, facing the viewer.
> Keep the SAME color palette and SAME soft lighting from the upper-left for both. Soft
> 3D-rendered mobile-game mascot style, same clean rendering as the cute creatures BUT this
> one is COOL, not kawaii: sleek and sharp, defined horns / spikes / claws / wings, sharper
> determined eyes, a slightly fierce heroic badass vibe, appealing and polished.
> Plain flat white background (easy to cut out), NO ground shadow, NO nest, NO text, NO
> labels, NO frame, NO extra props. Wide 2:1 image, high detail.
> ```

---

## 🥈 任意：卵イラストの高品質版（今は参照シートからの切り出し＋輪郭で運用中）

`docs/EGG_ART_PROMPT.md` の通り。4レア（common霧緑/rare水色/sr紫/ssr金＝星）×（無傷/ヒビ①/ヒビ②）。
段階画像を用意すると、成長で卵の絵そのものが変わります（今は簡易ヒビ線を重ねて代用）。
ファイル名: `egg_common.png`（段階まで作るなら `egg_common_intact/crack1/crack2.png`）。

---

## 🥉 任意：空巣の器（空状態用）

卵もキャラも入っていない「空の藁の巣」1枚（透過）。`assets/images/ui/nest_empty.png`。
今はアプリが淡い卵型プレースホルダで代用中なので、これは後回しで可。

---

## 渡し方
- `assets/images/mofi/`（Mofi）/ `assets/images/egg/`（卵）に入れてファイル名を教えてください。
  私が **pubspec 登録＋アプリ配線＋（必要なら）インク輪郭処理** をして反映します（届いた分から順に）。
- おすすめ着手順: ①各種の**ベビー `_1` を15枚** → 図鑑が埋まる ②**アダルト `_2` を15枚** → 進化が完成 ③**卵4種**。

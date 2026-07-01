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

## 🥇 最優先：Mofi キャラ 15種（＝図鑑の主役・今は仮アイコン）

各キャラを**巣なし・単体**で。ファイル名＝`mofi_<id>.png`。色違い（shiny）は**同じ形の色替え**なので、
まず15種の通常色を用意すれば図鑑が埋まります（shiny は後追いでも可＝`mofi_<id>_shiny.png`）。

生成プロンプト（英語推奨）に足す共通文:
```
A cute original collectible creature, soft 3D-rendered kawaii mobile-game style, gentle pastel colors,
warm soft lighting from top-left, rounded friendly shapes, big expressive eyes, chibi proportions.
Full body, centered, plain transparent background (PNG alpha), NO ground shadow, NO text.
Square 1:1, 1024x1024.
```

| id | ファイル名 | 種族 | レア | 名前 | 生成のヒント（見た目の方向） |
|---|---|---|---|---|---|
| slime_01 | `mofi_slime_01.png` | スライム | N | ぷるりん | 水色のぷるぷるスライム、ほっぺ |
| slime_02 | `mofi_slime_02.png` | スライム | N | もちすら | 白〜クリームの餅っぽいスライム |
| slime_03 | `mofi_slime_03.png` | スライム | R | きらすら | 水色＋キラッと光る宝石質感 |
| slime_04 | `mofi_slime_04.png` | スライム | R | にじすら | 淡い虹色グラデのスライム |
| slime_05 | `mofi_slime_05.png` | スライム | SR | しずくおう | 王冠を乗せた雫型スライム（紫系＝SRのみ紫可） |
| critter_01 | `mofi_critter_01.png` | 小動物 | N | ころみ | 丸い小動物（ハムスター風）茶色 |
| critter_02 | `mofi_critter_02.png` | 小動物 | N | ぽてうさ | ぽてっとした白うさぎ |
| critter_03 | `mofi_critter_03.png` | 小動物 | R | まめきつ | 小さなキツネ、耳が大きめ |
| critter_04 | `mofi_critter_04.png` | 小動物 | R | ふわりす | ふわふわのリス、大きな尻尾 |
| critter_05 | `mofi_critter_05.png` | 小動物 | SSR | こんげつ | 月モチーフの神秘的な狐（金＝SSR配色） |
| dragon_01 | `mofi_dragon_01.png` | ドラゴン | N | とかげり | 小さな緑のトカゲ竜、赤ちゃん風 |
| dragon_02 | `mofi_dragon_02.png` | ドラゴン | R | ほのおこ | オレンジの炎をまとう子竜 |
| dragon_03 | `mofi_dragon_03.png` | ドラゴン | SR | らいりゅう | 雷（黄/紫）をまとう竜（紫可＝SR） |
| dragon_04 | `mofi_dragon_04.png` | ドラゴン | SR | こおりば | 氷・水色の竜 |
| dragon_05 | `mofi_dragon_05.png` | ドラゴン | SSR | てんりゅう | 金色の荘厳な天竜（SSR＝金の華やかさ） |

> レア色の目安（`RarityToken`）: N=霧緑 / R=水色 / **SR=紫（キャラのSRだけ紫OK）** / SSR=金。
> shiny版を作るなら、通常色から色相をずらした特別配色（例: 通常青→shinyは金や桃）にすると「特別感」が出ます。

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
- 上記フォルダに入れて教えていただければ、私が **pubspec 登録＋アプリ配線＋（必要なら）インク輪郭処理** をして反映します。
- まず **Mofi 15種（通常色）** から着手すると、図鑑・孵化演出が一気に本物になります。

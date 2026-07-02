# 卵イラスト生成プロンプト（GPT / 画像生成用）

オーナーが GPT（画像生成）で卵イラストを作るための指示書。生成後 `assets/images/egg/` に
配置し、開発が `EggArt` に配線する。**背景は透過（PNGアルファ）**が必須。もし生成物が
白/単色背景なら、こちらで背景を除去できる（透過で出せるならそのままでOK）。

> **署名のインク輪郭（焦げ茶 `#4A3B2E`）はこちらで後処理(PIL)で焼き込みます**＝現行4種と
> 同じ工程なので画風が揃う。プロンプトに太い輪郭を入れる必要はありません。
> **巣（藁）は卵と一緒に描く**（アプリは砂リングを別に描く二層構成なので、藁の巣は画像に含める）。

---

## 共通スタイル（すべての卵で固定）

英語プロンプト（画像生成は英語が安定）:

```
A single cute collectible egg cradled in a small round woven straw nest, soft 3D-rendered
kawaii mobile-gacha-game art style, smooth glossy eggshell with a soft specular highlight
in the UPPER-LEFT from a single warm light source, gentle rounded friendly shape, clean
high-quality soft shading, Nintendo/Pokemon-toy-like charm. The egg is large and centered
and the little straw nest cradles its base. Plain transparent background (PNG alpha);
NO cast/ground shadow, NO text, NO border, NO frame, NO extra objects.
Square 1:1, 1024x1024, crisp, consistent egg shape / nest / lighting across the whole set.
```

日本語メモ: 「藁の小さな巣に抱かれたかわいい卵／やわらか3Dガチャ風／つやのある殻・光は
**左上から**の一灯／中央・卵大きめ／**背景は完全透過・地面影なし・文字/枠なし**／4種で
卵形・巣・ライティングを揃える」。

---

## レアリティ別（殻と斑点の色）— 上の共通文に足す

| レアリティ | 追記する英語（現行アセットに合わせて調整） |
|---|---|
| common（ノーマル） | `cream / off-white shell with soft blurry-edged SAGE-GREEN blotches and small speckles; a small shallow light-brown woven straw nest` |
| rare（レア） | `cream / off-white shell with soft blurry-edged SKY-BLUE blotches and speckles; a fuller warm-brown woven straw nest` |
| sr / epic（エピック） | `cream / off-white shell with soft blurry-edged blotches in TWO tones of PINK and LAVENDER-PURPLE; a small warm-brown woven straw nest` |
| ssr / legend（レジェンド） | `deep royal-PURPLE glossy shell scattered with five-pointed GOLDEN stars of varying sizes, premium golden magical shimmer and a bright highlight; a golden softly-glowing woven straw nest; a legendary luxurious feel` |

> **画風を揃える最大のコツ**: まず common を1枚作り、残り3種は **既存の `assets/images/egg/egg_common.png`
> （または最初に作った1枚）を「参照画像」として添付**し、「**同じ画風・同じ卵形・同じ巣・同じライティングで、
> 殻の色と模様だけ〔レア色〕に変える**」と指示する。テキストだけより圧倒的に揃う。

---

## 成長段階別（ヒビ）— さらに足す

同じ卵で「無傷 → ヒビ① → ヒビ②」の3枚を、**殻の色・巣・アングルを揃えて**作る
（3枚で殻がバラバラだと段階に見えないので、同一シードや「same egg, only cracks change」を指定）。

| 段階 | 追記する英語 |
|---|---|
| intact（たまご） | `perfectly smooth shell, no cracks` |
| crack1（ヒビ①） | `a few small thin hairline cracks near the top of the shell` |
| crack2（ヒビ②） | `larger spreading cracks, one small shell piece slightly lifting, about to hatch, a faint warm light glowing from inside the cracks` |

---

## ファイル名（この名前で保存してくれれば開発がそのまま配線できる）

- ベース1枚だけでも可: `egg_common.png` / `egg_rare.png` / `egg_sr.png` / `egg_ssr.png`
- 段階まで作る場合: `egg_common_intact.png` / `egg_common_crack1.png` / `egg_common_crack2.png`
  （rare / sr / ssr も同様）

※ 段階画像を用意してもらえれば、アプリはヒビ段階でその画像に切り替える（今は暫定として
アプリ側で簡易的なヒビ線を卵の上に重ねて段階変化を出している）。

## サイズ・技術要件
- 1024×1024、正方形、**透過PNG**。
- 卵（＋小さい巣）が中央でフレームの7〜8割を占める。
- 影を「地面」に落とさない（アプリが巣リングと影を描くため）。
- 文字・枠・ロゴを入れない。

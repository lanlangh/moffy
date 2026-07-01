# 卵イラスト生成プロンプト（GPT / 画像生成用）

オーナーが GPT（画像生成）で卵イラストを作るための指示書。生成後 `assets/images/egg/` に
配置し、開発が `EggArt` に配線する。**背景は透過（PNGアルファ）**が必須。もし生成物が
白/単色背景なら、こちらで背景を除去できる（透過で出せるならそのままでOK）。

---

## 共通スタイル（すべての卵で固定）

英語プロンプト（画像生成は英語が安定）:

```
A cute collectible egg resting in a small round straw nest, soft 3D-rendered kawaii
mobile-game art style, gentle pastel colors, warm soft studio lighting, smooth glossy
shell with subtle speckles, rounded friendly shapes, Nintendo-like charm.
Centered composition; the egg + little nest fill most of the frame.
Plain transparent background (PNG alpha), NO ground shadow, NO text, NO border, NO frame.
Square 1:1, 1024x1024, high detail, consistent lighting across the set.
```

日本語メモ: 「藁の小さな巣に乗ったかわいい卵／やわらか3D・パステル・あたたかい光／
つやのある殻に控えめな斑点／中央・卵が大きく／**背景は完全透過・地面影なし・文字なし**」。

---

## レアリティ別（殻と斑点の色）— 上の共通文に足す

| レアリティ | 追記する英語 |
|---|---|
| common（ノーマル） | `cream/off-white shell with soft grey-green blotchy speckles` |
| rare（レア） | `cream shell with sky-blue blotchy speckles` |
| epic/SR（エピック） | `cream shell with soft lavender-purple blotchy speckles` |
| legend/SSR（レジェンド） | `deep royal-purple shell decorated with glowing golden stars, premium magical shimmer` |

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

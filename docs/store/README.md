# ストア掲載アセット（Google Play）

Google Play / App Store 提出用のグラフィック素材置き場。

## フィーチャーグラフィック（Play 必須）
- **`feature_graphic_1024x500.png`** … 提出用の最終ファイル。**ちょうど 1024×500 px**（Play 要件）。これをそのまま Play Console にアップロードする。
- **`feature_graphic_source.png`** … 元データ（マスター / 1794×876・比率2.048＝1024×500と同一）。GPT 画像生成（gpt-image）で作成し、これを縮小して最終ファイルにした。文言・キャラを直したいときはここから作り直す。

### 再書き出し（マスター → 1024×500）
```bash
python -c "from PIL import Image; \
Image.open('docs/store/feature_graphic_source.png').convert('RGB') \
  .resize((1024,500), Image.LANCZOS) \
  .save('docs/store/feature_graphic_1024x500.png','PNG',optimize=True)"
```

### 内容・審査メモ
- ワードマーク「Moffy」＋タグライン「見ない時間が、ごほうびになる」＋サブ「スマホ時間で、かわいいキャラを集めよう」。
- キャラ＝ベビードラゴン（カッコいい枠）＋スライム/小動物（かわいい枠）＝御社デザイン決定（`docs/DESIGN_DIRECTION.md`）と一致。
- **価格・「無料」・「割引」表記なし**（Play/Apple 要件）。未実装特典（限定Mofi/プレミアム卵）は描かない（景表法・3.1.2 / `docs/ASO.md` §0）。

## ストア用アプリアイコン（512×512・Play 必須）
- **`store_icon_512.png`** … Play Console の「ストアの設定 → アプリのアイコン」に使う 512×512・32-bit PNG。
- 端末のランチャーアイコン（アダプティブ：前景=巣のSSR星卵 / 背景=`#EB8C58`）と**一致**するよう、前景 `mipmap-xxxhdpi/ic_launcher_foreground.png` を同じテラコッタ背景に合成して作成（`gen_store_icon.py`）。角丸は Play 側が付けるので、被写体は中央・余白ありで欠けない。
- 生成/再作成：`python docs/store/gen_store_icon.py`（scratchpad で実行→ `store_icon_512.png` を差し替え）。

## 未作成（今後）
- スクリーンショット（撮影ガイド＝`docs/ASO.md` §スクショ）

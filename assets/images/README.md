# 画像アセット置き場

本番イラスト（卵・Mofi・UI）をここに入れる。仕様・命名・組み込み手順は
[`docs/ART_ASSETS.md`](../../docs/ART_ASSETS.md) を参照。

- `egg/` … 卵（レアリティ×成長段階）
- `mofi/` … キャラ（通常・色違い）
- `ui/` … 通貨・バッジ等

⚠️ `pubspec.yaml` の `flutter.assets` への登録は、**実ファイルを入れてから**行うこと
（空ディレクトリを宣言すると `flutter pub get` が失敗する）。

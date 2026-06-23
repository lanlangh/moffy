import 'tab_icons.dart';

/// ボトムナビ5タブの定義（SCREEN_FLOWS §0 / DESIGN_SYSTEM §6）。
/// 順序: ホーム / たまご / 図鑑 / クエスト / メニュー。
enum AppTab {
  home(path: '/home', label: 'ホーム', glyph: TabGlyph.home),
  eggs(path: '/eggs', label: 'たまご', glyph: TabGlyph.egg),
  collection(path: '/collection', label: '図鑑', glyph: TabGlyph.dex),
  quests(path: '/quests', label: 'クエスト', glyph: TabGlyph.quest),
  menu(path: '/menu', label: 'メニュー', glyph: TabGlyph.menu);

  const AppTab({
    required this.path,
    required this.label,
    required this.glyph,
  });

  /// シェル内のブランチルートパス。
  final String path;

  /// ボトムナビのラベル（アクティブ時のみ表示）。
  final String label;

  /// SVGアイコン種別（塗り/ラインの2状態を [TabIcon] が描く）。
  final TabGlyph glyph;

  /// 現在の location からアクティブタブを判定する（前方一致）。
  static int indexForLocation(String location) {
    for (var i = 0; i < AppTab.values.length; i++) {
      if (location.startsWith(AppTab.values[i].path)) return i;
    }
    return 0;
  }
}

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_tab.dart';

/// 各タブの主スクロールの controller。
///
/// 開いているタブをもう一度押したら、そのページの先頭へ戻すために共有する
/// （2026-10-26 オーナー提案）。タブの画面は IndexedStack で生き続けるので、
/// controller もアプリが動いている間は持ち続ける（autoDispose にしない）。
/// 1つの controller は、そのタブの主スクロール1つにだけ渡すこと。
final tabScrollControllerProvider =
    Provider.family<ScrollController, AppTab>((ref, tab) {
  final controller = ScrollController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// そのタブの主スクロールを先頭へ戻す（表示されていなければ何もしない）。
void scrollTabToTop(WidgetRef ref, AppTab tab) {
  final controller = ref.read(tabScrollControllerProvider(tab));
  if (!controller.hasClients) return;
  controller.animateTo(
    0,
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
  );
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/collection_repository.dart';
import '../domain/mofi_models.dart';

/// 図鑑のフィルタ状態（レアリティ / 色違いトグル / SCREEN_FLOWS §4）。
class CollectionFilter {
  /// null=全レアリティ。指定時はそのレアリティのみ。
  final MofiRarity? rarity;

  /// true=色違いのみ表示。
  final bool shinyOnly;

  const CollectionFilter({this.rarity, this.shinyOnly = false});

  CollectionFilter copyWith({MofiRarity? rarity, bool? shinyOnly, bool clearRarity = false}) =>
      CollectionFilter(
        rarity: clearRarity ? null : (rarity ?? this.rarity),
        shinyOnly: shinyOnly ?? this.shinyOnly,
      );

  /// エントリがこのフィルタに合致するか。
  bool matches(MofiDexEntry e) {
    if (shinyOnly && !e.isShiny) return false;
    if (rarity != null && e.species.rarity != rarity) return false;
    return true;
  }
}

/// フィルタ状態の Provider（UIトグルで更新）。
final collectionFilterProvider =
    NotifierProvider<CollectionFilterNotifier, CollectionFilter>(
  CollectionFilterNotifier.new,
);

class CollectionFilterNotifier extends Notifier<CollectionFilter> {
  @override
  CollectionFilter build() => const CollectionFilter();

  /// レアリティをトグル（同じものを再選択で解除）。
  void toggleRarity(MofiRarity r) {
    state = state.rarity == r
        ? state.copyWith(clearRarity: true)
        : state.copyWith(rarity: r);
  }

  void toggleShiny() => state = state.copyWith(shinyOnly: !state.shinyOnly);
}

/// 図鑑コントローラ（再読込のため AsyncNotifier をラップ）。
/// 達成率は [CollectionState] が算出する（コンプ率 = 発見数 / 総数）。
class CollectionController extends AsyncNotifier<CollectionState> {
  @override
  Future<CollectionState> build() async {
    return ref.watch(collectionStateProvider.future);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    ref.invalidate(collectionStateProvider);
    state = await AsyncValue.guard(() => ref.read(collectionStateProvider.future));
  }
}

final collectionControllerProvider =
    AsyncNotifierProvider<CollectionController, CollectionState>(
  CollectionController.new,
);

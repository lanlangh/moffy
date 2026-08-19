import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/egg_models.dart';

/// 孵化の結果と、その孵化が進化に与えた意味をまとめたもの。
///
/// なぜ [HatchResult] だけでは足りないか:
///   サーバーの `fn_hatch_egg` が返すのは「どの Mofi が出たか」までで、
///   **その子が何体目か（obtainedCount）は返さない**。進化は重複入手で起きる
///   （docs/EVOLUTION.md: 同一個体を3体そろえるとアダルト）ので、
///   演出を出し分けるには孵化後の所持数が要る。
///   → サーバーを変えず、**孵化後に図鑑を読み直して所持数を得る**（呼び出し側の責務）。
class HatchPresentation {
  const HatchPresentation({
    required this.result,
    required this.stage,
    required this.justEvolved,
    required this.toNextEvolution,
  });

  final HatchResult result;

  /// 進化段階（1=ベビー / 2=アダルト）。孵化後の所持数から算出した実データ。
  final int stage;

  /// **この孵化で**進化のしきい値を跨いだか。
  /// すでにアダルトの子をもう1体引いた場合は false（毎回「進化！」を出さない）。
  final bool justEvolved;

  /// 進化まであと何体か。0 なら進化済み。
  final int toNextEvolution;
}

/// 孵化したばかりで、まだ図鑑へ送っていない Mofi。
///
/// なぜ要るか（2026-08-19 オーナー提案）:
///   従来は孵化演出が終わると Mofi は即座に図鑑へ行き、たまごタブには
///   「空の巣」だけが残った。**育てた子を眺める間が1秒も無い**。
///   コレクション型のいちばん嬉しい瞬間が、演出の数秒で消えていた。
///   → 孵化後はステージに残し、「図鑑に送る」を押すか、次の卵を育て始めた
///     ときに送られる、という間を作る。
///   進化に到達した回は**アダルトの姿がステージに残る**ので、
///   「重ねて育てると姿が変わる」という仕組みが目で分かるようになる。
///
/// 保持場所について:
///   図鑑への登録自体は**孵化した時点でサーバー側が済ませている**
///   （`fn_hatch_egg` が原子的に mofi_collection を upsert する）。
///   ここで持つのは**表示のための一時状態だけ**で、押し忘れてもデータは失われない。
///   だからアプリを閉じれば消えてよく、永続化しない（＝復旧の複雑さを持ち込まない）。
final pendingHatchProvider = StateProvider<HatchPresentation?>((ref) => null);

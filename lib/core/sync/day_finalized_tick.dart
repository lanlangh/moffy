import 'package:flutter_riverpod/flutter_riverpod.dart';

/// サーバー確定（`fn_submit_and_finalize_day`）が成功するたびに増える「確定イベント」の合図。
///
/// 発火元は [SyncService]（`core/sync/sync_service.dart`）＝確定RPCの結果を唯一知る場所。
/// 購読側は features のコントローラ（ホーム残高・たまご・クエスト）で、これを watch して
/// サーバー状態を再取得する。
///
/// ## 独立ファイルである理由
/// 発火元 `sync_service.dart` と、それを駆動する `daily_submission.dart` の相互 import を
/// 避けるため。core が features を import すると層が逆転するので、core は「合図」だけを
/// 公開し、何を再取得するかは features 側が決める（ARCHITECTURE §1-2）。
///
/// ## ⚠️ 確定で変わるサーバー状態を読む Provider は **すべて** これを watch すること
/// `ref.watch` は「購読」であって「再実行」ではない。ある Provider が本 tick を watch して
/// いなければ、tick が増えてもその Provider は**キャッシュを返し続ける**。確定で
/// 残高・卵の成長（`fn_apply_growth`）・クエスト進捗が同時に変わるため、1つでも watch し
/// 忘れると「ptは入ったのに卵が育っていない」という画面不整合になる
/// （Codex 第2次レビュー #6 / 実際に eggs・quests が watch 漏れしていた）。
///
/// 現在の購読者:
///   * `features/home/presentation/home_controller.dart`
///   * `features/eggs/presentation/eggs_controller.dart`
///   * `features/quests/presentation/quests_controller.dart`
final dayFinalizedTickProvider = StateProvider<int>((ref) => 0);

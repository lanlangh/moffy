/// 競合解決ロジック（S8 / ARCHITECTURE §1-5）。純粋関数=単体テスト対象。
///
/// S8 競合解決ルール:
///   1. オフライン中は端末で暫定計算しUI即時反映（楽観的更新）。
///   2. 復帰時、端末の未確定生データを送信し、サーバーが日付ごとに確定計算して正とする。
///   3. 同一日が食い違う場合、サーバーの確定値を採用（上書き）。
///      **ただし確定済みポイントを減らす方向の上書きはしない**（ユーザー保護 / 増える方向のみ）。
///   4. 通貨の消費はサーバーで原子的に処理し、オフライン中の消費は許可しない（二重消費防止）。
library;

import 'sync_models.dart';

/// あるカウンタ（pt/成長pt等）の「ローカル暫定値」と「サーバー確定値」の解決結果。
class PointResolution {
  /// 採用する最終値（UIキャッシュへ反映する値）。
  final int resolvedValue;

  /// サーバー値が小さく、減算を抑止した（=サーバーの減少をユーザー保護で無視した）か。
  /// true のときは差分をログのみに記録する（S8: 減る差分はログ）。
  final bool suppressedDecrease;

  const PointResolution({
    required this.resolvedValue,
    required this.suppressedDecrease,
  });
}

abstract final class ConflictResolver {
  /// 確定ポイント系（pt残高・卵成長pt）の競合解決（S8 ルール3）。
  ///
  /// サーバーが SSOT だが「確定値を減らす上書きはしない」。
  ///   * server >= local → server を採用（増加方向の反映）。
  ///   * server <  local → local を維持し、減少は抑止（[suppressedDecrease]=true）。
  ///
  /// これにより「オンライン復帰でポイントが減った」というユーザー不信を防ぐ。
  static PointResolution resolveConfirmedPoints({
    required int localValue,
    required int serverValue,
  }) {
    if (serverValue >= localValue) {
      return PointResolution(
        resolvedValue: serverValue,
        suppressedDecrease: false,
      );
    }
    // サーバーの方が小さい → 減算上書きしない（ローカル維持・差分はログ）。
    return PointResolution(
      resolvedValue: localValue,
      suppressedDecrease: true,
    );
  }

  /// 通貨残高（ジェム/消費対象pt）の解決（S8 ルール4）。
  ///
  /// 通貨は「サーバーが原子的に処理」する真の値。表示は常にサーバー値を採用する
  /// （消費系はオフラインで動かさないため、ローカルが先行することはない）。
  static int resolveCurrencyBalance({required int serverValue}) {
    return serverValue;
  }

  /// この操作をオフライン中にキューへ積んでよいか（S8 ルール4）。
  ///
  /// 通貨消費は二重消費防止のためオフライン不可。生データ提出・孵化要求・受取要求は
  /// 冪等RPCなので積める（復帰時に順次実行 / ARCHITECTURE §1-5）。
  static bool canEnqueueOffline(SyncOpType type) {
    return !type.isCurrencySpend;
  }

  /// 同一日の利用生データ競合の解決（S8 ルール2/3）。
  ///
  /// 生データは端末がSSOTだが、サーバーが「確定（is_finalized）」した日は確定値が正。
  ///   * サーバー未確定 → 端末の生データ（送信予定）を採用。
  ///   * サーバー確定済み → サーバー値を採用（端末からの再送で確定日を上書きしない）。
  static int resolveDailyUsageMinutes({
    required int localMinutes,
    required int serverMinutes,
    required bool serverFinalized,
  }) {
    return serverFinalized ? serverMinutes : localMinutes;
  }
}

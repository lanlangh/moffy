/// 同期エンジンのドメインモデル（ARCHITECTURE §1-5 / S8）。
///
/// SSOTの原則（S8 / ARCHITECTURE §0-1）:
///   * 利用時間の生データ = 端末（Drift）が SSOT。
///   * ポイント確定・卵成長・図鑑・通貨残高 = サーバー（Supabase）が SSOT。
///
/// オフライン中はローカル操作を [SyncOperation] として [SyncQueue] に積むだけで実行はしない。
/// オンライン復帰時に [SyncService] がサーバーへ反映し、[ConflictResolver] で競合解決する。
library;

/// 同期操作の種別（sync_queue に積むローカル操作 / ARCHITECTURE §1-1 tables）。
enum SyncOpType {
  /// 端末で取得した日次利用の生データ提出（insert/未確定update）。
  /// これは「生データSSOT=端末」をサーバーへ送る操作で、オフライン中も積める。
  submitUsageDaily,

  /// 孵化確定要求（サーバー fn_hatch_egg）。オンライン確定が原則（S8）。
  hatchEgg,

  /// クエスト報酬の受取要求（サーバー fn_grant_quest_reward）。残高操作。
  grantQuestReward,

  /// 通貨消費（ジェム/ポイント使用）。**オフライン不可**（S8: 二重消費防止）。
  spendCurrency;

  String get wire => name;

  /// この操作が通貨残高を増減させる「消費系」か。
  /// 消費系はオフライン中はキューに積めない（[SyncQueue] が拒否 / S8）。
  bool get isCurrencySpend => this == SyncOpType.spendCurrency;
}

/// キューに積む1操作（冪等キー付き）。
///
/// サーバーRPCは冪等（idempotency_key）なので、復帰時に二重送信されても安全。
/// [idempotencyKey] は「日付×source」「egg×日」等、操作の一意性を表す（ARCHITECTURE §3）。
class SyncOperation {
  final String id; // ローカル一意ID（再送追跡用）
  final SyncOpType type;

  /// RPC/insert に渡すペイロード（jsonb 相当）。
  final Map<String, Object?> payload;

  /// サーバー側の二重実行防止キー（必須 / 冪等性の核 / ARCHITECTURE §3）。
  final String idempotencyKey;

  /// キュー投入時刻（順序保証・古い操作の整理に使う）。
  final DateTime enqueuedAt;

  /// 送信試行回数（バックオフ・恒久失敗の判定に使う）。
  final int attempts;

  const SyncOperation({
    required this.id,
    required this.type,
    required this.payload,
    required this.idempotencyKey,
    required this.enqueuedAt,
    this.attempts = 0,
  });

  SyncOperation copyWith({int? attempts}) => SyncOperation(
        id: id,
        type: type,
        payload: payload,
        idempotencyKey: idempotencyKey,
        enqueuedAt: enqueuedAt,
        attempts: attempts ?? this.attempts,
      );
}

/// 同期結果の集計（復帰時の一括処理の戻り値）。
class SyncOutcome {
  /// 成功して送信済み（キューから除去された）操作数。
  final int succeeded;

  /// 一時失敗で再試行待ち（キューに残した）操作数。
  final int retryable;

  /// 拒否（オフライン消費系など）でキューに積まれなかった操作数。
  final int rejected;

  const SyncOutcome({
    this.succeeded = 0,
    this.retryable = 0,
    this.rejected = 0,
  });

  bool get isClean => retryable == 0 && rejected == 0;
}

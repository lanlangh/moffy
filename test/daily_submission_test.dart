import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:moffy/app.dart';
import 'package:moffy/core/router/app_router.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/core/sync/daily_submission.dart';
import 'package:moffy/core/sync/day_finalized_tick.dart';
import 'package:moffy/core/sync/finalize_models.dart';
import 'package:moffy/core/sync/usage_sync_repository.dart';
import 'package:moffy/core/usage/usage_models.dart';
import 'package:moffy/core/usage/usage_provider.dart';
import 'package:moffy/core/usage/usage_providers.dart';

/// 「削減 → usage_daily 提出 → サーバー確定」の**配線**を守る回帰テスト。
///
/// 背景（2026-07-16 に発見したバグ / iOS・Android 共通）:
///   `SyncService.enqueueUsageSubmission` も `UsageDailyDraft.fromDailyUsage` も
///   `submitAndFinalize` も**すべて正しく実装されていた**が、**呼び出し元が1つも
///   存在しなかった**。そのため usage_daily は永久に提出されず、確定RPCは到達不能で、
///   削減ptが一切確定しなかった（コアループの死）。最初の7日はウォームアップ付与
///   （fn_claim_warmup）が働くため**正常に見え**、実機テストをすり抜けた。
///
/// なぜ既存テストで防げなかったか:
///   `rpc_parsing_test` / `sync_conflict_test` は対象の関数を**テストから直接呼ぶ**ため、
///   「関数は正しいが誰も呼ばない」型のバグを構造的に検出できない。
///   よって本テストは個々の関数ではなく **提出が実際に発生すること**を検証し、さらに
///   **実際の `MoffyApp` を pump して app.dart の配線ごと**守る（Codex 指摘 #5）。
void main() {
  // サーバーが「確定すべき日」として返す日。端末の「昨日」とは意図的に無関係な日にして、
  // 端末時計に依存していないことを検証する（Codex 指摘 #1a）。
  final serverTarget = DateTime(2026, 7, 10);

  ProviderContainer containerWith(
    _FakeUsageProvider usage,
    _FakeUsageSyncRepository repo, {
    bool online = true,
  }) {
    final container = ProviderContainer(
      overrides: _overrides(usage, repo, online: online),
    );
    addTearDown(container.dispose);
    return container;
  }

  test('提出対象日はサーバーが決める（端末時計の「昨日」を使わない / S4・#1a）', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);
    final container = containerWith(usage, repo);

    await container.read(dailySubmissionServiceProvider).submitPendingDay();

    // 提出が「実際に起きる」こと（＝配線が生きていること）。
    expect(repo.submitted, hasLength(1));
    // サーバーが指した日そのものを提出していること。端末時計由来の日付ではない。
    expect(repo.submitted.single.dateKey, '2026-07-10');
    expect(usage.fetchedDates, contains(serverTarget));
  });

  test('サーバーが確定済みと言えば何もしない（無駄な往復とOS取得を省く）', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(
      targetDate: serverTarget,
      alreadyFinalized: true,
    );
    final container = containerWith(usage, repo);

    await container.read(dailySubmissionServiceProvider).submitPendingDay();

    expect(repo.submitted, isEmpty);
  });

  test('確定済みになるまで、復帰のたびに再試行する', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);
    final container = containerWith(usage, repo);
    final service = container.read(dailySubmissionServiceProvider);

    await service.submitPendingDay(); // 提出 → サーバーが確定済みになる
    await service.submitPendingDay(); // 2回目は already_finalized で何もしない

    expect(repo.submitted, hasLength(1));
  });

  test('送信に失敗した日は確定済みにならず、次の呼び出しで再試行する（S8）', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(
      targetDate: serverTarget,
      throwOnce: true,
    );
    final container = containerWith(usage, repo);
    final service = container.read(dailySubmissionServiceProvider);

    await service.submitPendingDay(); // 1回目: 送信失敗（確定しない）
    await service.submitPendingDay(); // 2回目: 再試行して確定

    expect(repo.submitted.map((d) => d.dateKey), ['2026-07-10', '2026-07-10']);
  });

  test('同時に呼ばれても1回しか提出しない（single-flight / #3）', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);
    final container = containerWith(usage, repo);
    final service = container.read(dailySubmissionServiceProvider);

    await Future.wait([service.submitPendingDay(), service.submitPendingDay()]);

    expect(repo.submitted, hasLength(1));
  });

  test('実DBが無い（モック）なら提出しない', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget, pendingNull: true);
    final container = containerWith(usage, repo);

    await container.read(dailySubmissionServiceProvider).submitPendingDay();

    expect(repo.submitted, isEmpty);
  });

  test('利用統計の権限が無ければ提出しない（体験を止めない / §5-1）', () async {
    final usage = _FakeUsageProvider(permission: UsagePermissionStatus.denied);
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);
    final container = containerWith(usage, repo);

    await container.read(dailySubmissionServiceProvider).submitPendingDay();

    expect(repo.submitted, isEmpty);
  });

  test('オフラインでは提出しない（復帰エッジで再試行する / S8）', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);
    final container = containerWith(usage, repo, online: false);

    await container.read(dailySubmissionServiceProvider).submitPendingDay();

    expect(repo.submitted, isEmpty);
  });

  test('確定に成功したら画面へ再取得の合図を出す', () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);
    final container = containerWith(usage, repo);

    expect(container.read(dayFinalizedTickProvider), 0);
    await container.read(dailySubmissionServiceProvider).submitPendingDay();
    // 合図の発火元は SyncService（確定RPCの戻り値を知る唯一の場所）。
    // ここが 0 なら sync_service.dart の tick++ が消えている。
    expect(container.read(dayFinalizedTickProvider), 1);
  });

  test('確定判定のためにサーバーへ再照会しない（日跨ぎで別日を誤判定する / #5B）',
      () async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);
    final container = containerWith(usage, repo);

    await container.read(dailySubmissionServiceProvider).submitPendingDay();

    // 対象日の問い合わせは「提出前の1回」だけ。送信後にもう一度
    // pendingFinalizeDate() を呼ぶと、23:59 に日を跨いだ場合その答えは**翌日**に
    // ついてのものになり、対象日の確定を見逃す／別日の確定を今回の成功と誤認する。
    // 確定の可否は submitAndFinalize の戻り値（サーバーの確定結果）が唯一の正本。
    expect(repo.pendingCalls, 1);
    expect(container.read(dayFinalizedTickProvider), 1);
  });

  // ---------------------------------------------------------------------------
  // ここから下が「誰も呼ばない」再発を実際に防ぐテスト（Codex #5 / #2）。
  // ProviderContainer から直接 read せず、**実際の MoffyApp を pump** する。
  // app.dart から配線を消すと落ちる。
  // ---------------------------------------------------------------------------

  testWidgets('MoffyApp を起動すると前日分の提出が駆動される（app.dart の配線を守る / #5）',
      (tester) async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(usage, repo),
        child: const MoffyApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      repo.submitted,
      hasLength(1),
      reason: 'app.dart が dailySubmissionProvider を watch していない',
    );
  });

  testWidgets('日を跨いでフォアグラウンド復帰すると次の日の分を提出する（#2）',
      (tester) async {
    final usage = _FakeUsageProvider();
    final repo = _FakeUsageSyncRepository(targetDate: serverTarget);

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(usage, repo),
        child: const MoffyApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(repo.submitted, hasLength(1));

    // プロセスが生きたまま日を跨いだ状況（サーバーの対象日が翌日へ進む）。
    repo.targetDate = DateTime(2026, 7, 11);
    repo.alreadyFinalized = false;

    // バックグラウンド → フォアグラウンド復帰。
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 50));

    // Provider の本体は再実行されないため、復帰トリガーが無いとここで 1 のまま落ちる。
    expect(
      repo.submitted.map((d) => d.dateKey),
      ['2026-07-10', '2026-07-11'],
      reason: 'app.dart の didChangeAppLifecycleState 経由の再駆動が無い',
    );
  });
}

/// テスト用の差し替え一式（ProviderContainer / ProviderScope 共通）。
List<Override> _overrides(
  _FakeUsageProvider usage,
  _FakeUsageSyncRepository repo, {
  bool online = true,
}) =>
    [
      // Env.useSupabase はコンパイル時定数のため、判定をプロバイダ経由にして差し替える。
      usageSubmissionEnabledProvider.overrideWithValue(true),
      isOnlineProvider.overrideWithValue(online),
      usageProviderProvider.overrideWithValue(usage),
      usageSyncRepositoryProvider.overrideWithValue(repo),
      // 実ルーター（オンボ判定・全タブ構築）を持ち込まない最小ルート。
      appRouterProvider.overrideWithValue(
        GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
          ],
        ),
      ),
    ];

/// OS 利用統計の差し替え。提出対象日を記録する。
class _FakeUsageProvider implements UsageProvider {
  _FakeUsageProvider({this.permission = UsagePermissionStatus.granted});

  final UsagePermissionStatus permission;
  final List<DateTime> fetchedDates = [];

  @override
  UsageMode get mode => UsageMode.exactMinutes;

  @override
  Future<UsagePermissionStatus> checkPermission() async => permission;

  @override
  Future<UsagePermissionStatus> requestPermission() async => permission;

  @override
  Future<DailyUsage> fetchDailyUsage({
    required DateTime date,
    required List<String> targetPackages,
  }) async {
    fetchedDates.add(DateTime(date.year, date.month, date.day));
    return DailyUsage.fromPerApp(
      date: date,
      perAppMinutes: const {'com.instagram.android': 40},
      mode: UsageMode.exactMinutes,
    );
  }

  @override
  Future<List<DailyUsage>> fetchUsageRange({
    required DateTime startDate,
    required DateTime endDate,
    required List<String> targetPackages,
  }) async =>
      const [];
}

/// サーバー側の状態（対象日・確定済みフラグ）を模した差し替え。
/// 実DBもRPCも使わない（確定計算はサーバーの責務なのでテスト対象外）。
class _FakeUsageSyncRepository implements UsageSyncRepository {
  _FakeUsageSyncRepository({
    required this.targetDate,
    this.alreadyFinalized = false,
    this.pendingNull = false,
    this.throwOnce = false,
  });

  DateTime targetDate;
  bool alreadyFinalized;
  final bool pendingNull;
  final bool throwOnce;
  final List<UsageDailyDraft> submitted = [];

  /// 対象日の照会回数（#5B: 送信後の再照会をしていないことの検証用）。
  int pendingCalls = 0;
  bool _thrown = false;

  @override
  Future<PendingFinalizeDate?> pendingFinalizeDate() async {
    pendingCalls++;
    if (pendingNull) return null;
    return PendingFinalizeDate(
      targetDate: targetDate,
      serverToday: targetDate.add(const Duration(days: 1)),
      alreadyFinalized: alreadyFinalized,
      hasUsageRow: false,
    );
  }

  @override
  Future<FinalizeDayResult> submitAndFinalize(UsageDailyDraft draft) async {
    submitted.add(draft);
    if (throwOnce && !_thrown) {
      _thrown = true;
      throw Exception('transient network failure');
    }
    alreadyFinalized = true; // サーバーが確定した。
    return const FinalizeDayResult(finalized: true, pointsAwarded: 120);
  }
}

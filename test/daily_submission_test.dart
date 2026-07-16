import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/core/sync/daily_submission.dart';
import 'package:moffy/core/sync/finalize_models.dart';
import 'package:moffy/core/sync/usage_sync_repository.dart';
import 'package:moffy/core/usage/usage_models.dart';
import 'package:moffy/core/usage/usage_provider.dart';
import 'package:moffy/core/usage/usage_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「削減 → usage_daily 提出 → fn_finalize_day 確定」の**配線**を守る回帰テスト。
///
/// 背景（2026-07-16 に発見したバグ / iOS・Android 共通）:
///   `SyncService.enqueueUsageSubmission` も `UsageDailyDraft.fromDailyUsage` も
///   `SupabaseUsageSyncRepository.submitAndFinalize` も**すべて正しく実装されていた**が、
///   **呼び出し元が1つも存在しなかった**。そのため usage_daily は永久に提出されず、
///   `fn_finalize_day` は到達不能で、削減ptが一切確定しなかった（コアループの死）。
///   最初の7日はウォームアップ付与（`fn_claim_warmup`）が働くため**正常に見え**、
///   実機テストをすり抜けた。
///
/// なぜ既存テストで防げなかったか:
///   `rpc_parsing_test` / `sync_conflict_test` は対象の関数を**テストから直接呼ぶ**ため、
///   「関数は正しいが誰も呼ばない」型のバグを構造的に検出できない。
///   よって本テストは個々の関数ではなく **提出が実際に発生すること**を検証する。
void main() {
  setUp(() {
    // 「提出済みの暦日」フラグ（shared_preferences）を毎回まっさらにする。
    SharedPreferences.setMockInitialValues({});
  });

  ProviderContainer containerWith(
    _FakeUsageProvider usage,
    _RecordingUsageSyncRepository repo, {
    bool online = true,
  }) {
    final container = ProviderContainer(
      overrides: [
        // Env.useSupabase はコンパイル時定数のため、判定をプロバイダ経由にして差し替える。
        usageSubmissionEnabledProvider.overrideWithValue(true),
        isOnlineProvider.overrideWithValue(online),
        usageProviderProvider.overrideWithValue(usage),
        usageSyncRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('提出対象は「昨日」であって当日ではない（PRD §S4-2: 翌日に確定）', () async {
    final usage = _FakeUsageProvider();
    final repo = _RecordingUsageSyncRepository();
    final container = containerWith(usage, repo);

    await container
        .read(dailySubmissionServiceProvider)
        .submitYesterdayIfNeeded(now: DateTime(2026, 7, 16, 9, 30));

    // 提出が「実際に起きる」こと（＝配線が生きていること）。
    expect(repo.submitted, hasLength(1));
    // 当日(07-16)を確定すると is_finalized と冪等キーでその日が締まり、以降の利用が
    // 反映されない（＝朝に満額確定できてしまう）。対象は必ず終了した日＝昨日。
    expect(repo.submitted.single.dateKey, '2026-07-15');
    expect(usage.fetchedDates, contains(DateTime(2026, 7, 15)));
    expect(usage.fetchedDates, isNot(contains(DateTime(2026, 7, 16))));
  });

  test('同じ日は二度提出しない（確定済み行は RLS で更新不可 → 無限リトライ防止 / S8）',
      () async {
    final usage = _FakeUsageProvider();
    final repo = _RecordingUsageSyncRepository();
    final container = containerWith(usage, repo);
    final service = container.read(dailySubmissionServiceProvider);
    final now = DateTime(2026, 7, 16, 9, 30);

    await service.submitYesterdayIfNeeded(now: now);
    await service.submitYesterdayIfNeeded(now: now);

    expect(repo.submitted, hasLength(1));
  });

  test('日付が変われば次の日の分を提出する', () async {
    final usage = _FakeUsageProvider();
    final repo = _RecordingUsageSyncRepository();
    final container = containerWith(usage, repo);
    final service = container.read(dailySubmissionServiceProvider);

    await service.submitYesterdayIfNeeded(now: DateTime(2026, 7, 16, 9, 30));
    await service.submitYesterdayIfNeeded(now: DateTime(2026, 7, 17, 8, 0));

    expect(repo.submitted.map((d) => d.dateKey), ['2026-07-15', '2026-07-16']);
  });

  test('利用統計の権限が無ければ提出しない（体験を止めない / §5-1）', () async {
    final usage = _FakeUsageProvider(permission: UsagePermissionStatus.denied);
    final repo = _RecordingUsageSyncRepository();
    final container = containerWith(usage, repo);

    await container
        .read(dailySubmissionServiceProvider)
        .submitYesterdayIfNeeded(now: DateTime(2026, 7, 16));

    expect(repo.submitted, isEmpty);
  });

  test('オフラインでは提出しない（復帰エッジで再試行する / S8）', () async {
    final usage = _FakeUsageProvider();
    final repo = _RecordingUsageSyncRepository();
    final container = containerWith(usage, repo, online: false);

    await container
        .read(dailySubmissionServiceProvider)
        .submitYesterdayIfNeeded(now: DateTime(2026, 7, 16));

    expect(repo.submitted, isEmpty);
  });

  test('送信に失敗した日は「提出済み」にせず次回再試行する（S8）', () async {
    final usage = _FakeUsageProvider();
    final repo = _RecordingUsageSyncRepository(throwOnce: true);
    final container = containerWith(usage, repo);
    final service = container.read(dailySubmissionServiceProvider);
    final now = DateTime(2026, 7, 16, 9, 30);

    await service.submitYesterdayIfNeeded(now: now); // 1回目: 失敗
    await service.submitYesterdayIfNeeded(now: now); // 2回目: 再試行して成功

    expect(repo.submitted.map((d) => d.dateKey), ['2026-07-15', '2026-07-15']);
  });

  test('dailySubmissionProvider を常駐させると提出が駆動される（app.dart の配線）', () async {
    final usage = _FakeUsageProvider();
    final repo = _RecordingUsageSyncRepository();
    final container = containerWith(usage, repo);

    // app.dart が ref.watch(dailySubmissionProvider) するのと同じ経路。
    container.read(dailySubmissionProvider);
    // プロバイダ本体は fire-and-forget で起動するため、マイクロタスクを流す。
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(repo.submitted, hasLength(1));
  });
}

/// OS 利用統計の差し替え。提出対象日を記録して「当日を送っていないか」を検証する。
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

/// 提出されたドラフトを記録する。実DBもRPCも使わない（サーバー責務は対象外）。
class _RecordingUsageSyncRepository implements UsageSyncRepository {
  _RecordingUsageSyncRepository({this.throwOnce = false});

  final bool throwOnce;
  final List<UsageDailyDraft> submitted = [];
  bool _thrown = false;

  @override
  Future<FinalizeDayResult> submitAndFinalize(UsageDailyDraft draft) async {
    submitted.add(draft);
    if (throwOnce && !_thrown) {
      _thrown = true;
      throw Exception('transient network failure');
    }
    return const FinalizeDayResult(finalized: true, pointsAwarded: 120);
  }
}

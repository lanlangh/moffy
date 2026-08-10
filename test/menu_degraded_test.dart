import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/constants/economy.dart';
import 'package:moffy/core/constants/remote_config.dart';
import 'package:moffy/core/iap/iap_providers.dart';
import 'package:moffy/core/sync/connectivity_provider.dart';
import 'package:moffy/core/widgets/state_views.dart';
import 'package:moffy/features/menu/presentation/menu_screen.dart';
import 'package:moffy/features/profile/data/profile_repository.dart';
import 'package:moffy/features/profile/domain/profile_models.dart';

/// メニュー画面の「統計が取れなくても画面は生きている」ことを守る回帰テスト。
///
/// 背景（2026-08-07 / v1.1 の順1 で作り込んだ退行を第三者レビューが検出）:
///   統計をサーバー集計 RPC に置き換えた際、`SupabaseProfileRepository` が
///   オフラインと RPC 失敗で **throw** していた。`MenuScreen` は
///   `async.when(error: → ErrorView)` で body 全体を差し替えるため、統計が取れない
///   だけで以下がまとめて画面から消えた:
///     * アカウント削除（S12 / **ストア審査の必須導線**）
///     * プライバシーポリシー / 利用規約 / 特定商取引法に基づく表記
///     * お問い合わせ / プレミアム
///   ＝「オフラインだと退会できないアプリ」。App Store 5.1.1(v) / Play のデータ削除
///   要件に直撃する。
///
/// なぜ既存テストで防げなかったか:
///   リポジトリ単体のテストは「throw すること」を正常系として通してしまう。
///   画面まで pump して**何が消えるか**を見ないと、この型の退行は捕まらない
///   （daily_submission_test.dart と同じ思想: 部品ではなく配線を守る）。
void main() {
  Widget harness({required ProfileState state}) {
    return ProviderScope(
      overrides: [
        // 経済パラメータは実 DB を見に行かせない（図鑑の分母だけ使う）。
        economyParamsProvider.overrideWith((ref) async => EconomyParams.defaults),
        isPremiumProvider.overrideWithValue(false),
        isOnlineProvider.overrideWithValue(!state.isOffline),
        profileRepositoryProvider
            .overrideWithValue(_FakeProfileRepository(state)),
      ],
      child: const MaterialApp(home: MenuScreen()),
    );
  }

  /// 審査必須導線を含む「統計と無関係に常に出ていなければならないもの」。
  void expectEssentialsVisible() {
    expect(find.text('アカウント削除'), findsOneWidget, reason: 'S12 審査必須導線');
    expect(find.text('プライバシーポリシー'), findsOneWidget);
    expect(find.text('利用規約'), findsOneWidget);
    expect(find.text('特定商取引法に基づく表記'), findsOneWidget);
    expect(find.text('お問い合わせ'), findsOneWidget);
    // 画面全体がエラー表示に差し替わっていないこと（退行の直接の形）。
    expect(find.byType(ErrorView), findsNothing);
  }

  testWidgets('オフラインでも退会・法務リンクに到達できる（統計だけが縮退する）',
      (tester) async {
    await tester.pumpWidget(
      harness(
        state: const ProfileState(
          stats: null,
          account: AccountState(isAnonymous: true, linkedProviders: []),
          isOffline: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expectEssentialsVisible();
    // 統計は 0 埋めせず、取得できなかったと正直に出す。
    expect(find.textContaining('統計を表示できませんでした'), findsOneWidget);
    // 実績のあるユーザーに「まだ何も無い」と嘘をつかないこと（isFresh の誤発火）。
    expect(find.text('これから記録を集めていきましょう。'), findsNothing);
    // 5状態契約: オフラインは上端バーで示す。
    expect(find.byType(OfflineBar), findsOneWidget);
  });

  testWidgets('オンラインでも統計 RPC が失敗したら画面は生かして縮退する',
      (tester) async {
    // 0014 未適用（PGRST202）や権限欠落を想定＝統計だけ null、接続はある。
    await tester.pumpWidget(
      harness(
        state: const ProfileState(
          stats: null,
          account: AccountState(isAnonymous: true, linkedProviders: []),
          isOffline: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expectEssentialsVisible();
    expect(find.textContaining('統計を表示できませんでした'), findsOneWidget);
    expect(find.byType(OfflineBar), findsNothing);
  });

  testWidgets('統計が取れたときは5指標を出す（縮退カードは出さない）', (tester) async {
    await tester.pumpWidget(
      harness(
        state: const ProfileState(
          stats: ProfileStats(
            totalReducedMinutes: 90,
            totalMofi: 2,
            dexDiscovered: 1,
            dexTotal: 40,
            longestStreak: 3,
            totalPoints: 530,
          ),
          account: AccountState(isAnonymous: true, linkedProviders: []),
          isOffline: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expectEssentialsVisible();
    expect(find.textContaining('統計を表示できませんでした'), findsNothing);
    expect(find.text('1時間30分'), findsOneWidget);
    expect(find.text('1/40'), findsOneWidget);
    expect(find.text('530'), findsOneWidget);
    // 実績があるので「これから集めよう」は出さない。
    expect(find.text('これから記録を集めていきましょう。'), findsNothing);
  });

  testWidgets('通知は未実装なので設定導線を出さず、正直に案内する（2.1 App Completeness）',
      (tester) async {
    await tester.pumpWidget(
      harness(
        state: const ProfileState(
          stats: null,
          account: AccountState(isAnonymous: true, linkedProviders: []),
          isOffline: false,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 送信側が1行も無い状態でトグルだけ触れる画面には入れないこと。
    expect(find.text('通知設定'), findsNothing);
    expect(find.text('5種類の通知を個別にON/OFF'), findsNothing);
    expect(find.text('通知は今後のアップデートで'), findsOneWidget);
  });
}

/// 画面の分岐だけを見たいので、リポジトリは固定の状態を返すだけにする。
class _FakeProfileRepository implements ProfileRepository {
  _FakeProfileRepository(this._state);
  final ProfileState _state;

  @override
  Future<ProfileState> loadProfile({required int dexTotalEntries}) async =>
      _state;
}

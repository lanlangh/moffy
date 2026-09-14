import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/error/failure.dart';
import 'package:moffy/core/observability/crash_reporter.dart';
import 'package:moffy/core/observability/error_severity.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException, PostgrestException;

/// Sentry へ送る重さの判定（2026-09-14）。
///
/// 1.2.1 を Play に送った直後、Google の自動テスト端末から「受け止めて処理済み」の
/// 失敗が error で2件届き、オーナーに高優先メールが飛んだ。一時的な通信の失敗だけを
/// warning（Sentry の優先度「中」＝1件ずつは通知しない）に落とす判定を縛る。
/// **不具合の兆候まで warning に落としていないか**を特に確かめる。
void main() {
  group('一時的な通信の失敗 → warning', () {
    test('RevenueCat の NETWORK_ERROR（今回の1件目 / code 10）', () {
      final e = PlatformException(
        code: '10',
        message: 'Error performing request.',
        details: {'readableErrorCode': 'NetworkError'},
      );
      expect(isTransientFailure(e), isTrue);
      expect(crashLevelFor(e), CrashLevel.warning);
    });

    test('Supabase の 504 Gateway Timeout（今回の2件目）', () {
      const e = PostgrestException(
        message: 'Gateway Timeout',
        code: '504',
        details: 'Gateway Timeout',
      );
      expect(isTransientFailure(e), isTrue);
      expect(crashLevelFor(e), CrashLevel.warning);
    });

    test('Supabase の 502 / 503 も同じ扱い', () {
      for (final code in ['502', '503']) {
        expect(
          isTransientFailure(PostgrestException(message: 'x', code: code)),
          isTrue,
          reason: code,
        );
      }
    });

    test('Supabase Auth が再試行可能と明示した通信エラー', () {
      expect(isTransientFailure(AuthRetryableFetchException()), isTrue);
    });

    test('タイムアウト', () {
      expect(isTransientFailure(TimeoutException('slow')), isTrue);
    });

    test('端末側の通信断（SocketException）', () {
      expect(isTransientFailure(const SocketException('no route')), isTrue);
    });
  });

  group('不具合の兆候 → error のまま（通知を止めてはいけない）', () {
    test('RevenueCat の STORE_PROBLEM（code 2）は通信の失敗ではない', () {
      final e = PlatformException(code: '2');
      expect(isTransientFailure(e), isFalse);
      expect(crashLevelFor(e), CrashLevel.error);
    });

    test('RevenueCat の設定ミス（invalidCredentialsError / code 11）', () {
      expect(isTransientFailure(PlatformException(code: '11')), isFalse);
    });

    test('権限不足（42501）＝マイグレーションの権限漏れの兆候', () {
      expect(
        isTransientFailure(
          const PostgrestException(message: 'permission denied', code: '42501'),
        ),
        isFalse,
      );
    });

    test('RPC が無い（PGRST202）＝マイグレーション未適用の兆候', () {
      expect(
        isTransientFailure(
          const PostgrestException(message: 'not found', code: 'PGRST202'),
        ),
        isFalse,
      );
    });

    test('code が無い PostgrestException', () {
      expect(
        isTransientFailure(const PostgrestException(message: 'x')),
        isFalse,
      );
    });

    test('ただの例外と、Log.e が error 無しで渡す文字列', () {
      expect(isTransientFailure(Exception('boom')), isFalse);
      expect(isTransientFailure('fn_profile_stats returned non-map'), isFalse);
      expect(crashLevelFor('x'), CrashLevel.error);
    });
  });

  test('数字でない code の PlatformException で落ちない（他プラグインの例外）', () {
    // PurchasesErrorHelper.getErrorCode は code を num.parse するので、
    // ガードが無いとここで FormatException を投げて Sentry 送信ごと止まる。
    final e = PlatformException(code: 'sign_in_failed');
    expect(() => isTransientFailure(e), returnsNormally);
    expect(isTransientFailure(e), isFalse);
  });

  // 1.2.1+29 で「Instance of 'ServerFailure'」が高優先で届いた件。
  // データ層が元の例外を送ってから ServerFailure に包み直し、上位がそれをまた送っていた。
  group('包み直された Failure', () {
    test('元の例外で重さを判定する（504 を包んだものは warning）', () {
      const root = PostgrestException(message: 'Gateway Timeout', code: '504');
      expect(
        crashLevelFor(const ServerFailure('サーバーで確定に失敗しました', root)),
        CrashLevel.warning,
      );
    });

    test('元の例外が不具合の兆候なら error のまま', () {
      const root = PostgrestException(message: 'profile_not_found', code: 'P0002');
      expect(crashLevelFor(const ServerFailure('x', root)), CrashLevel.error);
    });

    test('元の例外が無い Failure（形式不正など）は error', () {
      expect(
        crashLevelFor(const ServerFailure('対象日の取得結果の形式が不正です')),
        CrashLevel.error,
      );
    });

    test('NetworkFailure は一時的な失敗', () {
      expect(crashLevelFor(const NetworkFailure()), CrashLevel.warning);
    });

    test('件名に種類と文言が出る（「Instance of ...」にならない）', () {
      const root = PostgrestException(message: 'x', code: '504');
      final s = const ServerFailure('サーバーで確定に失敗しました', root).toString();
      expect(s, isNot(contains('Instance of')));
      expect(s, contains('ServerFailure'));
      expect(s, contains('サーバーで確定に失敗しました'));
      expect(s, contains('PostgrestException'));
    });
  });

  // 送り済みの印は「同じ参照」に付く。const は同じ値なら同じ参照になるので、
  // テストごとに message を変えて、別のテストで付けた印が混ざらないようにしている。
  group('二重送信の防止（shouldReport / markReported）', () {
    test('元の例外を送った後の包み直しは送らない（今回の件）', () {
      const root = PostgrestException(message: 'dedupe-sent', code: '500');
      // データ層: Log.e(root) → 送信
      expect(shouldReport(root), isTrue);
      markReported(root);
      // 上位: catch した ServerFailure を Log.e → 2回目は捨てる
      expect(shouldReport(const ServerFailure('x', root)), isFalse);
    });

    test('元の例外がまだ送られていなければ、包み直しを送る（取りこぼさない）', () {
      const root = PostgrestException(message: 'dedupe-not-sent', code: '500');
      expect(shouldReport(const ServerFailure('x', root)), isTrue);
    });

    test('元の例外を持たない Failure は送る（形式不正など、データ層で送っていないもの）', () {
      expect(shouldReport(const ServerFailure('形式が不正です')), isTrue);
    });

    test('包みが入れ子でも、いちばん元が送り済みなら送らない', () {
      const root = PostgrestException(message: 'dedupe-nested', code: '500');
      markReported(root);
      expect(
        shouldReport(const UnknownFailure('outer', ServerFailure('inner', root))),
        isFalse,
      );
    });

    test('ふつうの例外は毎回送る（同一インスタンスでない限り重複扱いしない）', () {
      final a = Exception('a');
      markReported(a);
      expect(shouldReport(Exception('b')), isTrue);
    });

    test('Log.e が渡す文字列でも落ちない（Expando に付けられない値）', () {
      expect(
        () => markReported('fn_profile_stats returned non-map'),
        returnsNormally,
      );
      expect(shouldReport('fn_profile_stats returned non-map'), isTrue);
    });
  });
}

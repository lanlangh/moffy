import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
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
      const e = PlatformException(
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
      const e = PlatformException(code: '2');
      expect(isTransientFailure(e), isFalse);
      expect(crashLevelFor(e), CrashLevel.error);
    });

    test('RevenueCat の設定ミス（invalidCredentialsError / code 11）', () {
      expect(isTransientFailure(const PlatformException(code: '11')), isFalse);
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
    const e = PlatformException(code: 'sign_in_failed');
    expect(() => isTransientFailure(e), returnsNormally);
    expect(isTransientFailure(e), isFalse);
  });
}

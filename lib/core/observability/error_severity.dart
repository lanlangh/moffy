/// エラーを Sentry にどの重さで送るかの判定（2026-09-14）。
///
/// なぜ要るか:
///   本番の [Log.e] は Sentry 送信に直結している（main.dart の crashReporterSink）。
///   そのため **アプリが受け止めて処理済みの失敗まで error で届き**、Sentry の既定アラート
///   「high priority issues」でオーナーにメールが飛んでいた。1.2.1 を Play に送った直後、
///   Google の自動テスト端末から2件届いた:
///     * RevenueCat `getOfferings` の NETWORK_ERROR（購入画面は再試行ボタンを出す）
///     * Supabase の 504 Gateway Timeout（メニュー画面は統計カードだけ欠けて出る）
///   どちらも画面は壊れておらず、1件ずつでは打つ手が無い。こういう通知が増えると、
///   本当に危ないクラッシュが埋もれる。
///
/// 方針:
///   * **一時的な通信・基盤の失敗だけ** warning にする。Sentry は warning を優先度「中」に
///     するので1件ずつの通知は来ない。一方で**全員に起きる本物の障害なら急増で自動的に
///     優先度が上がって通知が来る**（docs.sentry.io/product/issues/issue-priority）。
///   * それ以外（RPC が無い / 戻り値の形がおかしい / 課金の設定ミス 等）は error のまま。
///     処理済みでも「全員に静かに起きている不具合」の兆候なので、知らせる価値がある。
///   * 本当のクラッシュ（未捕捉）は SentryFlutter が自前で error/fatal で送るので影響しない。
///
/// log.dart からは import しない（log.dart は Sentry や各 SDK を知らない一方向依存を保つ）。
library;

import 'dart:async' show TimeoutException;

import 'package:flutter/services.dart' show PlatformException;
import 'package:purchases_flutter/purchases_flutter.dart'
    show PurchasesErrorCode, PurchasesErrorHelper;
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthRetryableFetchException, PostgrestException;

import '../error/failure.dart';
import 'crash_reporter.dart';

/// Supabase の入口（API ゲートウェイ）が返す、一時的な失敗の HTTP ステータス。
const Set<String> _gatewayTransientCodes = {'502', '503', '504'};

/// 一時的な通信・基盤の失敗か（＝1件ずつでは行動につながらない）。
bool isTransientFailure(Object error) {
  // 【2026-09-14】包み直された失敗は、**元の例外で**判定する。
  //   1.2.1+29 で「Instance of 'ServerFailure'」が高優先で届いた。データ層が元の例外を
  //   ServerFailure に包んで投げ直していたため、ここでは種類が分からず error に倒れていた。
  if (error is Failure) {
    if (error is NetworkFailure) return true;
    final cause = error.cause;
    return cause != null && isTransientFailure(cause);
  }

  // RevenueCat（Google Play Billing / StoreKit）の通信エラー。
  if (error is PlatformException) {
    // PurchasesErrorHelper.getErrorCode は code を num.parse するので、数字でない code
    // （他プラグインの 'sign_in_failed' 等）を渡すと例外を投げる。先に弾く。
    if (int.tryParse(error.code) == null) return false;
    try {
      return PurchasesErrorHelper.getErrorCode(error) ==
          PurchasesErrorCode.networkError;
    } catch (_) {
      return false;
    }
  }

  // Supabase / PostgREST の入口の一時的な失敗（今回の 504）。
  // 42501（権限）や PGRST202（RPC が無い）などは不具合の兆候なので対象外。
  if (error is PostgrestException) {
    return _gatewayTransientCodes.contains(error.code);
  }

  // Supabase Auth が「再試行してよい」と明示している通信エラー。
  if (error is AuthRetryableFetchException) return true;

  if (error is TimeoutException) return true;

  // dart:io の SocketException / HandshakeException と package:http の ClientException は
  // 型名で判定する。dart:io を import すると Web プレビューのビルドが壊れ、package:http は
  // 直接の依存ではない（入れると依存が増える）ため。
  final type = error.runtimeType.toString();
  return type == 'SocketException' ||
      type == 'HandshakeException' ||
      type == 'ClientException';
}

/// Sentry へ送るときの重さ。一時的な通信の失敗だけ warning、ほかは error。
CrashLevel crashLevelFor(Object error) =>
    isTransientFailure(error) ? CrashLevel.warning : CrashLevel.error;

/// Sentry へ送り済みの例外に付ける印（同じ失敗の二重送信を防ぐ）。
///
/// [Expando] は対象を参照で掴まないので、例外が不要になれば印ごと回収される
/// （送った例外の一覧を溜め込んでメモリを食う心配が無い）。
final Expando<bool> _reported = Expando<bool>('sentry_reported');

/// [Expando] に印を付けられる値か（文字列・数値・bool・record には付けられない）。
/// [Log.e] は error が無いとメッセージ文字列をそのまま渡してくるので、ここで弾く。
bool _canMark(Object o) => o is! String && o is! num && o is! bool && o is! Record;

/// この error を Sentry に送るべきか。
///
/// データ層は「元の例外を Log.e で送る → [Failure] に包んで投げ直す」をしている。
/// 上位がその Failure をまた Log.e すると**同じ失敗が2回**届く（1.2.1+29 で実際に起きた）。
/// 包みの中の元の例外（[Failure.cause]）が送り済みなら、2回目は捨てる。
/// 元を送らずに包んだ Failure（戻り値の形式不正など）は、ここで初めて送る＝取りこぼさない。
bool shouldReport(Object error) {
  Object? cause = error is Failure ? error.cause : null;
  // 包みが入れ子になっていても辿る。循環に備えて上限を置く。
  for (var depth = 0; cause != null && depth < 5; depth++) {
    if (_canMark(cause) && _reported[cause] == true) return false;
    cause = cause is Failure ? cause.cause : null;
  }
  return true;
}

/// 送ったことを記録する（[shouldReport] が2回目を見分けるため）。
void markReported(Object error) {
  if (_canMark(error)) _reported[error] = true;
}

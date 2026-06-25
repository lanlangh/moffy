/// 行動分析（PostHog ラッパ / ARCHITECTURE §1 observability・PRD §5-5）。
///
/// 役割: PostHog SDK（posthog_flutter）の詳細を隠蔽し、上位（プロバイダ/UI）には
/// 抽象 [Analytics] のみ公開する（lib/core/iap/ の IapService と同じ構成: 抽象+実装+Noop）。
///
/// 信頼境界・PII 原則（OBSERVABILITY_SETUP.md / 厳守）:
///   * 個人情報・利用生データ（usage_daily の分数等）は送らない。
///     プロパティに載せてよいのはカテゴリ値（レアリティ・プラン期間・経路）のみ。
///   * user_id は **匿名ID のみ許容**（メール・氏名は identify に渡さない）。
///   * Project API Key は Env（dart-define）から受ける。未設定なら [NoopAnalytics]。
library;

import 'package:posthog_flutter/posthog_flutter.dart';

import 'analytics_events.dart';
import 'log.dart';

/// 行動分析の抽象。未設定/テスト時は [NoopAnalytics] を注入する。
abstract interface class Analytics {
  /// ファネルイベントを記録する（[AnalyticsEvents] の定数を渡す）。
  ///
  /// [properties] はカテゴリ値のみ（PII/生データ禁止）。失敗しても例外を投げない。
  void capture(String event, {Map<String, Object>? properties});

  /// 匿名ユーザーIDを紐づける（機種変・復元時の同一人物判定）。
  ///
  /// [anonymousUserId] は **匿名ID のみ**（Supabase の user_id 等）。
  /// メール・氏名など個人特定情報は渡さない（信頼境界）。
  void identifyAnonymous(String anonymousUserId);

  /// セッション/識別子をリセットする（ログアウト・アカウント削除時）。
  void reset();
}

/// 何もしない実装（PostHog 未設定 / テスト）。スローしない・送らない。
class NoopAnalytics implements Analytics {
  const NoopAnalytics();

  @override
  void capture(String event, {Map<String, Object>? properties}) {}

  @override
  void identifyAnonymous(String anonymousUserId) {}

  @override
  void reset() {}
}

/// PostHog 実装。
///
/// 初期化（init）は main.dart 側で行う（SDK のセットアップは1度きり）。本クラスは
/// 初期化済みの [Posthog] インスタンスへイベントを委譲する薄いラッパ。
class PostHogAnalytics implements Analytics {
  PostHogAnalytics();

  final Posthog _posthog = Posthog();

  @override
  void capture(String event, {Map<String, Object>? properties}) {
    try {
      // PII 防御の最終ゲート: ここに渡るのはカテゴリ値のみ（呼び出し側で担保）。
      _posthog.capture(eventName: event, properties: properties);
    } catch (e, st) {
      // 計測失敗でアプリ挙動を壊さない（握りつぶさずログのみ / 本番は抑止）。
      Log.e('PostHog capture failed: $event', error: e, stack: st);
    }
  }

  @override
  void identifyAnonymous(String anonymousUserId) {
    try {
      // userProperties は渡さない（匿名IDのみ / PII 非送信）。
      _posthog.identify(userId: anonymousUserId);
    } catch (e, st) {
      Log.e('PostHog identify failed', error: e, stack: st);
    }
  }

  @override
  void reset() {
    try {
      _posthog.reset();
    } catch (e, st) {
      Log.e('PostHog reset failed', error: e, stack: st);
    }
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/observability/log.dart';

/// オンボーディング完了フラグのローカル永続化（SCREEN_FLOWS §0,§1）。
///
/// 初回のみオンボーディングを表示する判定に使う。フラグは端末ローカル
/// （shared_preferences）に持つ（サーバー往復不要・オフラインでも判定可能）。
/// アカウント連携・利用統計の権限はこれとは別軸（権限はOS側が保持）。
abstract interface class OnboardingRepository {
  /// オンボーディングを完了済みか（true=ホームへ直行）。
  Future<bool> isCompleted();

  /// オンボーディング完了を記録する。
  Future<void> markCompleted();
}

class SharedPrefsOnboardingRepository implements OnboardingRepository {
  SharedPrefsOnboardingRepository();

  static const String _key = 'onboarding_completed_v1';

  @override
  Future<bool> isCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (e, st) {
      // 読み取り失敗時はオンボを表示する側に倒す（安全側 / クラッシュさせない）。
      Log.e('onboarding flag read failed', error: e, stack: st);
      return false;
    }
  }

  @override
  Future<void> markCompleted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, true);
    } catch (e, st) {
      Log.e('onboarding flag write failed', error: e, stack: st);
    }
  }
}

final onboardingRepositoryProvider = Provider<OnboardingRepository>((ref) {
  return SharedPrefsOnboardingRepository();
});

/// 初回起動かどうか（true=オンボーディングを表示）。
/// router の redirect が参照し、完了済みならホームへ流す。
final onboardingCompletedProvider = FutureProvider<bool>((ref) async {
  return ref.read(onboardingRepositoryProvider).isCompleted();
});

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/notification_settings.dart';

/// 通知設定の永続化（S9）。ローカル保存（shared_preferences）。
///
/// S9: 通知設定は端末ごとの設定でサーバーに持たない。既定はすべてON。
/// 抽象を切り、テストではインメモリ実装で override 可能にする。
abstract interface class NotificationSettingsRepository {
  Future<NotificationSettings> load();
  Future<void> setEnabled(NotificationKind kind, bool value);
}

/// shared_preferences 実装（本番）。
class PrefsNotificationSettingsRepository
    implements NotificationSettingsRepository {
  @override
  Future<NotificationSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final map = <NotificationKind, bool>{};
    for (final k in NotificationKind.values) {
      // 未設定（初回）は既定ON（S9）。
      map[k] = prefs.getBool(k.prefKey) ?? true;
    }
    return NotificationSettings(map);
  }

  @override
  Future<void> setEnabled(NotificationKind kind, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kind.prefKey, value);
  }
}

/// インメモリ実装（テスト用 / プラグイン非依存）。
class InMemoryNotificationSettingsRepository
    implements NotificationSettingsRepository {
  NotificationSettings _settings = NotificationSettings.defaults();

  @override
  Future<NotificationSettings> load() async => _settings;

  @override
  Future<void> setEnabled(NotificationKind kind, bool value) async {
    _settings = _settings.toggle(kind, value);
  }
}

final notificationSettingsRepositoryProvider =
    Provider<NotificationSettingsRepository>((ref) {
  return PrefsNotificationSettingsRepository();
});

/// 通知設定の状態（設定画面が watch）。
final notificationSettingsProvider =
    FutureProvider<NotificationSettings>((ref) async {
  return ref.read(notificationSettingsRepositoryProvider).load();
});

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/notification_settings_repository.dart';
import '../domain/notification_settings.dart';

/// 通知設定の状態管理（S9 / AsyncNotifier）。
///
/// AsyncValue<NotificationSettings> で loading/error を型で担保。トグルは即ローカル保存し、
/// 楽観的に state を更新する（保存は端末内なので失敗しても致命的でない）。
class NotificationSettingsController
    extends AsyncNotifier<NotificationSettings> {
  @override
  Future<NotificationSettings> build() {
    return ref.read(notificationSettingsRepositoryProvider).load();
  }

  /// 1種の通知をON/OFFする（即ローカル保存 + 楽観反映）。
  Future<void> toggle(NotificationKind kind, bool value) async {
    final current = state.valueOrNull ?? NotificationSettings.defaults();
    // 楽観的更新（保存前にUI反映）。
    state = AsyncValue.data(current.toggle(kind, value));
    await ref
        .read(notificationSettingsRepositoryProvider)
        .setEnabled(kind, value);
  }
}

final notificationSettingsControllerProvider =
    AsyncNotifierProvider<NotificationSettingsController, NotificationSettings>(
  NotificationSettingsController.new,
);

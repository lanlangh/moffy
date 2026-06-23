import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// オンライン/オフライン状態（ARCHITECTURE §1-3 connectivityProvider / S8）。
/// 全画面が監視し、オフライン時は上端バー表示 + 書込み系のグレーアウトに使う。

/// 接続状態の Stream。connectivity_plus の結果を bool（接続あり）に正規化。
final connectivityStreamProvider = StreamProvider<bool>((ref) {
  final connectivity = Connectivity();
  return connectivity.onConnectivityChanged.map(_isOnline);
});

/// 現在オンラインか（同期的に参照したい箇所向け）。初期値は楽観的に true。
final isOnlineProvider = Provider<bool>((ref) {
  final async = ref.watch(connectivityStreamProvider);
  return async.maybeWhen(data: (online) => online, orElse: () => true);
});

bool _isOnline(List<ConnectivityResult> results) {
  return results.any((r) => r != ConnectivityResult.none);
}

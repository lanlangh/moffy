import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Supabase クライアントの DI（ARCHITECTURE §1-3 supabaseClientProvider）。
///
/// 既定では未初期化（throw）。`main()` で Supabase.initialize 後に
/// `supabaseClientProvider.overrideWithValue(Supabase.instance.client)` で
/// 注入する。Supabase 未設定（オフライン専用起動）の場合は override しないため、
/// このプロバイダを watch する側は事前に hasSupabase を確認すること。
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  throw StateError(
    'supabaseClientProvider が未初期化です。main() で overrideWithValue してください。',
  );
});

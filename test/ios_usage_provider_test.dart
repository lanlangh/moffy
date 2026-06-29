import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/usage/ios_usage_provider.dart';
import 'package:moffy/core/usage/usage_models.dart';
import 'package:moffy/core/usage/usage_provider.dart';

/// IOSUsageProvider の単体テスト（ネイティブ MethodChannel をモック）。
///
/// iOS は分数を取得できず「しきい値到達（分）の近似値」を扱う。本テストは
/// チャネル契約（メソッド名・引数・戻り値形状）と DailyUsage 変換・例外マッピング、
/// および S11（記録のある日のみ baseline に入れる）の不変条件を固定する。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.moffy/usage_stats_test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late IOSUsageProvider provider;
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall call)? handler;

  setUp(() {
    calls = <MethodCall>[];
    provider = IOSUsageProvider(channel: channel);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler?.call(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('mode は thresholdAchievement（iOS は近似値）', () {
    expect(provider.mode, UsageMode.thresholdAchievement);
  });

  test('UsageProvider かつ ScreenTimeAppSelection を実装する', () {
    expect(provider, isA<UsageProvider>());
    expect(provider, isA<ScreenTimeAppSelection>());
  });

  group('checkPermission', () {
    test('granted', () async {
      handler = (_) async => 'granted';
      expect(await provider.checkPermission(), UsagePermissionStatus.granted);
    });

    test('permanently_denied -> permanentlyDenied（OS設定誘導）', () async {
      handler = (_) async => 'permanently_denied';
      expect(
        await provider.checkPermission(),
        UsagePermissionStatus.permanentlyDenied,
      );
    });

    test('not_applicable -> notApplicable', () async {
      handler = (_) async => 'not_applicable';
      expect(
        await provider.checkPermission(),
        UsagePermissionStatus.notApplicable,
      );
    });

    test('未知の値 / PlatformException -> denied（再要求可）', () async {
      handler = (_) async => 'whatever';
      expect(await provider.checkPermission(), UsagePermissionStatus.denied);
      handler = (_) async => throw PlatformException(code: 'boom');
      expect(await provider.checkPermission(), UsagePermissionStatus.denied);
    });
  });

  group('requestPermission', () {
    test('requestPermission メソッドを呼び結果を写像する', () async {
      handler = (call) async {
        expect(call.method, 'requestPermission');
        return 'granted';
      };
      expect(await provider.requestPermission(), UsagePermissionStatus.granted);
    });

    test('例外時は checkPermission にフォールバック', () async {
      handler = (call) async {
        if (call.method == 'requestPermission') {
          throw PlatformException(code: 'boom');
        }
        return 'granted'; // checkPermission
      };
      expect(await provider.requestPermission(), UsagePermissionStatus.granted);
      expect(
        calls.map((c) => c.method),
        containsAllInOrder(<String>['requestPermission', 'checkPermission']),
      );
    });
  });

  group('presentAppPicker / hasAppSelection', () {
    test('presentAppPicker は selected/count を返す', () async {
      handler = (call) async {
        expect(call.method, 'presentAppPicker');
        return <String, Object?>{'selected': true, 'count': 3};
      };
      final r = await provider.presentAppPicker();
      expect(r.selected, true);
      expect(r.count, 3);
    });

    test('presentAppPicker キャンセル/例外は none', () async {
      handler = (_) async => throw PlatformException(code: 'cancelled');
      final r = await provider.presentAppPicker();
      expect(r.selected, false);
      expect(r.count, 0);
    });

    test('hasAppSelection', () async {
      handler = (_) async => true;
      expect(await provider.hasAppSelection(), true);
      handler = (_) async => null; // null は false 扱い
      expect(await provider.hasAppSelection(), false);
    });
  });

  group('fetchDailyUsage', () {
    test('minutes>0 -> threshold mode の DailyUsage（dateMs を渡す）', () async {
      handler = (call) async {
        expect(call.method, 'queryDailyUsage');
        expect((call.arguments as Map)['dateMs'], isA<int>());
        return <String, Object?>{'minutes': 60};
      };
      final u = await provider.fetchDailyUsage(
        date: DateTime(2026, 6, 26),
        targetPackages: const ['ignored.on.ios'],
      );
      expect(u.totalMinutes, 60);
      expect(u.mode, UsageMode.thresholdAchievement);
      expect(u.isZero, false);
    });

    test('minutes=0 -> isZero（低利用＝しきい値未達）', () async {
      handler = (_) async => <String, Object?>{'minutes': 0};
      final u = await provider.fetchDailyUsage(
        date: DateTime(2026, 6, 26),
        targetPackages: const [],
      );
      expect(u.totalMinutes, 0);
      expect(u.isZero, true);
    });

    test('no_permission -> UsageException', () async {
      handler = (_) async => throw PlatformException(code: 'no_permission');
      expect(
        () => provider.fetchDailyUsage(
          date: DateTime(2026, 6, 26),
          targetPackages: const [],
        ),
        throwsA(
          isA<UsageException>().having((e) => e.code, 'code', 'no_permission'),
        ),
      );
    });
  });

  group('fetchUsageRange', () {
    test('記録のある日のみ返し minutes<=0 を除外（S11: baseline を薄めない）', () async {
      handler = (call) async {
        expect(call.method, 'queryRangeUsage');
        final args = call.arguments as Map;
        expect(args['startMs'], isA<int>());
        expect(args['endMs'], isA<int>());
        return <Object?>[
          {
            'dateMs': DateTime(2026, 6, 24).millisecondsSinceEpoch,
            'minutes': 90,
          },
          {
            'dateMs': DateTime(2026, 6, 25).millisecondsSinceEpoch,
            'minutes': 0, // 除外される
          },
          {
            'dateMs': DateTime(2026, 6, 23).millisecondsSinceEpoch,
            'minutes': 45,
          },
        ];
      };
      final list = await provider.fetchUsageRange(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 25),
        targetPackages: const [],
      );
      expect(list.length, 2);
      expect(
        list.every((d) => d.mode == UsageMode.thresholdAchievement),
        true,
      );
      expect(list.map((d) => d.totalMinutes).toSet(), {90, 45});
    });

    test('null 応答は空リスト', () async {
      handler = (_) async => null;
      final list = await provider.fetchUsageRange(
        startDate: DateTime(2026, 6, 20),
        endDate: DateTime(2026, 6, 25),
        targetPackages: const [],
      );
      expect(list, isEmpty);
    });
  });
}

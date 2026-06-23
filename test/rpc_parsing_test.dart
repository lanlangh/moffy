import 'package:flutter_test/flutter_test.dart';
import 'package:moffy/core/sync/finalize_models.dart';
import 'package:moffy/core/usage/usage_models.dart';
import 'package:moffy/features/collection/domain/mofi_models.dart';
import 'package:moffy/features/eggs/domain/egg_models.dart';

/// サーバーRPC（fn_hatch_egg 等）のレスポンスを Dart 型へパースする単体テスト。
///
/// 信頼境界（ARCHITECTURE §2-3）: 抽選はサーバー。クライアントは「サーバーが返した
/// 結果 jsonb」を受け取って演出・図鑑表示に使うだけ。本テストはその受け口
/// （fromJson）が migration 0002 の fn_hatch_egg が返す wire 形を正しく解釈できるかを担保する。
void main() {
  group('HatchResult.fromJson（fn_hatch_egg の戻り jsonb）', () {
    test('色違いSR個体・新規発見を正しくパース', () {
      // fn_hatch_egg が jsonb_build_object で返す形（migration 0002）。
      final json = <String, Object?>{
        'species': <String, Object?>{
          'id': 'dragon_03',
          'family': 'dragon',
          'rarity': 'sr',
          'name': 'らいりゅう',
          'sort_order': 13,
        },
        'is_shiny': true,
        'is_new_dex_entry': true,
        'from_egg_id': 'egg_abc',
      };

      final r = HatchResult.fromJson(json);
      expect(r.species.id, 'dragon_03');
      expect(r.species.family, MofiFamily.dragon);
      expect(r.species.rarity, MofiRarity.sr);
      expect(r.species.name, 'らいりゅう');
      expect(r.species.sortOrder, 13);
      expect(r.isShiny, isTrue);
      expect(r.isNewDexEntry, isTrue);
      expect(r.fromEggId, 'egg_abc');
    });

    test('通常色Common・既発見（重複）をパース', () {
      final json = <String, Object?>{
        'species': <String, Object?>{
          'id': 'slime_01',
          'family': 'slime',
          'rarity': 'common',
          'name': 'ぷるりん',
          'sort_order': 1,
        },
        'is_shiny': false,
        'is_new_dex_entry': false,
        'from_egg_id': 'egg_xyz',
      };

      final r = HatchResult.fromJson(json);
      expect(r.species.rarity, MofiRarity.common);
      expect(r.isShiny, isFalse);
      expect(r.isNewDexEntry, isFalse);
    });
  });

  group('FinalizeDayResult.fromJson（fn_finalize_day の戻り jsonb）', () {
    test('確定成功・倍率/上限/卵反映ありをパース', () {
      // migration 0002 の fn_finalize_day（finalized=true）の戻り形。
      final json = <String, Object?>{
        'finalized': true,
        'points_awarded': 480,
        'base_points': 400,
        'multiplier': 1.5,
        'baseline_minutes': 120,
        'reduced_minutes': 90,
        'capped': true,
        'stage': 'confirmed',
        'streak_after': 7,
        'egg_applied': <String, Object?>{
          'applied_to': 'egg',
          'egg_id': 'egg_abc',
          'growth_after': 500,
        },
        'already_finalized': false,
      };

      final r = FinalizeDayResult.fromJson(json);
      expect(r.finalized, isTrue);
      expect(r.pointsAwarded, 480);
      expect(r.basePoints, 400);
      expect(r.multiplier, 1.5);
      expect(r.baselineMinutes, 120);
      expect(r.reducedMinutes, 90);
      expect(r.capped, isTrue);
      expect(r.stage, 'confirmed');
      expect(r.streakAfter, 7);
      expect(r.eggApplied?['applied_to'], 'egg');
      expect(r.alreadyFinalized, isFalse);
      expect(r.reason, isNull);
    });

    test('生データ未提出（finalized=false / reason）をパース', () {
      final json = <String, Object?>{
        'finalized': false,
        'reason': 'no_usage_data',
      };
      final r = FinalizeDayResult.fromJson(json);
      expect(r.finalized, isFalse);
      expect(r.reason, 'no_usage_data');
      expect(r.pointsAwarded, 0);
    });

    test('冪等スキップ（already_finalized / 加算0）をパース', () {
      final json = <String, Object?>{
        'finalized': true,
        'points_awarded': 0,
        'base_points': 120,
        'multiplier': 1.0,
        'baseline_minutes': 60,
        'reduced_minutes': 120,
        'capped': false,
        'stage': 'provisional',
        'streak_after': 3,
        'egg_applied': null,
        'already_finalized': true,
      };
      final r = FinalizeDayResult.fromJson(json);
      expect(r.finalized, isTrue);
      expect(r.alreadyFinalized, isTrue);
      expect(r.pointsAwarded, 0);
      expect(r.eggApplied, isNull);
    });
  });

  group('UsageDailyDraft（提出ペイロードの往復）', () {
    test('DailyUsage から提出行 / payload を生成し復元できる', () {
      final usage = DailyUsage.fromPerApp(
        date: DateTime(2026, 6, 22, 9, 30), // 時刻成分は日付化される
        perAppMinutes: const {'com.instagram.android': 40, 'com.x': 20},
        mode: UsageMode.exactMinutes,
      );
      final draft = UsageDailyDraft.fromDailyUsage(usage, localPoints: 35);

      expect(draft.dateKey, '2026-06-22');
      final row = draft.toUsageRow();
      expect(row['usage_date'], '2026-06-22');
      expect(row['total_minutes'], 60);
      expect(row['source_mode'], 'exact-minutes');
      expect(row['is_anomaly'], isFalse);

      // payload 往復で local_points（S8競合解決の比較基準）も保持される。
      final restored = UsageDailyDraft.fromPayload(draft.toPayload());
      expect(restored.dateKey, '2026-06-22');
      expect(restored.totalMinutes, 60);
      expect(restored.perAppMinutes['com.instagram.android'], 40);
      expect(restored.mode, UsageMode.exactMinutes);
      expect(restored.localPoints, 35);
    });

    test('異常値（1440分超）フラグが提出行に伝播する（S4）', () {
      final usage = DailyUsage.fromPerApp(
        date: DateTime(2026, 6, 22),
        perAppMinutes: const {'com.x': 2000},
        mode: UsageMode.exactMinutes,
      );
      final draft = UsageDailyDraft.fromDailyUsage(usage);
      expect(draft.isAnomaly, isTrue);
      expect(draft.toUsageRow()['is_anomaly'], isTrue);
    });
  });

  group('WarmupClaimResult.fromJson（fn_claim_warmup の戻り jsonb / F-01）', () {
    test('Day1 初回付与（granted=200 / starter卵へ充当）をパース', () {
      // migration 0003 の fn_claim_warmup（初回 = v_inserted）の戻り形。
      final json = <String, Object?>{
        'claimed': true,
        'day': 1,
        'granted': 200,
        'egg_id': 'egg_starter',
        'egg_applied': <String, Object?>{
          'applied_to': 'egg',
          'egg_id': 'egg_starter',
          'growth_after': 200,
        },
        'balance_after': 200,
        'already_claimed': false,
      };

      final r = WarmupClaimResult.fromJson(json);
      expect(r.claimed, isTrue);
      expect(r.day, 1);
      expect(r.granted, 200);
      expect(r.eggId, 'egg_starter');
      expect(r.eggApplied?['applied_to'], 'egg');
      expect(r.eggApplied?['growth_after'], 200);
      expect(r.balanceAfter, 200);
      expect(r.alreadyClaimed, isFalse);
    });

    test('Day2 初回付与（granted=300 / 累計500で孵化保証）をパース', () {
      final json = <String, Object?>{
        'claimed': true,
        'day': 2,
        'granted': 300,
        'egg_id': 'egg_starter',
        'egg_applied': <String, Object?>{
          'applied_to': 'egg',
          'egg_id': 'egg_starter',
          'growth_after': 500,
        },
        'balance_after': 500,
        'already_claimed': false,
      };
      final r = WarmupClaimResult.fromJson(json);
      expect(r.day, 2);
      expect(r.granted, 300);
      expect(r.eggApplied?['growth_after'], 500);
    });

    test('冪等スキップ（already_claimed=true / 生涯1回・granted=0）をパース', () {
      // 2回目以降の呼び出し: 台帳 conflict で加算されず balance_after は null。
      final json = <String, Object?>{
        'claimed': true,
        'day': 1,
        'granted': 0,
        'egg_id': 'egg_starter',
        'egg_applied': null,
        'balance_after': null,
        'already_claimed': true,
      };
      final r = WarmupClaimResult.fromJson(json);
      expect(r.claimed, isTrue);
      expect(r.granted, 0);
      expect(r.alreadyClaimed, isTrue);
      expect(r.balanceAfter, isNull);
      expect(r.eggApplied, isNull);
    });
  });

  group('Egg.fromJson（eggs select の行）', () {
    test('育成中・アクティブ卵をパース', () {
      final json = <String, Object?>{
        'id': 'egg_1',
        'rarity': 'epic',
        'growth_points': 320,
        'location': 'incubating',
        'slot_index': 1,
        'is_active': true,
        'acquired_source': 'premium',
      };
      final e = Egg.fromJson(json);
      expect(e.id, 'egg_1');
      expect(e.rarity, EggRarity.epic);
      expect(e.growthPoints, 320);
      expect(e.location, EggLocation.incubating);
      expect(e.slotIndex, 1);
      expect(e.isActive, isTrue);
      expect(e.acquiredSource, 'premium');
    });

    test('保管枠（slot null）をパース', () {
      final json = <String, Object?>{
        'id': 'egg_2',
        'rarity': 'normal',
        'growth_points': 0,
        'location': 'storage',
        'slot_index': null,
        'is_active': false,
        'acquired_source': 'standard',
      };
      final e = Egg.fromJson(json);
      expect(e.location, EggLocation.storage);
      expect(e.slotIndex, isNull);
      expect(e.isActive, isFalse);
    });
  });
}

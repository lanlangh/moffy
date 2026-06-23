# Moffy アーキテクチャ設計書 v1.0

> 作成: 開発部署 (engineer) / 日付: 2026-06-19
> 位置づけ: PRD v1.0 (S1〜S14・抽選確率表§4・受け入れ条件§5) を満たす技術設計。
> 対象範囲: ①アーキテクチャ設計 ②OS抽象インターフェース ④Android利用時間取得PoC検証手順。
> DBスキーマ(③)は `supabase/migrations/0001_init.sql` に分離。
> 専門用語は初出時にインラインで日本語説明。

---

## 0. 設計の3大原則 (= このプロジェクト共通の判断軸)

1. **SSOT分離 (= Single Source of Truth / 信頼できる唯一の情報源)**
   - 利用時間の「生データ」= **端末 (Drift = FlutterのローカルSQLite)** がSSOT。
   - ポイント確定・卵成長・図鑑・通貨残高 = **サーバー (Supabase)** がSSOT。
   - 経済パラメータ (抽選確率・成長しきい値・上限480pt・色違い率) = **`app_config` / `drop_tables`** に集約。UIもサーバーRPCも必ずここを参照し、コード内にハードコードしない。
2. **信頼境界 (= trust boundary) を守る**
   - クライアントの主張 (「自分はPro」「ポイント+9999」) を一切信頼しない。
   - ポイント加算・孵化・報酬付与・通貨消費は **サーバーRPC (PostgreSQL関数 / security definer)** で原子的・冪等に処理。RLS でクライアントの直接書き込みを封じる。
3. **5状態を必ず設計する (= 完成基準 / DoD)**
   - すべての画面・データ取得で **ハッピーパス / エラー / ローディング / 空状態 / オフライン** の5状態を実装する。1つでも欠けたら「完成」と呼ばない (§5)。

---

## 1. アーキテクチャ設計

### 1-1. ディレクトリ構成 (Feature-First)

```
lib/
├── main.dart                       # エントリ。ProviderScope + 初期化(Supabase/Drift/Sentry/PostHog)
├── app.dart                        # MaterialApp.router / テーマ適用 / 認証ゲート
│
├── core/                           # 機能横断の共通基盤 (= レール)
│   ├── theme/                      # デザイントークン(色/タイポ/余白) — デザイン部署成果物を実装
│   │   ├── app_theme.dart
│   │   ├── tokens.dart
│   │   └── components/             # 共通UI(MoffyButton, MoffyCard, LoadingSkeleton, EmptyState, ErrorView)
│   ├── db/                         # Drift (ローカルDB / 生データSSOT)
│   │   ├── app_database.dart       # @DriftDatabase 定義
│   │   ├── tables/                 # usage_raw, sync_queue, cached_* テーブル
│   │   └── daos/                   # UsageDao, SyncQueueDao
│   ├── sync/                       # オフライン同期エンジン (S8)
│   │   ├── sync_service.dart       # 送信キュー処理 / オンライン復帰検知 / 競合解決
│   │   ├── connectivity_provider.dart  # オンライン/オフライン状態
│   │   └── sync_models.dart
│   ├── constants/                  # 経済パラメータの「クライアント側キャッシュ層」
│   │   ├── remote_config.dart      # app_config/drop_tables を取得しキャッシュ(SSOT参照)
│   │   └── app_constants.dart      # パッケージ名等の不変定数(リモート化しないもの)
│   ├── error/                      # 共通エラー型 / Failure / Result
│   │   └── failure.dart            # sealed class Failure (network/auth/server/notAllowed...)
│   ├── usage/                      # ★OS抽象 (利用時間取得 + ポイント計算)
│   │   ├── usage_provider.dart     # abstract UsageProvider (§2)
│   │   ├── android_usage_provider.dart   # UsageStatsManager 実装(Platform Channel)
│   │   ├── ios_usage_provider.dart       # DeviceActivity 実装(v1.1)
│   │   ├── point_calculator.dart   # abstract PointCalculator + 2モード実装(§2)
│   │   └── usage_models.dart       # UsageSnapshot / DailyUsage / PermissionStatus
│   ├── auth/                       # 匿名認証ファースト → 連携 (S10)
│   │   └── auth_repository.dart
│   ├── analytics/                  # PostHog ラッパ(ファネルイベント)
│   ├── observability/              # Sentry 初期化 / __DEV__ ガードのログユーティリティ
│   └── providers/                  # supabaseClientProvider 等のグローバルProvider
│
└── features/                       # 画面=機能単位 (Feature-First)
    ├── home/                       # ホーム(最も開く画面): 今日の利用/削減/育成卵/クエスト/pt/gem
    ├── eggs/                       # 卵: 育成枠3 + 保管枠 + 孵化演出 (S5,S6)
    ├── collection/                 # 図鑑: 一覧/達成率/レアリティ・色違いフィルタ (S13)
    ├── quests/                     # クエスト: デイリー/ウィークリー/報酬 (S14)
    ├── profile/                    # プロフィール + 設定 + アカウント削除導線 (S12) + 通知設定(S9)
    ├── usage/                      # 利用時間の詳細/権限オンボーディング画面
    └── paywall/                    # プレミアム(RevenueCat)購入/復元/解約導線
```

各 `features/<x>/` の内部レイヤリング:

```
features/home/
├── data/            # repository実装 / DTO / Supabase・Driftアクセス
│   └── home_repository.dart
├── domain/          # エンティティ / repository抽象 / ユースケース(必要時)
│   └── models.dart
└── presentation/    # 画面・Widget・Riverpod Notifier/Provider
    ├── home_screen.dart
    ├── home_controller.dart        # AsyncNotifier (状態管理)
    └── widgets/
```

### 1-2. レイヤリングと依存方向

```
presentation (Widget + Riverpod)
      │ watch/read
      ▼
domain (AsyncNotifier / UseCase / Entity)      ← 純粋ロジック。Flutter非依存が理想
      │
      ▼
data (Repository)
      ├── remote: Supabase (RPC/PostgREST)      … 確定値SSOT
      └── local:  Drift                          … 生データSSOT + キャッシュ
```

- **依存は内向き** (presentation → domain → data)。data はSupabase/Driftの詳細を隠蔽し、上位には抽象 (Repository) のみ公開。
- OS差 (Android/iOS) は **`core/usage/` の抽象 (§2) に閉じ込める**。features 層はプラットフォームを意識しない。

### 1-3. Riverpod 構成

- **状態管理は Riverpod の `AsyncNotifier` / `Notifier` (riverpod_generator + `@riverpod`)** を標準とする。
- 非同期データ取得は **`AsyncValue<T>` (= loading/data/error の3状態を型で表現)** を全面採用。これにより **ローディング・エラー状態がUIで強制的に扱われる** (5状態のうち2つを型で担保)。

```dart
// 例: ホームの状態。AsyncValue が loading/error を型で強制。
@riverpod
class HomeController extends _$HomeController {
  @override
  Future<HomeState> build() async {
    final usage   = await ref.watch(todayUsageProvider.future);
    final eggs     = await ref.watch(activeEggProvider.future);
    return HomeState(usage: usage, activeEgg: eggs, ...);
  }
}
```

Provider の階層 (依存注入):

| Provider | 役割 | スコープ |
|---|---|---|
| `supabaseClientProvider` | Supabaseクライアント | app全体 / override可(テスト) |
| `appDatabaseProvider` | Drift DB | app全体 |
| `remoteConfigProvider` | app_config/drop_tables キャッシュ (SSOT参照) | app全体 |
| `connectivityProvider` | オンライン/オフライン (Stream) | app全体 |
| `usageProviderProvider` | OS抽象 (Android/iOS で実装切替) | platform依存override |
| `pointCalculatorProvider` | exact-minutes / threshold-achievement 切替 | platform依存override |
| `<feature>RepositoryProvider` | 各機能のデータ層 | feature |
| `<feature>ControllerProvider` | 各画面のAsyncNotifier | feature |

### 1-4. 5状態の扱い方 (= 設計の核 / DoD)

| 状態 | 実装方針 |
|---|---|
| **ハッピーパス** | `AsyncValue.data` 。Repositoryがローカル(Drift)→楽観反映、裏でサーバー同期。 |
| **ローディング** | `AsyncValue.loading` → `core/theme/components/LoadingSkeleton`。孵化演出中は操作ロック+スキップ可(§5-2)。初回取得はスケルトン、再取得はpull-to-refresh。 |
| **エラー** | `AsyncValue.error` を `core/error/Failure` (sealed) に正規化 → `ErrorView` (再試行ボタン付き)。権限エラーは「権限再要求導線」専用ビュー(§5-1)。 |
| **空状態** | データ0件は error ではなく `EmptyState` Widget。育成枠が空→「卵をセットしよう」+ 保管卵一覧(§5-2)。利用0分は「削減量=基準値」として正常処理(§5-1)。 |
| **オフライン** | `connectivityProvider` を全画面が監視。①読み取り: Driftキャッシュ表示。②書き込み: 楽観的更新 + `sync_queue` 投入。③通貨消費・連携・削除・孵化確定は**オフライン不可**として導線をグレーアウト+理由表示(S8,§5-4)。 |

### 1-5. オフライン同期の流れ (S8)

```
[オフライン中]
  端末がOS利用統計を取得 → Drift(usage_raw)に保存(=生データSSOT)
  PointCalculatorで暫定pt計算 → UI即時反映(楽観的更新)
  確定が必要な操作(孵化/報酬/通貨消費)は sync_queue に積むだけ。実行はしない。

[オンライン復帰] (connectivityProvider が検知)
  1. 未確定の usage_daily をサーバーに提出 (insert/未確定update)
  2. サーバーRPC fn_finalize_day が「サーバー時刻+ユーザーTZ」で日付確定(S11)
     → 基準値算出(7日平均/欠損除外/30分クランプ) → 差分 → ストリーク倍率
     → 480ptキャップ → point_ledger に冪等加算(idempotency_key=日付×source)
  3. クライアントは確定値を取得しキャッシュ更新。
     競合時はサーバー値採用だが「確定ptを減らす上書きはしない」(S8: 増加方向のみ反映)
  4. sync_queue の孵化/報酬/消費RPCを順次実行(各RPCが冪等なので二重実行安全)
```

---

## 2. OS抽象インターフェース (Dart)

> OS差 (Android `UsageStatsManager` / iOS `DeviceActivity`) を2つの抽象に閉じ込め、
> iOS追従時の再設計を防ぐ。ポイント計算は `exact-minutes`(Android) /
> `threshold-achievement`(iOS) の2モードで抽象化 (ORG決定済み)。

### 2-1. `UsageProvider` — 利用時間取得の抽象

```dart
/// 対象SNSアプリの利用時間取得を抽象化する。
/// Android = UsageStatsManager (exact-minutes) / iOS = DeviceActivity (threshold) で実装。
abstract interface class UsageProvider {
  /// このプラットフォームの計算モード。PointCalculator の選択に使う。
  UsageMode get mode;

  /// 利用統計へのアクセス権限の現在状態を返す。
  /// Android: PACKAGE_USAGE_STATS / iOS: FamilyControls Authorization。
  Future<UsagePermissionStatus> checkPermission();

  /// 権限要求フローを起動する(OS設定画面への遷移を含む)。
  /// 戻り値は要求後の状態。未許可時は呼び出し側がフォールバックUIを出す。
  Future<UsagePermissionStatus> requestPermission();

  /// 指定日(ユーザーTZの暦日)における対象アプリ別の利用分数を取得する。
  /// [targetPackages] はホワイトリスト(S3: 対象4SNS)。
  /// 取得失敗は UsageException を throw する(権限なし/OS API失敗)。
  Future<DailyUsage> fetchDailyUsage({
    required DateTime date,
    required List<String> targetPackages,
  });

  /// 指定期間(基準値計算用の直近N日)の日別利用を一括取得する。
  /// 欠損日(取得不可日)はリストに含めない(= 分母から除外 / S11)。
  Future<List<DailyUsage>> fetchUsageRange({
    required DateTime startDate,   // 含む
    required DateTime endDate,     // 含む
    required List<String> targetPackages,
  });
}

/// ポイント計算モード。OS差をここで表現。
enum UsageMode {
  /// Android: 分単位の正確な利用時間が取れる。
  exactMinutes,
  /// iOS: 分単位は取れず、段階しきい値の「達成/未達」しか取れない(15/30分起点)。
  thresholdAchievement,
}

/// 利用統計アクセス権限の状態。
enum UsagePermissionStatus {
  granted,          // 許可済み
  denied,           // 拒否(再要求可)
  permanentlyDenied,// 恒久拒否(OS設定誘導が必要)
  notApplicable,    // この機能を持たないプラットフォーム
}

/// ある1日の対象アプリ利用実績(生データ)。
class DailyUsage {
  final DateTime date;                  // ユーザーTZの暦日(0:00基準)
  final Map<String, int> perAppMinutes; // パッケージ名 -> 利用分
  final int totalMinutes;               // 対象アプリ合計(= ポイント計算の入力 / S3)
  final UsageMode mode;                 // どのモードで取得したか
  final bool isAnomaly;                 // S4: 物理的にありえない値(1440分超)なら true

  const DailyUsage({
    required this.date,
    required this.perAppMinutes,
    required this.totalMinutes,
    required this.mode,
    this.isAnomaly = false,
  });
}

/// 取得失敗時の例外(権限なし/OS API失敗/Platform Channelエラー)。
class UsageException implements Exception {
  final String code;     // 'no_permission' | 'platform_error' | 'unsupported'
  final String message;
  const UsageException(this.code, this.message);
}
```

### 2-2. `PointCalculator` — ポイント計算の抽象 (2モード)

```dart
/// 削減量からポイントを計算する抽象。実装は exact-minutes / threshold-achievement の2つ。
/// 注意: ここで計算するのは「端末側の暫定値(楽観的更新用)」。
///       確定値は必ずサーバーRPC fn_finalize_day が再計算する(S8: サーバーSSOT)。
///       経済パラメータ(上限/クランプ/倍率)は EconomyParams 経由で app_config を参照する。
abstract interface class PointCalculator {
  UsageMode get mode;

  /// その日の基礎ポイント(倍率適用前)を計算する。
  /// 削減量 = baselineMinutes - todayMinutes。マイナスは 0 にクランプ(S2: 下限0)。
  /// 上限・色違い等の経済値は [params] から取得(ハードコード禁止 / SSOT)。
  int calculateBasePoints({
    required DailyUsage today,
    required Baseline baseline,
    required EconomyParams params,
  });

  /// 基礎ポイントにストリーク倍率を適用し、1日上限でクランプした最終ポイントを返す(S14,S4)。
  /// 倍率は基礎ptにのみ適用。固定報酬(クエスト/ジェム/卵)には掛けない。
  int applyStreakAndCap({
    required int basePoints,
    required int currentStreakDays,
    required EconomyParams params,
  });
}

/// Android実装: 分単位の正確な削減量から線形にpt化(1分=1pt)。
final class ExactMinutesPointCalculator implements PointCalculator {
  @override
  UsageMode get mode => UsageMode.exactMinutes;
  // calculateBasePoints: max(0, (baseline.appliedMinutes - today.totalMinutes)) * params.pointPerMinute
  // ...
}

/// iOS実装(v1.1): 段階しきい値の達成度を近似pt化(15/30分起点の刻み)。
/// 分数が取れないため「しきい値を何段クリアしたか」を擬似削減量に換算する。
final class ThresholdAchievementPointCalculator implements PointCalculator {
  @override
  UsageMode get mode => UsageMode.thresholdAchievement;
  // 段階しきい値(15/30分起点)の達成段数 -> 近似削減量 -> pt。
  // ...
}

/// 基準値(S1 ウォームアップ方式の結果)。
class Baseline {
  final DateTime date;
  final double? rawAverageMinutes; // 欠損除外後の生平均。データ無しは null
  final int appliedMinutes;        // 30分クランプ後の適用値(§4-5)
  final int sampleDays;            // 平均の分母(実データ日数)
  final BaselineStage stage;       // warmup / provisional / confirmed
  const Baseline({...});
}

enum BaselineStage { warmup, provisional, confirmed } // S1

/// 経済パラメータ(app_config の単一情報源をクライアントにロードしたもの)。
/// ここに集約し、計算ロジックにマジックナンバーを書かない。
class EconomyParams {
  final int pointPerMinute;        // 1
  final int dailyPointCap;         // 480 (S4)
  final int baselineFloorMinutes;  // 30 (§4-5)
  final int baselineWindowDays;    // 7 (S11)
  final EggThresholds eggThresholds;       // 100/250/500
  final List<StreakTier> streakMultipliers;// [{1,1.0},{3,1.2},{7,1.5},{30,2.0}]
  final double shinyRate;          // 0.02 (S13)
  const EconomyParams({...});
}
```

### 2-3. クライアント計算とサーバー確定の責務分離 (重要)

| 計算 | クライアント (PointCalculator) | サーバー (RPC) |
|---|---|---|
| 用途 | オフライン中の**暫定表示**(楽観的更新) | **確定値**(SSOT) |
| 日付境界 | 端末ローカル日付(暫定) | サーバー時刻 + ユーザーTZ(正 / S11) |
| 信頼性 | 表示のみ。台帳には書かない | point_ledger に冪等加算 |
| 改ざん耐性 | なし(端末値は信頼しない) | あり(S4: 上限/異常値/ロールバック検知) |

クライアントの計算結果は **絶対に台帳へ直接書かない**。`point_ledger` の書き込みは RPC のみ (RLSで封鎖)。

---

## 3. DBスキーマ

→ 実行可能なDDL + RLSポリシー + マスタ初期データは
**`supabase/migrations/0001_init.sql`** を参照。

要点 (レビュー観点):
- **冪等加算**: `point_ledger.idempotency_key` を unique 制約 (= 日付×source) にし、二重加算を物理的に防止。
- **信頼境界**: `entitlements` / `point_ledger` / `mofi_collection` はクライアント insert/update ポリシーを**作らない** → RPC(security definer)のみ書き込み可。
- **master読み取り公開**: `mofi_species` / `drop_tables` / `app_config` / `quest_definitions` は select ポリシー `using(true)`、書き込みポリシー無し (service_roleのみ)。
- **経済パラメータの単一情報源**: `app_config` / `drop_tables` に §4 の全数値を seed。Android実数値検証後はここの value だけ更新すれば UI・サーバー双方に反映。
- **アクティブ卵1個制約**: `eggs` の部分unique index `uq_eggs_one_active`(S6)。

---

## 4. Android 利用時間取得 PoC 検証手順書

> 目的: `UsageStatsManager` で対象4SNSの利用分数が**実機で正確に取れるか**を最小コストで検証する。
> 実行環境(実機)は現サイクルに無いため、ここでは「検証手順書 + Platform Channel設計 + フォールバック設計」までを確定し、実機が用意でき次第そのまま実行できる状態にする。

### 4-1. 前提知識 (= 用語)

- **`UsageStatsManager`**: Androidが提供する「アプリ別の利用統計」を返すシステムサービス。`queryUsageStats(interval, begin, end)` で期間内のアプリ別フォアグラウンド時間を取得できる。
- **`PACKAGE_USAGE_STATS`**: 上記APIを使うための**特別権限**(= signature|privileged|appop)。通常の `requestPermissions()` では取れず、**ユーザーがOS設定の「使用状況へのアクセス」画面で手動ON**にする必要がある。`AppOpsManager` で許可状態を確認する。
- **Platform Channel (MethodChannel)**: Flutter(Dart) ⇄ ネイティブ(Kotlin) 間の通信路。利用統計取得はネイティブでしか行えないためChannelで橋渡しする。

### 4-2. 権限取得フロー (受け入れ §5-1 エラー/権限再要求に対応)

```
1. アプリ初回起動 → コアループ(お試し孵化 / S1ウォームアップ)を1回体験させる
   ※ 権限はここでは要求しない(許可率を上げるため / S9と同方針)
2. 利用時間ベースのポイントが必要になった時点(Day2〜3頃)で権限オンボーディング画面を表示
   「正確な削減ポイントには『使用状況へのアクセス』が必要です」+ 図解
3. [許可する]タップ → MethodChannel経由で
   Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS) を起動しOS設定へ遷移
4. ユーザーがMoffyをON → アプリ復帰
5. onResume/フォーカス復帰時に AppOpsManager で再チェック
   - granted   → 利用統計取得開始
   - denied    → フォールバックUI(§4-5)を表示し再要求導線を残す
```

### 4-3. Platform Channel 設計

チャネル名: `com.moffy/usage_stats`

| Method | 引数 | 戻り値 | 説明 |
|---|---|---|---|
| `checkPermission` | なし | `String` (`granted`/`denied`) | `AppOpsManager.checkOpNoThrow(OPSTR_GET_USAGE_STATS)` で判定 |
| `openUsageAccessSettings` | なし | `void` | `ACTION_USAGE_ACCESS_SETTINGS` Intent起動 |
| `queryDailyUsage` | `{beginMs, endMs, packages:[...]}` | `Map<String,int>` (package→分) | `queryUsageStats(INTERVAL_DAILY, begin, end)` を集計 |
| `queryRangeUsage` | `{startMs, endMs, packages:[...]}` | `List<Map>` (日別) | 基準値計算用の期間取得。`queryUsageStats` を日ごとに集計 |

Kotlin側の集計ロジック要点:
- `queryUsageStats` は同一パッケージの複数 `UsageStats` を返すことがある → `totalTimeInForeground` をパッケージごとに**合算**してから分換算 (`/1000/60`)。
- `INTERVAL_DAILY` の境界はOS依存でブレるため、PoCでは `INTERVAL_BEST` も併用し**どちらが実測に近いか比較計測**する (検証項目)。
- タイムゾーン: begin/end は **ユーザーTZの0:00〜23:59:59** をミリ秒で渡す(S11と一致させる)。

Dart側 (`android_usage_provider.dart`) は `UsageProvider` 実装としてこのChannelを呼ぶ。

### 4-4. PoC で実数値検証すべき項目 (= CEO報告と一致)

| 検証項目 | 計測方法 | 合否基準(仮) |
|---|---|---|
| **取得精度** | TikTok等を実機で正確に時間を測りながら使用 → API値とストップウォッチを比較 | 誤差±2分以内/日 |
| **集計の妥当性** | `INTERVAL_DAILY` vs `INTERVAL_BEST` の差分を比較 | 実測に近い方を採用 |
| **対象4アプリの実パッケージ名** | 実機で実際のpackage名を確認(TikTokは地域で異なる場合あり) | 4つすべて取得可 |
| **基準値ロジック** | 7日平均・欠損除外・30分クランプ(§4-5)が想定通りか | PRD仕様一致 |
| **480pt上限(S4)** | 大量削減日で480を超えないか | 超えない |
| **30分クランプ(S2/§4-5)** | 元々低利用(基準<30分)のユーザーで0pt詰みしないか | 30分扱いで加点される |
| **孵化頻度/SSR体感** | §4確率での試行(単体テスト分布 + 実機体感) | 体感が出荷品質か |

### 4-5. 未許可時フォールバック設計 (= エラー/空状態の受け入れ §5-1)

- 権限が無い間も**アプリは使える**(クラッシュさせない)。
  - ポイント計算は**停止**し、ホームに「権限を許可すると今日の削減ptが計算されます」+ 再要求ボタン。
  - 初回ボーナス卵(S1ウォームアップ)は**権限不要で進行**するため、権限が無くてもコアループ初体験は成立する。
- `permanentlyDenied` 相当(設定でOFFのまま戻ってきた)時は、OS設定への明示的な誘導文 + スクショ手順を表示。
- フォールバック中も Drift / サーバー同期は他データ(図鑑/クエスト/通貨)について正常動作させる。

### 4-6. Manifest / 既知の注意

- `AndroidManifest.xml` に `<uses-permission android:name="android.permission.PACKAGE_USAGE_STATS" tools:ignore="ProtectedPermissions"/>` を宣言(宣言しないと設定画面に出ない)。
- Google Play審査: `PACKAGE_USAGE_STATS` は**機微権限**。データ安全性フォームと**プライバシーポリシーで利用目的を明示**(法務部署と整合 / 「SNS利用時間の削減ゲーム化のため」)。用途逸脱はリジェクト要因。

---

## 5. QA(レビュー)への引き継ぎ — 変更点とテスト観点

**変更点(新規ファイル)**
- `docs/ARCHITECTURE.md`(本書)
- `supabase/migrations/0001_init.sql`(DDL + RLS + マスタseed)

**テスト観点(第三者=Codexレビュー向け)**
1. **冪等性**: `point_ledger.idempotency_key`(日付×source)で同一日二重加算が起きないか。RPC再実行時も安全か。
2. **信頼境界**: `entitlements`/`point_ledger`/`mofi_collection` にクライアント書き込みポリシーが**無い**ことを確認(改ざん不可)。
3. **RLS網羅**: 全userテーブルで `auth.uid()=user_id` が効くか。他人のデータが見えないか。
4. **SSOT一貫性**: §4の全数値が `app_config`/`drop_tables` に集約され、ARCHITECTUREの計算式にマジックナンバーが残っていないか。
5. **確率表の整合**: `drop_tables` の各分布合計が1.0、§4-2と一致するか。色違い2.0%・上限480・クランプ30が一致するか。
6. **5状態網羅**: 各画面で error/loading/empty/offline の設計が揃っているか。

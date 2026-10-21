/// 1日の評価（◎/○/△/計測なし）の純粋ロジック（0018 / docs/design/EGG_PACING_DESIGN.md §2）。
///
/// 重要: ここで計算するのは**端末側の暫定評価（「きょうのペース」表示用）**。
/// 確定値は必ずサーバー RPC `fn_finalize_day` が再計算する（ARCHITECTURE §2-3: サーバーSSOT）。
/// 条件・pt は [DailyBands]（`app_config.daily_bands`）経由で参照し、マジックナンバーを書かない。
///
/// 式（サーバーと同じ）: きのうの計測分を m、ふだんのSNS時間を R として
///   ◎ しっかり離れた日: m <= max(30, floor(R × 1/2))   → 100pt
///   ○ 減らした日      : m <= max(60, floor(R × 3/4))   →  70pt
///   △ 多めだった日    : それ以外                        →  15pt
///   — 計測なし        : 評価しない                      →   0pt
library;

import '../constants/economy.dart';

/// 1日の評価。
enum DayBand {
  /// ◎ しっかり離れた日（ふだんの半分以下、または 30分以内）。
  great,

  /// ○ 減らした日（ふだんの4分の3以下、または 60分以内）。
  good,

  /// △ 多めだった日（ふだんと同じかそれ以上）。
  poor,

  /// 計測なし（権限なし / iOS で対象アプリ未選択 / 開かなかった）。
  unmeasured;

  /// サーバー（`fn_finalize_day` の `band`）との相互変換。
  String get wire => name;

  static DayBand fromWire(String? s) => switch (s) {
        'great' => DayBand.great,
        'good' => DayBand.good,
        'poor' => DayBand.poor,
        _ => DayBand.unmeasured,
      };

  /// 画面の見出し（責めない文言 / §4-5）。
  String get label => switch (this) {
        DayBand.great => 'しっかり離れた日',
        DayBand.good => '減らした日',
        DayBand.poor => '多めだった日',
        DayBand.unmeasured => '計れなかった日',
      };

  /// 記号（◎/○/△）。計測なしは「—」。
  String get mark => switch (this) {
        DayBand.great => '◎',
        DayBand.good => '○',
        DayBand.poor => '△',
        DayBand.unmeasured => '—',
      };

  /// 卵が進む評価か（連続日数が +1 になる評価と同じ）。
  bool get keepsStreak => this == DayBand.great || this == DayBand.good;
}

/// 評価の純粋関数群。
abstract final class DayBandCalculator {
  /// [minutes]（その日の計測分）と [usualMinutes]（R）から評価を決める。
  ///
  /// [measured] が false なら無条件に [DayBand.unmeasured]。
  static DayBand evaluate({
    required int minutes,
    required int usualMinutes,
    required DailyBands bands,
    bool measured = true,
  }) {
    if (!measured) return DayBand.unmeasured;
    if (minutes <= bands.great.limitFor(usualMinutes)) return DayBand.great;
    if (minutes <= bands.good.limitFor(usualMinutes)) return DayBand.good;
    return DayBand.poor;
  }

  /// 評価ごとに卵へ入る pt（1日上限 [cap] でクランプ）。
  static int pointsFor(DayBand band, DailyBands bands, {int? cap}) {
    final raw = switch (band) {
      DayBand.great => bands.great.points,
      DayBand.good => bands.good.points,
      DayBand.poor => bands.poorPoints,
      DayBand.unmeasured => 0,
    };
    if (cap == null) return raw;
    return raw > cap ? cap : raw;
  }

  /// ◎ になる上限（分）。「◎まで あと N分の余裕」の表示に使う。
  static int greatLimit(int usualMinutes, DailyBands bands) =>
      bands.great.limitFor(usualMinutes);

  /// ○ になる上限（分）。
  static int goodLimit(int usualMinutes, DailyBands bands) =>
      bands.good.limitFor(usualMinutes);
}

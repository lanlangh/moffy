import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/usage/day_band.dart';
import '../../../../core/usage/usage_models.dart';
import '../../../../core/widgets/common_widgets.dart';
import '../../../../core/widgets/state_views.dart';
import '../../domain/home_state.dart';

/// 「きのうの結果」＋「きょうのペース」カード（0018 / docs/design/EGG_PACING_DESIGN.md §4-5）。
///
/// 以前の「今日のSNS削減（分×倍率のpt）」に代わるもの。
///   * きのうの結果 … サーバー確定の評価（◎/○/△/計れなかった）と卵に入った pt。
///   * きょうのペース … いまの利用分と、◎/○ のラインまでの余裕（端末の暫定）。
/// 権限なし / 対象アプリ未選択のフォールバックは従来どおり先頭で出す。
class DailyResultCard extends StatelessWidget {
  const DailyResultCard({
    super.key,
    required this.state,
    required this.onRequestPermission,
    this.hasAppSelection = true,
    this.onPickApps,
  });

  final HomeState state;
  final VoidCallback onRequestPermission;

  /// 対象アプリ（iOS の「見守るアプリ」）が選ばれているか。
  /// 選択という概念が無い Android 等は常に true。
  final bool hasAppSelection;

  /// 対象アプリを選び直す（OS のピッカーを開く）。iOS 以外では null。
  final VoidCallback? onPickApps;

  @override
  Widget build(BuildContext context) {
    // 権限なし: このカードのみフォールバック（卵/通貨は通常表示 / §5-1）。
    //
    // 【5.1.1(iv)】ここもボタンを押すと OS の権限要求が出る導線なので、
    // アプリ側が「許可」を促す語を使わない（Apple 指定は Continue/Next 相当）。
    //
    // 【B-4 / B-5 / B-9 第三者レビュー指摘】以前はここに OS 分岐が無く、
    //   * iOS のユーザーにも Android 専用の設定名「使用状況へのアクセス」を出していた
    //     （iOS にその設定は存在しない）
    //   * 恒久拒否（iOS で一度拒否すると OS は二度と確認画面を出さない）でも
    //     ボタンを出しており、**押しても何も起きない**状態だった
    // ＝「続ける」と書いてあるのに前進しない。押せないボタンは出荷しない。
    if (state.isPermissionMissing) {
      final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
      final permanent =
          state.permission == UsagePermissionStatus.permanentlyDenied;
      return AppCard(
        child: ErrorView(
          message: permanent
              ? (isIOS
                  ? '計測を再開するには、端末の「設定 > スクリーンタイム」で'
                      'Moffy を有効にしてください。'
                  : '計測を再開するには、端末の設定の「使用状況へのアクセス」で'
                      'Moffy を有効にしてください。')
              : (isIOS
                  ? '時間を計るにはスクリーンタイムの利用が必要です。'
                      '有効にすると、毎日の結果でたまごが育ちます。'
                  : '時間を計るには「使用状況へのアクセス」が必要です。'
                      '有効にすると、毎日の結果でたまごが育ちます。'),
          // 恒久拒否では OS 要求が出ないので、ボタン自体を出さない
          // （ErrorView は onRetry=null でボタンを描画しない）。案内文だけ残す。
          retryLabel: isIOS ? '続ける' : '設定を開く',
          onRetry: permanent ? null : onRequestPermission,
          compact: true,
        ),
      );
    }

    // 【2026-10-05 追加】権限はあるのに「見守るアプリ」が未選択（iOS）。
    //
    // iOS は許可だけでは計測できない。FamilyActivityPicker で対象を選ばないと
    // DeviceActivity が何も監視せず **永久に0分** になる。0018 からはこの状態の日は
    // 「計測なし」として 0pt（幻の30ptは出ない）なので、選ばないとたまごが進まない。
    // メニューの「対象アプリ」を探させず、ここから直接ピッカーを開く。
    if (!hasAppSelection && onPickApps != null) {
      return AppCard(
        child: ErrorView(
          message: '見守るアプリが選ばれていません。'
              '選ぶと、その日の結果が ◎○△ で評価されて、たまごが進みます。',
          retryLabel: 'アプリを選ぶ',
          onRetry: onPickApps,
          compact: true,
        ),
      );
    }

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _YesterdaySection(state: state),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpace.md),
            child: Divider(height: 1, color: AppColors.divider),
          ),
          _TodaySection(state: state),
        ],
      ),
    );
  }
}

/// 評価の色（面と記号で区別する。色だけに頼らない / §4-6）。
Color bandColor(DayBand band) => switch (band) {
      DayBand.great => AppColors.successDeep,
      DayBand.good => AppColors.primaryDeep,
      DayBand.poor => AppColors.warn,
      DayBand.unmeasured => AppColors.textSecondary,
    };

class _YesterdaySection extends StatelessWidget {
  const _YesterdaySection({required this.state});

  final HomeState state;

  @override
  Widget build(BuildContext context) {
    final y = state.yesterday;
    final String headline;
    final String? sub;
    DayBand? band;
    int? points;

    if (state.isFirstDay) {
      headline = 'きょうが1日目';
      sub = 'あしたから「きのうの結果」が出ます。きょうはボーナスで育ちます。';
    } else if (y == null) {
      headline = 'きのうは開かなかったので、計れませんでした';
      sub = '開いた日の分だけ、たまごが進みます。きょうは開いているので大丈夫。';
    } else if (!y.finalized) {
      headline = 'きのうの結果を計算しています…';
      sub = '少し待つか、下に引っぱって更新してください。';
    } else if (!y.measured) {
      band = DayBand.unmeasured;
      headline = 'きのうは計れなかった日';
      sub = 'いまは計れる状態です。きょうの分から、たまごが進みます。';
    } else {
      band = y.band;
      points = y.points;
      headline = '${y.band.label} +${y.points}pt';
      sub = switch (y.band) {
        DayBand.great => 'ふだんよりしっかり離れられた日。たまごが大きく進みました。',
        DayBand.good => 'ふだんより減らせた日。たまごが進みました。',
        DayBand.poor => 'それでも、たまごは少し進んだよ。',
        DayBand.unmeasured => null,
      };
    }

    return Semantics(
      container: true,
      label: 'きのうの結果: $headline',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('きのうの結果', style: AppType.bodyStrong),
          const SizedBox(height: AppSpace.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (band != null) ...[
                _BandMark(band: band),
                const SizedBox(width: AppSpace.md),
              ],
              Expanded(
                child: points != null && band != null
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Flexible(
                            child: Text(
                              band.label,
                              style: AppType.title.copyWith(color: bandColor(band)),
                            ),
                          ),
                          const SizedBox(width: AppSpace.sm),
                          Text(
                            '+$points',
                            style:
                                AppType.numHero.copyWith(color: bandColor(band)),
                          ),
                          Text('pt', style: AppType.numLabel),
                        ],
                      )
                    : Text(headline, style: AppType.title),
              ),
            ],
          ),
          if (sub != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(sub, style: AppType.caption),
          ],
        ],
      ),
    );
  }
}

class _TodaySection extends StatelessWidget {
  const _TodaySection({required this.state});

  final HomeState state;

  @override
  Widget build(BuildContext context) {
    final usage = state.todayUsage;
    final band = state.todayBand;
    final minutes = state.todayMinutes;

    final String headline;
    final String sub;
    if (usage == null || band == null) {
      headline = 'いまの利用時間を取得できませんでした';
      sub = state.usageErrorMessage ?? '下に引っぱって更新してください。';
    } else {
      headline = 'いま $minutes分';
      sub = switch (band) {
        DayBand.great =>
          '◎ペース。◎のまま終えるには あと${state.greatLimit - minutes}分の余裕。',
        DayBand.good =>
          '○ペース。○のまま終えるには あと${state.goodLimit - minutes}分の余裕。',
        DayBand.poor => '△ペース。ふだんと同じくらい。それでも開けば少し進みます。',
        DayBand.unmeasured => '',
      };
    }

    return Semantics(
      container: true,
      label: 'きょうのペース: $headline。$sub',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('きょうのペース', style: AppType.bodyStrong),
              Text(
                'ふだん ${_minutesLabel(state.usualMinutes)}',
                style: AppType.caption,
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          Row(
            children: [
              if (band != null) ...[
                _BandMark(band: band),
                const SizedBox(width: AppSpace.md),
              ],
              Expanded(
                child: Text(
                  headline,
                  style: band == null
                      ? AppType.body
                      : AppType.title.copyWith(color: bandColor(band)),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(sub, style: AppType.caption),
        ],
      ),
    );
  }

  String _minutesLabel(int m) {
    if (m < 60) return '$m分';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '$h時間' : '$h時間$r分';
  }
}

/// ◎/○/△ の記号を面の上に置く（色だけに頼らない）。
class _BandMark extends StatelessWidget {
  const _BandMark({required this.band});

  final DayBand band;

  @override
  Widget build(BuildContext context) {
    final color = bandColor(band);
    return Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Text(
        band.mark,
        style: AppType.title.copyWith(color: color),
      ),
    );
  }
}

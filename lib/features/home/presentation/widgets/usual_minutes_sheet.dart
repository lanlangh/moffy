import 'package:flutter/material.dart';

import '../../../../core/theme/tokens.dart';
import '../../../../core/widgets/common_widgets.dart';

/// 「ふだんのSNS時間」の選択UI（0018 / docs/design/EGG_PACING_DESIGN.md §2-1）。
///
/// オンボーディングの1ページと、既存ユーザー向けの1回だけのシートで共用する。
/// 選択肢は `app_config.usual_minutes_choices`（iOS のしきい値と同じ刻み）。
/// 評価（◎/○/△）の基準 R になるので、「だいたいでOK」と添えて迷わせない。

/// 選択肢の表示名（30→「30分くらいまで」 / 60→「1時間くらい」 / 最大→「5時間以上」）。
String usualMinutesLabel(int minutes, {required bool isLargest}) {
  if (isLargest && minutes >= 60) return '${minutes ~/ 60}時間以上';
  if (minutes < 60) return '$minutes分くらいまで';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h時間くらい' : '$h時間$m分くらい';
}

/// 設定アプリで確かめる方法（両OS）。
const String usualMinutesHint =
    'iPhoneは「設定 > スクリーンタイム」、Androidは「Digital Wellbeing」で見られます。だいたいでOK。';

/// 選択肢の一覧（縦に並ぶ大きなボタン）。
class UsualMinutesChooser extends StatelessWidget {
  const UsualMinutesChooser({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelect,
  });

  final List<int> choices;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final largest = choices.isEmpty ? 0 : choices.reduce((a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in choices)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: _ChoiceTile(
              label: usualMinutesLabel(m, isLargest: m == largest),
              selected: selected == m,
              onTap: () => onSelect(m),
            ),
          ),
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected ? AppColors.primarySoft : AppColors.surface,
        borderRadius: AppRadius.lgR,
        child: InkWell(
          borderRadius: AppRadius.lgR,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.lg,
              vertical: AppSpace.md,
            ),
            decoration: BoxDecoration(
              borderRadius: AppRadius.lgR,
              border: Border.all(
                color: selected ? AppColors.primary : AppColors.divider,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? AppColors.primary : AppColors.textDisabled,
                ),
                const SizedBox(width: AppSpace.md),
                Expanded(child: Text(label, style: AppType.bodyStrong)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 既存ユーザー向けの1回だけのシート（アプリ更新後の最初の起動 / §2-1）。
///
/// [onDone] は選んだ値（スキップ・閉じた場合は null）で**必ず1回**呼ばれる。
/// 「わからない・あとで」はスキップ＝既定の 120 分で評価される（責めない・止めない）。
Future<void> showUsualMinutesSheet(
  BuildContext context, {
  required List<int> choices,
  required Future<void> Function(int? minutes) onDone,
}) async {
  var done = false;
  Future<void> finish(int? minutes) async {
    if (done) return;
    done = true;
    await onDone(minutes);
  }

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _UsualMinutesSheetBody(
      choices: choices,
      onPick: (m) async {
        await finish(m);
      },
      onSkip: () async {
        await finish(null);
      },
    ),
  );
  // 枠外タップ・戻る操作で閉じた場合もスキップとして1回だけ記録する。
  await finish(null);
}

class _UsualMinutesSheetBody extends StatefulWidget {
  const _UsualMinutesSheetBody({
    required this.choices,
    required this.onPick,
    required this.onSkip,
  });

  final List<int> choices;
  final Future<void> Function(int minutes) onPick;
  final Future<void> Function() onSkip;

  @override
  State<_UsualMinutesSheetBody> createState() => _UsualMinutesSheetBodyState();
}

class _UsualMinutesSheetBodyState extends State<_UsualMinutesSheetBody> {
  int? _selected;
  bool _busy = false;

  Future<void> _submit() async {
    final m = _selected;
    if (m == null || _busy) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    await widget.onPick(m);
    if (mounted) navigator.pop();
  }

  Future<void> _skip() async {
    if (_busy) return;
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    await widget.onSkip();
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      padding: EdgeInsets.fromLTRB(
        AppSpace.xl,
        AppSpace.xl,
        AppSpace.xl,
        AppSpace.xl + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('ふだん、SNSをどれくらい使っていますか？', style: AppType.title),
            const SizedBox(height: AppSpace.sm),
            Text(
              'これを「ふだん」として、毎日どれだけ離れられたかを見ます。$usualMinutesHint',
              style: AppType.caption,
            ),
            const SizedBox(height: AppSpace.lg),
            UsualMinutesChooser(
              choices: widget.choices,
              selected: _selected,
              onSelect: (m) => setState(() => _selected = m),
            ),
            const SizedBox(height: AppSpace.md),
            PrimaryButton(
              label: 'これで決める',
              onPressed: _selected == null || _busy ? null : _submit,
            ),
            const SizedBox(height: AppSpace.xs),
            TextButton(
              onPressed: _busy ? null : _skip,
              child: const Text('わからない・あとで'),
            ),
          ],
        ),
      ),
    );
  }
}

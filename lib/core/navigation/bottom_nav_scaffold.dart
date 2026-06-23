import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'app_tab.dart';
import 'tab_icons.dart';

/// ボトムナビ5タブのシェル（DESIGN_SYSTEM §7 BottomNav）。
///
/// アクティブ = 塗りアイコン + warm.orange + ラベル。
/// 非アクティブ = ライン + ink.600（ラベルなし）。
/// 高さ 64 + セーフエリア、タブアイコン 26（AppSpace）。
/// GoRouter の StatefulShellRoute から [child]（現在のブランチ）と
/// [currentIndex] / [onTap] を受け取り、各タブの状態を保持する。
class BottomNavScaffold extends StatelessWidget {
  const BottomNavScaffold({
    super.key,
    required this.child,
    required this.currentIndex,
    required this.onTap,
  });

  /// 現在のタブのナビゲータ（StatefulNavigationShell）。
  final Widget child;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: child,
      bottomNavigationBar: _MoffyBottomNav(
        currentIndex: currentIndex,
        onTap: onTap,
      ),
    );
  }
}

class _MoffyBottomNav extends StatelessWidget {
  const _MoffyBottomNav({required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: AppElevation.card,
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: AppSpace.bottomNavHeight,
          child: Row(
            children: [
              for (var i = 0; i < AppTab.values.length; i++)
                Expanded(
                  child: _TabButton(
                    tab: AppTab.values[i],
                    active: i == currentIndex,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.active,
    required this.onTap,
  });

  final AppTab tab;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.primary : AppColors.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.pillR,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 塗り（アクティブ）/ ライン（非アクティブ）の2状態（DESIGN_SYSTEM §6）。
            TabIcon(
              glyph: tab.glyph,
              color: color,
              filled: active,
              size: AppSpace.tabIcon,
            ),
            // ラベルはアクティブ時のみ（非アクティブはアイコンのみ）。
            if (active) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                tab.label,
                style: AppType.caption.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

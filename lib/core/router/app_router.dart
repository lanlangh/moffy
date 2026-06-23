import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/collection/presentation/collection_screen.dart';
import '../../features/eggs/presentation/eggs_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/menu/presentation/menu_screen.dart';
import '../../features/onboarding/data/onboarding_repository.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/paywall/presentation/paywall_screen.dart';
import '../../features/profile/presentation/account_link_screen.dart';
import '../../features/profile/presentation/delete_account_screen.dart';
import '../../features/profile/presentation/notification_settings_screen.dart';
import '../../features/quests/presentation/quests_screen.dart';
import '../navigation/app_tab.dart';
import '../navigation/bottom_nav_scaffold.dart';

/// ルーティング（ARCHITECTURE §1-1 / go_router）。
///
/// 第2aパス: ボトムナビ5タブを [StatefulShellRoute] でシェル化し、各タブの状態を
/// 保持する（タブ切替で再構築しない）。オンボーディングはシェル外の独立ルートにし、
/// 初回未完了なら redirect でオンボへ流す。
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppTab.home.path,
    // 初回起動はオンボーディングへ（完了フラグはローカル / SCREEN_FLOWS §1）。
    redirect: (context, state) {
      final completedAsync = ref.read(onboardingCompletedProvider);
      // 取得前（loading）は判定保留（リダイレクトしない）。
      final completed = completedAsync.maybeWhen(
        data: (v) => v,
        orElse: () => true, // 取得不能時はオンボを強制しない（既存ユーザー保護）
      );
      final goingToOnboarding = state.matchedLocation == OnboardingScreen.routePath;
      if (!completed && !goingToOnboarding) {
        return OnboardingScreen.routePath;
      }
      if (completed && goingToOnboarding) {
        return AppTab.home.path;
      }
      return null;
    },
    routes: [
      GoRoute(
        path: OnboardingScreen.routePath,
        name: OnboardingScreen.routeName,
        builder: (context, state) => const OnboardingScreen(),
      ),
      // 5タブのシェル（各タブが独立した Navigator を持ち状態を保持）。
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return BottomNavScaffold(
            currentIndex: navigationShell.currentIndex,
            onTap: (i) => navigationShell.goBranch(
              i,
              // 同じタブ再タップでルートへ戻す。
              initialLocation: i == navigationShell.currentIndex,
            ),
            child: navigationShell,
          );
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppTab.home.path,
                name: HomeScreen.routeName,
                builder: (context, state) => const HomeScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppTab.eggs.path,
                name: EggsScreen.routeName,
                builder: (context, state) => const EggsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppTab.collection.path,
                name: CollectionScreen.routeName,
                builder: (context, state) => const CollectionScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppTab.quests.path,
                name: QuestsScreen.routeName,
                builder: (context, state) => const QuestsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppTab.menu.path,
                name: MenuScreen.routeName,
                builder: (context, state) => const MenuScreen(),
              ),
            ],
          ),
        ],
      ),
      // メニュー配下の子画面（シェル外のフルスクリーン / SCREEN_FLOWS §6）。
      // context.push で遷移し、ボトムナビを覆って戻る導線を持つ。
      GoRoute(
        path: AccountLinkScreen.routePath,
        name: AccountLinkScreen.routeName,
        builder: (context, state) => const AccountLinkScreen(),
      ),
      GoRoute(
        path: NotificationSettingsScreen.routePath,
        name: NotificationSettingsScreen.routeName,
        builder: (context, state) => const NotificationSettingsScreen(),
      ),
      GoRoute(
        path: DeleteAccountScreen.routePath,
        name: DeleteAccountScreen.routeName,
        builder: (context, state) => const DeleteAccountScreen(),
      ),
      // ペイウォール（プレミアム購入 / RevenueCat）。メニュー・保管枠満杯から push。
      GoRoute(
        path: PaywallScreen.routePath,
        name: PaywallScreen.routeName,
        builder: (context, state) => const PaywallScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text('画面が見つかりません: ${state.uri}')),
    ),
  );
});

import 'package:flutter/material.dart';

import '../screens/player_page.dart';
import 'navigation_guard.dart';

/// 播放页统一转场：**底部滑入 / 滑出**（打开时上滑进入、关闭时下滑退出）。
///
/// 所有入口（首页私人 FM、底部常驻播放条、搜索结果）都统一走本路由，
/// 保证打开与关闭动画一致，避免关闭时「生硬直落」的观感。
Route<void> playerPageRoute() {
  return PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, _, _) => const PlayerPage(),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 1),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

/// 打开播放页（统一转场 + 防重复打开）。
///
/// 返回的 Future 在播放页关闭后完成；重复调用会被 [NavigationGuard] 拦截。
Future<void> openPlayerPage(BuildContext context) {
  if (NavigationGuard.isPlayerPageOpen) return Future<void>.value();
  NavigationGuard.isPlayerPageOpen = true;
  return Navigator.of(context)
      .push(playerPageRoute())
      .whenComplete(() => NavigationGuard.isPlayerPageOpen = false);
}

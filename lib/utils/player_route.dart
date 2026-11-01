import 'package:flutter/material.dart';

import '../screens/player_page.dart';
import 'navigation_guard.dart';

/// 播放页统一入口。
///
/// 曾经这里用 `PageRouteBuilder` 手写「底部滑入」转场，代价是**绕过了
/// `PageTransitionsTheme`**：系统返回手势收不到 `handleStartBackGesture`，
/// 于是播放页成了全 App 唯一没有预测性返回（返回到一半可以松手取消、
/// 背后页面跟着缩放）的页面。
/// 现在改用 `MaterialPageRoute`，与首页、歌单页、设置页完全同一套转场，
/// 预测性返回由 `PredictiveBackPageTransitionsBuilder` 统一负责。
Route<void> playerPageRoute() {
  return MaterialPageRoute<void>(
    builder: (_) => const PlayerPage(),
    settings: const RouteSettings(name: 'player'),
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

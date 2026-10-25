import 'package:flutter/material.dart';

import '../utils/responsive.dart';

/// 导航目的地。
class NavDestination {
  const NavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 通用外壳：按断点在「左侧边栏 + 底部播放条（横屏大屏）」与
/// 「底部悬浮胶囊栏（竖屏 / 手机）」之间切换，并把页面内容夹到内容上限居中。
///
/// - 竖屏（B1 手机竖屏 / B3 平板竖屏）与手机横屏（B2）：body 铺满 +
///   [bottomBar] 悬浮于底部居中（**与上游原版一致**）。
/// - 横屏大屏（B4 平板横屏 / B5 超宽屏）：参照 PC 版布局 —— 左侧边栏
///   （Logo + 导航）+ 右侧内容区 + **底部全宽常驻播放条** [playerBar]。
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.bottomBar,
    this.playerBar,
    this.backgroundColor = const Color(0xFFF1F2F4),
    this.extendBody = true,
  });

  /// 当前选中项
  final int currentIndex;

  /// 选中回调
  final ValueChanged<int> onDestinationSelected;

  /// 导航项
  final List<NavDestination> destinations;

  /// 页面内容
  final Widget body;

  /// 竖屏 / 手机横屏下的底部自定义栏（悬浮胶囊栏）；PC 形态忽略
  final Widget? bottomBar;

  /// 横屏大屏（B4/B5）下的底部常驻播放条（全宽）；竖屏形态忽略
  final Widget? playerBar;

  final Color backgroundColor;
  final bool extendBody;

  /// 侧边栏宽度（平板/横屏，参照 PC 版 240px 收窄以适配平板）
  static const double sidebarWidth = 200;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final bp = Responsive.of(size);

    // 横屏 / 大屏**不使用 PC 侧边栏**：
    // 概念版是 Android 应用，横屏沿用与手机一致的底部胶囊导航，
    // 只把内容区限宽居中，避免卡片在宽屏上被拉变形。
    if (Responsive.showRail(bp)) {
      final wideInset = MediaQuery.of(context).padding.bottom;
      return Scaffold(
        backgroundColor: backgroundColor,
        extendBody: extendBody,
        body: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: body,
                ),
              ),
            ),
            if (bottomBar != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 10 + wideInset,
                child: Center(child: bottomBar!),
              ),
          ],
        ),
      );
    }

    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Scaffold(
      backgroundColor: backgroundColor,
      extendBody: extendBody,
      body: Stack(
        children: [
          Positioned.fill(child: body),
          if (bottomBar != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 10 + bottomInset,
              child: Center(child: bottomBar!),
            ),
        ],
      ),
    );
  }
}

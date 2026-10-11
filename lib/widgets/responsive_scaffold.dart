import 'package:flutter/material.dart';

import '../utils/responsive.dart';

/// 导航目的地（用于平板形态的 NavigationRail）。
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

/// 通用外壳：按断点在「左侧 NavigationRail（平板）」与
/// 「底部悬浮自定义栏（手机）」之间切换，并把页面内容夹到内容上限居中。
///
/// - 手机形态（B1/B2）：body 铺满 + [bottomBar] 悬浮于底部居中，
///   与改造前布局一致（竖屏基线不回归）。
/// - 平板形态（B3/B4/B5）：左侧 NavigationRail + 右侧内容区。
class ResponsiveScaffold extends StatelessWidget {
  const ResponsiveScaffold({
    super.key,
    required this.currentIndex,
    required this.onDestinationSelected,
    required this.destinations,
    required this.body,
    this.bottomBar,
    this.backgroundColor = const Color(0xFFF1F2F4),
    this.extendBody = true,
  });

  /// 当前选中项
  final int currentIndex;

  /// 选中回调
  final ValueChanged<int> onDestinationSelected;

  /// 导航项（平板形态使用）
  final List<NavDestination> destinations;

  /// 页面内容
  final Widget body;

  /// 手机形态下的底部自定义栏（悬浮胶囊栏）；平板形态忽略
  final Widget? bottomBar;

  final Color backgroundColor;
  final bool extendBody;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final bp = Responsive.of(size);

    if (Responsive.showRail(bp)) {
      return Scaffold(
        backgroundColor: backgroundColor,
        body: Row(
          children: [
            SafeArea(
              child: NavigationRail(
                selectedIndex: currentIndex,
                onDestinationSelected: onDestinationSelected,
                minWidth: Responsive.railMinWidth,
                labelType: NavigationRailLabelType.all,
                groupAlignment: 0,
                destinations: [
                  for (final d in destinations)
                    NavigationRailDestination(
                      icon: Icon(d.icon),
                      selectedIcon: Icon(d.selectedIcon),
                      label: Text(d.label),
                    ),
                ],
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: body),
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

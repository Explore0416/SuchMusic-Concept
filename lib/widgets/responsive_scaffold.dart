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

    if (Responsive.showRail(bp)) {
      return Scaffold(
        backgroundColor: backgroundColor,
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: sidebarWidth,
                    child: SafeArea(
                      right: false,
                      child: _Sidebar(
                        currentIndex: currentIndex,
                        destinations: destinations,
                        onDestinationSelected: onDestinationSelected,
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(child: body),
                ],
              ),
            ),
            // PC 风格：底部全宽常驻播放条
            if (playerBar != null)
              SafeArea(top: false, left: false, right: false, child: playerBar!),
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

/// PC 风格侧边栏：顶部 Logo 区 + 导航项（图标+文字同行、圆角选中态）。
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.currentIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  final int currentIndex;
  final List<NavDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  static const Color _accent = Color(0xFF2F84FE);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo 区
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/images/SuchMusic@1x.png',
                    width: 32,
                    height: 32,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox(
                      width: 32,
                      height: 32,
                      child: Icon(Icons.music_note, color: _accent),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'SuchMusic概念版',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // 导航项
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              itemCount: destinations.length,
              itemBuilder: (context, i) {
                final d = destinations[i];
                final selected = i == currentIndex;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Material(
                    color: selected
                        ? _accent.withValues(alpha: 0.10)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => onDestinationSelected(i),
                      child: SizedBox(
                        height: 46,
                        child: Row(
                          children: [
                            const SizedBox(width: 14),
                            Icon(
                              selected ? d.selectedIcon : d.icon,
                              size: 22,
                              color: selected ? _accent : const Color(0xFF838383),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                d.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight:
                                      selected ? FontWeight.w600 : FontWeight.w400,
                                  color:
                                      selected ? _accent : const Color(0xFF3A3A3A),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

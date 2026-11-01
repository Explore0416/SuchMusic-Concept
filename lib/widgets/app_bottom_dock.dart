import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/responsive.dart';

/// 底部导航项（一级入口，4 项）。
class AppDockItem {
  const AppDockItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// 底部导航坞：白色浮层 + 发丝边 + 柔和投影。
///
/// 4 个一级入口（首页 / 本地 / 歌单 / 我的），选中态用墨色图标 + 600 字重，
/// 不再用高饱和色块堆叠。宽度沿用 [Responsive.bottomBarWidth]，窄屏不贴边。
class AppBottomDock extends StatelessWidget {
  const AppBottomDock({
    super.key,
    required this.index,
    required this.onSelect,
    this.items = defaultItems,
  });

  static const defaultItems = <AppDockItem>[
    AppDockItem(
      icon: Icons.home_outlined,
      activeIcon: Icons.home_rounded,
      label: '首页',
    ),
    AppDockItem(
      icon: Icons.album_outlined,
      activeIcon: Icons.album_rounded,
      label: '本地',
    ),
    AppDockItem(
      icon: Icons.queue_music_outlined,
      activeIcon: Icons.queue_music_rounded,
      label: '歌单',
    ),
    AppDockItem(
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      label: '我的',
    ),
  ];

  final int index;
  final ValueChanged<int> onSelect;
  final List<AppDockItem> items;

  @override
  Widget build(BuildContext context) {
    final width = Responsive.bottomBarWidth(MediaQuery.sizeOf(context));
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: AppLayout.dockMargin,
        right: AppLayout.dockMargin,
        bottom: 8 + bottom,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.hero),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            width: width,
            height: AppLayout.dockHeight,
            decoration: BoxDecoration(
              color: AppColors.surface.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(AppRadius.hero),
              border: Border.all(color: AppColors.hairline, width: 0.7),
              boxShadow: AppShadow.dock,
            ),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _DockTab(
                      item: items[i],
                      selected: i == index,
                      onTap: () => onSelect(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DockTab extends StatelessWidget {
  const _DockTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final AppDockItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.ink : AppColors.inkTertiary;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: SizedBox(
          height: AppLayout.dockHeight,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? item.activeIcon : item.icon,
                size: 22,
                color: color,
              ),
              const SizedBox(height: 3),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.1,
                  letterSpacing: 0.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 悬浮迷你播放卡：封面 + 歌名/歌手 + 播放暂停，底部一条 2px 进度。
///
/// 整卡点击进播放页；左右滑动切歌；无歌曲时由宿主不渲染本组件。
class MiniPlayerCard extends StatelessWidget {
  const MiniPlayerCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.isPlaying,
    required this.progress,
    required this.onTap,
    required this.onToggle,
    this.onSwipeNext,
    this.onSwipePrevious,
  });

  final String title;
  final String subtitle;
  final Widget cover;
  final bool isPlaying;

  /// 0 到 1
  final double progress;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback? onSwipeNext;
  final VoidCallback? onSwipePrevious;

  @override
  Widget build(BuildContext context) {
    final width = Responsive.bottomBarWidth(MediaQuery.sizeOf(context));
    return Padding(
      padding: const EdgeInsets.only(
        left: AppLayout.dockMargin,
        right: AppLayout.dockMargin,
        bottom: AppLayout.dockGap,
      ),
      child: GestureDetector(
        onTap: onTap,
        onHorizontalDragEnd: (details) {
          final v = details.primaryVelocity ?? 0;
          if (v < -220) {
            onSwipeNext?.call();
          } else if (v > 220) {
            onSwipePrevious?.call();
          }
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              width: width,
              height: AppLayout.miniPlayerHeight,
              decoration: BoxDecoration(
                color: AppColors.surface.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(color: AppColors.hairline, width: 0.7),
                boxShadow: AppShadow.card,
              ),
              child: Stack(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 8),
                      // 封面与卡片同心圆角：外层 20 - 内距 8 = 12
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 44,
                          height: 44,
                          color: AppColors.surfaceMuted,
                          child: cover,
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.body.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.1,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.caption.copyWith(
                                color: AppColors.inkTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // 播放键是全卡唯一的高对比元素：墨色实心圆，
                      // 视线有落点，比一个描边图标更像「正在播放」
                      SizedBox(
                        width: 44,
                        height: 44,
                        child: Center(
                          child: Material(
                            color: AppColors.ink,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: onToggle,
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: Icon(
                                  isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 21,
                                  color: AppColors.surface,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ),
                  // 进度线贴卡片底沿：既是进度，也把「播放区 / 导航区」
                  // 在视觉上明确分开，避免线穿过封面。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: 2,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceMuted,
                        borderRadius: BorderRadius.circular(2),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: progress.clamp(0.0, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.brand,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽屏侧栏底部的当前播放卡（与迷你播放卡同一视觉语言）。
class SideNowPlayingCard extends StatelessWidget {
  const SideNowPlayingCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.isPlaying,
    required this.progress,
    required this.onTap,
    required this.onToggle,
  });

  final String title;
  final String subtitle;
  final Widget cover;
  final bool isPlaying;
  final double progress;
  final VoidCallback? onTap;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: AppColors.hairline, width: 0.7),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card - 0.7),
        child: Stack(
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox(width: 40, height: 40, child: cover),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.body.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.caption.copyWith(
                                color: AppColors.inkTertiary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton(
                          onPressed: onToggle,
                          padding: EdgeInsets.zero,
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 22,
                            color: AppColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                  valueColor: const AlwaysStoppedAnimation(AppColors.brand),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

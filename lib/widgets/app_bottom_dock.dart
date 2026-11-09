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

/// 播放控制区的通用尺寸（迷你播放卡与宽屏侧栏播放卡共用，保证同一种视觉语言）。
abstract final class _PlayerMetrics {
  /// 触控热区下限：低于这个值手指点不中
  static const double hitTarget = 44;

  /// 封面边长
  static const double coverSize = 48;

  /// 封面内圆角：外层 20 − 内距 6 = 14，保持同心
  static const double coverRadius = AppRadius.card - 6;

  /// 窄于 360dp 隐藏封面，把宽度让给歌名
  static const double narrowBreakpoint = 360;

  /// 播放键视觉直径（外圈热区仍为 44）
  static const double playDiameter = 40;

  /// 进度条线宽
  static const double progressHeight = 3;

  /// 贴底进度条的左右内缩量。
  ///
  /// 卡片圆角 r = [AppRadius.card] 是一个 r×r 的正方形内切四分之一圆，
  /// 底沿上圆角弧线到卡片左右边缘的水平距离正好等于 r（直线段从 x = r 才开始）。
  /// 3px 的条如果一路铺到卡片边，方头就压在弧线上：1x 渲染时弧线被量化成
  /// 三级台阶，看上去像一条蓝线捅破了白色轮廓。左右各让出 r 之后，
  /// 整条（含 2px 圆头）都落在圆角的直线段内，任何 DPR 都不会碰到弧线。
  static const double progressCornerInset = AppRadius.card;

  /// 与卡片一致的圆角裁剪路径：只收底边两角，顶边保持直角。
  static const BorderRadius progressClipRadius = BorderRadius.vertical(
    bottom: Radius.circular(AppRadius.card),
  );
}

/// 迷你播放卡：封面 / 歌名+艺人 / 上一首 / 播放键 / 下一首，底部一条可拖的进度。
///
/// 交互分工：
/// - 整卡点击 → 进播放页；
/// - 左右滑动 → 切歌（与按钮并存，手势不是唯一入口）；
/// - 底部 20px 透明热区横向拖动 → seek，[onSeek] 未接入时拖拽无效。
///
/// [onSeek] / [onPrevious] / [onNext] 均为可空：宿主没接能力时控件置灰禁用，
/// 而不是让一张缺按钮的卡直接崩掉。
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
    this.onSeek,
    this.onPrevious,
    this.onNext,
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

  /// 拖动进度条时回调，值域 0–1；为空表示当前宿主不支持 seek
  final ValueChanged<double>? onSeek;

  /// 上一首 / 下一首；为空时按钮置灰禁用
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  final VoidCallback? onSwipeNext;
  final VoidCallback? onSwipePrevious;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = Responsive.bottomBarWidth(size);
    final showCover = size.width >= _PlayerMetrics.narrowBreakpoint;
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
                boxShadow: AppShadow.dock,
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Row(
                      children: [
                        // 窄屏不给封面留位：44 的按钮区已经吃掉大半宽度，
                        // 再放 48 的封面歌名就只剩两个字了
                        if (showCover) ...[
                          const SizedBox(width: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(
                              _PlayerMetrics.coverRadius,
                            ),
                            child: Container(
                              width: _PlayerMetrics.coverSize,
                              height: _PlayerMetrics.coverSize,
                              color: AppColors.surfaceMuted,
                              child: cover,
                            ),
                          ),
                          const SizedBox(width: AppSpace.md),
                        ] else
                          const SizedBox(width: AppSpace.lg),
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
                        PlayerTransportButton(
                          icon: Icons.skip_previous_rounded,
                          tooltip: '上一首',
                          onTap: onPrevious,
                        ),
                        // 播放键是全卡唯一的高对比元素：墨色实心圆，
                        // 视线有落点，比一个描边图标更像「正在播放」
                        PlayToggleButton(
                          isPlaying: isPlaying,
                          onTap: onToggle,
                          diameter: _PlayerMetrics.playDiameter,
                          iconSize: 21,
                          filled: true,
                        ),
                        PlayerTransportButton(
                          icon: Icons.skip_next_rounded,
                          tooltip: '下一首',
                          onTap: onNext,
                        ),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                  // 进度条贴卡片底沿：既是进度，也把「播放区 / 导航区」
                  // 在视觉上明确分开，避免线穿过封面。
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: AppLayout.miniPlayerProgressHitHeight,
                    child: PlaybackProgressScrubber(
                      progress: progress,
                      onSeek: onSeek,
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

/// 44×44 的次级播放控制键（上一首 / 下一首）。
///
/// [onTap] 为空时图标用 [AppColors.inkDisabled] 且不可点，调用方无需判空。
class PlayerTransportButton extends StatelessWidget {
  const PlayerTransportButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: _PlayerMetrics.hitTarget,
        height: _PlayerMetrics.hitTarget,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Icon(
              icon,
              size: 20,
              color: enabled ? AppColors.inkSecondary : AppColors.inkDisabled,
            ),
          ),
        ),
      ),
    );
  }
}

/// 播放 / 暂停键：墨色实心圆（迷你卡）或纯图标（侧栏卡），热区固定 44。
class PlayToggleButton extends StatelessWidget {
  const PlayToggleButton({
    super.key,
    required this.isPlaying,
    required this.onTap,
    this.diameter = 40,
    this.iconSize = 21,
    this.filled = true,
  });

  final bool isPlaying;
  final VoidCallback onTap;
  final double diameter;
  final double iconSize;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final label = isPlaying ? '暂停' : '播放';
    final icon = Icon(
      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
      size: iconSize,
      color: filled ? AppColors.surface : AppColors.ink,
    );
    return Tooltip(
      message: label,
      child: SizedBox(
        width: _PlayerMetrics.hitTarget,
        height: _PlayerMetrics.hitTarget,
        child: Center(
          child: Material(
            color: filled ? AppColors.ink : Colors.transparent,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: diameter,
                height: diameter,
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 进度条 + 20px 透明拖拽热区：条本身 3px，手指却有点得中的高度。
///
/// 热区始终满宽（[onSeek] 的比例分母就是卡片内宽，不随视觉内缩变化），
/// 内缩与圆角裁剪只作用在可见的那条 3px 轨道上。
///
/// [onSeek] 为空时只作为进度展示，不接管任何手势。
class PlaybackProgressScrubber extends StatelessWidget {
  const PlaybackProgressScrubber({
    super.key,
    required this.progress,
    this.onSeek,
  });

  /// 0 到 1
  final double progress;
  final ValueChanged<double>? onSeek;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth;
        void seekTo(double dx) {
          final callback = onSeek;
          if (callback == null || trackWidth <= 0) return;
          callback((dx / trackWidth).clamp(0.0, 1.0));
        }

        // 贴底进度条必须被卡片圆角裁切：外层 ClipRRect 的裁剪路径与卡片
        // 完全一致（同一条半径、同一块底沿 r×r 区域内切圆），保证任何位置
        // 都不会画到白色轮廓之外；同时左右内缩到圆角的直线段，避免 3px 方头
        // 被弧线斜切成「捅破卡片」的台阶。
        final bar = ClipRRect(
          borderRadius: _PlayerMetrics.progressClipRadius,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _PlayerMetrics.progressCornerInset,
              ),
              child: PlaybackProgressBar(progress: progress),
            ),
          ),
        );

        if (onSeek == null) return bar;

        return GestureDetector(
          // translucent：热区透明但仍然参与命中，同时不妨碍卡片的整卡点击
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (details) => seekTo(details.localPosition.dx),
          onHorizontalDragUpdate: (details) => seekTo(details.localPosition.dx),
          child: bar,
        );
      },
    );
  }
}

/// 单条进度轨：已播 [AppColors.brand]，轨道 [AppColors.surfaceMuted]。
class PlaybackProgressBar extends StatelessWidget {
  const PlaybackProgressBar({
    super.key,
    required this.progress,
    this.height = _PlayerMetrics.progressHeight,
  });

  /// 0 到 1
  final double progress;
  final double height;

  @override
  Widget build(BuildContext context) {
    const radius = Radius.circular(2);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: AppColors.surfaceMuted,
          borderRadius: BorderRadius.all(radius),
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: progress.clamp(0.0, 1.0),
          child: const DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.brand,
              borderRadius: BorderRadius.all(radius),
            ),
          ),
        ),
      ),
    );
  }
}

/// 宽屏侧栏底部的当前播放卡（与迷你播放卡同一视觉语言）。
///
/// 侧栏只有 224 宽，放不下一行五控件，于是把「封面 + 歌名」与
/// 「上一首 / 播放键 / 下一首」拆成上下两行，进度条同样贴在卡片底沿。
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
    this.onSeek,
    this.onPrevious,
    this.onNext,
  });

  final String title;
  final String subtitle;
  final Widget cover;
  final bool isPlaying;
  final double progress;
  final VoidCallback? onTap;
  final VoidCallback onToggle;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
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
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(
              height: _PlayerMetrics.hitTarget,
              child: Row(
                children: [
                  const SizedBox(width: 6),
                  PlayerTransportButton(
                    icon: Icons.skip_previous_rounded,
                    tooltip: '上一首',
                    onTap: onPrevious,
                  ),
                  const Spacer(),
                  PlayToggleButton(
                    isPlaying: isPlaying,
                    onTap: onToggle,
                    diameter: 32,
                    iconSize: 18,
                  ),
                  const Spacer(),
                  PlayerTransportButton(
                    icon: Icons.skip_next_rounded,
                    tooltip: '下一首',
                    onTap: onNext,
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
            SizedBox(
              height: AppLayout.miniPlayerProgressHitHeight,
              child: PlaybackProgressScrubber(
                progress: progress,
                onSeek: onSeek,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

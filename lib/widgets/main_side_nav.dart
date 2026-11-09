import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../theme/app_theme.dart';
import 'app_bottom_dock.dart';

/// 宽屏（平板 / 横屏）左侧导航栏。
///
/// 一级入口与窄屏底部导航坞完全一致（首页 / 本地 / 歌单 / 我的），
/// 只是物理形态随屏幕宽度切换；选中态用白色卡片 + 发丝边表达层级，
/// 不再用高饱和色块。底部保留「正在播放」卡，作为横屏回到播放页的入口。
class MainSideNav extends StatelessWidget {
  const MainSideNav({
    super.key,
    required this.index,
    required this.song,
    required this.isPlaying,
    required this.onSelect,
    required this.onTogglePlay,
    required this.onOpenPlayer,
    this.progress = 0,
    this.onSeek,
    this.onPrevious,
    this.onNext,
    this.cover,
    this.bottomPadding = 0,
  });

  static const double width = 224;

  /// 当前一级入口下标（0 首页 / 1 本地 / 2 歌单 / 3 我的）
  final int index;

  final SongModel? song;
  final bool isPlaying;
  final ValueChanged<int> onSelect;
  final VoidCallback onTogglePlay;
  final VoidCallback onOpenPlayer;

  /// 当前播放进度（0–1），驱动底部播放卡的进度条
  final double progress;

  /// 拖动进度条回调（为空时进度条只展示不可拖）
  final ValueChanged<double>? onSeek;

  /// 上一首 / 下一首（为空时按钮置灰）
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  final Widget? cover;
  final double bottomPadding;

  static const _items = <({IconData icon, IconData activeIcon, String label})>[
    (icon: Icons.home_outlined, activeIcon: Icons.home_rounded, label: '首页'),
    (icon: Icons.album_outlined, activeIcon: Icons.album_rounded, label: '本地'),
    (
      icon: Icons.queue_music_outlined,
      activeIcon: Icons.queue_music_rounded,
      label: '歌单',
    ),
    (
      icon: Icons.person_outline_rounded,
      activeIcon: Icons.person_rounded,
      label: '我的',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: AppColors.canvas,
      child: SafeArea(
        right: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 26, 20, 2),
              child: Text(
                'SuchMusic',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: AppColors.ink,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 20, 22),
              child: Text(
                '概念版',
                style: AppType.caption.copyWith(color: AppColors.inkTertiary),
              ),
            ),
            // 菜单区可滚动：横屏高度很小（如 360dp）时不会挤爆底部播放卡
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 2),
                children: [
                  for (var i = 0; i < _items.length; i++) _entry(i, _items[i]),
                ],
              ),
            ),
            if (song != null)
              Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: SideNowPlayingCard(
                  title: song!.name,
                  subtitle: song!.artist.isEmpty ? '未知歌手' : song!.artist,
                  cover: cover ?? const SizedBox.shrink(),
                  isPlaying: isPlaying,
                  progress: progress,
                  onTap: onOpenPlayer,
                  onToggle: onTogglePlay,
                  onSeek: onSeek,
                  onPrevious: onPrevious,
                  onNext: onNext,
                ),
              ),
            SizedBox(height: 12 + bottomPadding),
          ],
        ),
      ),
    );
  }

  Widget _entry(
    int i,
    ({IconData icon, IconData activeIcon, String label}) item,
  ) {
    final active = i == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: active ? AppColors.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.row),
        child: InkWell(
          onTap: () => onSelect(i),
          borderRadius: BorderRadius.circular(AppRadius.row),
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.row),
              border: Border.all(
                color: active ? AppColors.hairline : Colors.transparent,
                width: 0.7,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  active ? item.activeIcon : item.icon,
                  size: 22,
                  color: active ? AppColors.ink : AppColors.inkTertiary,
                ),
                const SizedBox(width: 12),
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active ? AppColors.ink : AppColors.inkSecondary,
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

import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../utils/home_tab.dart';

/// 宽屏（横屏 / 平板）左侧导航栏。
///
/// 纯展示组件：状态与回调全部由 MainShell 传入，便于单独做布局测试与截图。
/// 「首页 / 本地 / 歌单」与首页顶部标签共用 [HomeTab] 的值；
/// 底部是当前播放卡 —— 横屏去掉底部悬浮胶囊后，这里是回到播放页的入口。
class MainSideNav extends StatelessWidget {
  const MainSideNav({
    super.key,
    required this.tab,
    required this.profileSelected,
    required this.song,
    required this.isPlaying,
    required this.onSelectTab,
    required this.onSelectProfile,
    required this.onTogglePlay,
    required this.onOpenPlayer,
    this.cover,
    this.bottomPadding = 0,
  });

  static const double width = 220;

  /// 当前首页内部标签（[HomeTab.home] / [HomeTab.local] / [HomeTab.playlists]）
  final int tab;

  /// 当前是否停在「我的」
  final bool profileSelected;

  final SongModel? song;
  final bool isPlaying;

  final ValueChanged<int> onSelectTab;
  final VoidCallback onSelectProfile;
  final VoidCallback onTogglePlay;
  final VoidCallback onOpenPlayer;

  /// 当前歌曲封面（由宿主提供，未播放时为空 → 占位图标）
  final Widget? cover;

  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: Colors.white,
      child: SafeArea(
        right: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 26, 22, 4),
              child: Text(
                'SuchMusic',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  color: Colors.black87,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 0, 22, 18),
              child: Text(
                '概念版',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF9C9C9C)),
              ),
            ),
            // 菜单区可滚动：横屏高度很小（如 360dp）时不会挤爆底部播放卡
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 2),
                children: [
                  _entry(
                    icon: Icons.home_outlined,
                    activeIcon: Icons.home,
                    label: '首页',
                    active: !profileSelected && tab == HomeTab.home,
                    onTap: () => onSelectTab(HomeTab.home),
                  ),
                  _entry(
                    icon: Icons.album_outlined,
                    activeIcon: Icons.album,
                    label: '本地',
                    active: !profileSelected && tab == HomeTab.local,
                    onTap: () => onSelectTab(HomeTab.local),
                  ),
                  _entry(
                    icon: Icons.queue_music_outlined,
                    activeIcon: Icons.queue_music,
                    label: '歌单',
                    active: !profileSelected && tab == HomeTab.playlists,
                    onTap: () => onSelectTab(HomeTab.playlists),
                  ),
                  _entry(
                    icon: Icons.person_outline,
                    activeIcon: Icons.person,
                    label: '我的',
                    active: profileSelected,
                    onTap: onSelectProfile,
                  ),
                ],
              ),
            ),
            const Divider(
              height: 1,
              indent: 20,
              endIndent: 20,
              color: Color(0xFFEFEFEF),
            ),
            _buildNowPlaying(),
            SizedBox(height: 12 + bottomPadding),
          ],
        ),
      ),
    );
  }

  Widget _entry({
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFF1F2F4) : Colors.transparent,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Row(
          children: [
            Icon(
              active ? activeIcon : icon,
              size: 22,
              color: active ? Colors.black87 : const Color(0xFF8A8A8A),
            ),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? Colors.black87 : const Color(0xFF5A5A5A),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  /// 底部「正在播放」卡：点整卡进播放页，右侧按钮只切播放/暂停
  Widget _buildNowPlaying() {
    final s = song;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: s == null ? null : onOpenPlayer,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F6F8),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 40,
                  height: 40,
                  color: const Color(0xFFE8E8E8),
                  child: s == null
                      ? const Icon(
                          Icons.music_note,
                          size: 20,
                          color: Color(0xFFBDBDBD),
                        )
                      : cover,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s?.name ?? '暂无播放',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: s == null
                            ? const Color(0xFF9C9C9C)
                            : Colors.black87,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s?.artist ?? '选一首歌开始',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF9C9C9C),
                      ),
                    ),
                  ],
                ),
              ),
              if (s != null)
                SizedBox(
                  width: 34,
                  height: 34,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onTogglePlay,
                      child: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 22,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

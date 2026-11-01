import 'package:flutter/material.dart';

import '../services/user_library_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/design_dialog.dart';
import 'kugou_playlist_page.dart';
import 'song_picker_page.dart';
import 'user_playlist_detail_page.dart';

/// 「歌单」页：我喜欢的音乐 / 自建歌单 / 酷狗歌单。
///
/// 三块内容收在同一页，避免「歌单」和「酷狗歌单」两个入口各占一行。
/// 顶部大标题建立页面身份；「我喜欢的音乐」用一张主卡突出，其余按组排列。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.embedded = false});

  /// 兼容旧调用：嵌入形态不再需要单独的 Scaffold，页面始终自带标题。
  final bool embedded;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final UserLibraryService _lib = UserLibraryService.instance;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ValueListenableBuilder<int>(
        valueListenable: _lib.version,
        builder: (_, _, _) => ListView(
          padding: const EdgeInsets.only(
            bottom: AppLayout.bottomInsetWithPlayer,
          ),
          children: [
            AppPageHeader(
              title: '歌单',
              subtitle: '喜欢的歌与自建歌单都收在这里',
              trailing: AppIconButton(
                icon: Icons.add_rounded,
                filled: true,
                onTap: _createPlaylist,
                tooltip: '新建歌单',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: _buildLikedCard(),
            ),
            const SizedBox(height: AppSpace.xxl),
            AppSectionHeader(
              title: '我的歌单',
              actionLabel: _lib.playlists.isEmpty ? null : '新建',
              onAction: _lib.playlists.isEmpty ? null : _createPlaylist,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: _lib.playlists.isEmpty
                  ? _buildEmptyPlaylists()
                  : _buildPlaylistCard(),
            ),
            const SizedBox(height: AppSpace.xxl),
            const AppSectionHeader(title: '酷狗歌单'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              child: AppCard(
                child: AppListTile(
                  icon: Icons.cloud_outlined,
                  title: '查看酷狗歌单',
                  subtitle: '登录后可查看账号歌单，也可粘贴链接导入',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const KugouPlaylistPage(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xxxl),
          ],
        ),
      ),
    );
  }

  /// 我喜欢的音乐：单独一张主卡，用玫瑰色系与收藏语义绑定。
  Widget _buildLikedCard() {
    final count = _lib.likedSongs.length;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFE9EE), Color(0xFFFFF7F3)],
        ),
        border: Border.all(color: const Color(0xFFFBDDE4), width: 0.7),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _openLiked,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.favorite_rounded,
                    size: 24,
                    color: AppColors.rose,
                  ),
                ),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        '我喜欢的音乐',
                        style: TextStyle(
                          fontSize: 17,
                          height: 1.3,
                          fontWeight: FontWeight.w700,
                          color: AppColors.ink,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        count == 0 ? '播放时点爱心，收藏到这里' : '$count 首',
                        style: AppType.caption.copyWith(
                          color: const Color(0xFF9A6270),
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: Color(0xFFC99AA6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistCard() {
    final playlists = _lib.playlists;
    return AppCard(
      child: Column(
        children: [
          for (var i = 0; i < playlists.length; i++) ...[
            if (i > 0) const AppHairline(indent: 66),
            AppListTile(
              icon: Icons.queue_music_rounded,
              title: playlists[i].name,
              subtitle: '${playlists[i].songs.length} 首',
              onTap: () => _openPlaylist(playlists[i].id),
              trailing: const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.inkDisabled,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyPlaylists() {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        child: AppEmptyState(
          icon: Icons.queue_music_rounded,
          title: '还没有自建歌单',
          message: '把常听的歌整理成一张自己的歌单',
          actionLabel: '新建歌单',
          onAction: _createPlaylist,
          compact: true,
        ),
      ),
    );
  }

  void _openLiked() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const UserPlaylistDetailPage(playlistId: 'liked', likedMode: true),
      ),
    );
  }

  void _openPlaylist(String id) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => UserPlaylistDetailPage(playlistId: id)),
    );
  }

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null) return;
    final pl = await _lib.createPlaylist(name);
    if (!mounted) return;

    // 创建后直接问是否马上添加歌曲：省掉「再点一次添加」的往返
    final picked = await Navigator.push<List<dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => const SongPickerPage(title: '选择歌曲加入歌单'),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final added = await _lib.addSongsToPlaylist(pl.id, picked.cast());
    if (!mounted) return;
    DesignToast.show(context, added > 0 ? '已创建并添加 $added 首' : '歌单已创建');
  }
}

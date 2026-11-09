import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/user_library_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/app_ui.dart';
import '../widgets/design_dialog.dart';
import 'song_picker_page.dart';

/// 自建歌单详情：播放全部 / 多选添加 / 移除 / 重命名 / 删除。
class UserPlaylistDetailPage extends StatefulWidget {
  const UserPlaylistDetailPage({
    super.key,
    required this.playlistId,
    this.likedMode = false,
  });

  final String playlistId;

  /// true 时展示「我喜欢的音乐」（只允许移除，不允许改名 / 删除）。
  final bool likedMode;

  @override
  State<UserPlaylistDetailPage> createState() => _UserPlaylistDetailPageState();
}

class _UserPlaylistDetailPageState extends State<UserPlaylistDetailPage> {
  final UserLibraryService _lib = UserLibraryService.instance;

  List<SongModel> get _songs => widget.likedMode
      ? _lib.likedSongs
      : (_lib.playlists
                .where((p) => p.id == widget.playlistId)
                .firstOrNull
                ?.songs ??
            const <SongModel>[]);

  String get _title => widget.likedMode
      ? '我喜欢的音乐'
      : (_lib.playlists
                .where((p) => p.id == widget.playlistId)
                .firstOrNull
                ?.name ??
            '歌单');

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _lib.version,
      builder: (_, _, _) {
        final songs = _songs;
        return Scaffold(
          backgroundColor: AppColors.canvas,
          body: SafeArea(
            bottom: false,
            child: ResponsiveContent(
              child: Column(
                children: [
                  _buildHeader(),
                  _buildToolbar(songs),
                  Expanded(child: _buildList(songs)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.xs,
      ),
      child: Row(
        children: [
          AppIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            iconSize: 18,
            tooltip: '返回',
            onTap: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: AppSpace.xs),
          Expanded(
            child: Text(
              _title,
              style: AppType.display,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!widget.likedMode)
            PopupMenuButton<String>(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz_rounded, color: AppColors.ink),
              color: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.row),
              ),
              onSelected: (v) async {
                if (v == 'rename') await _rename();
                if (v == 'delete') await _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(value: 'delete', child: Text('删除歌单')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildToolbar(List<SongModel> songs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.xs,
        AppSpace.page,
        AppSpace.md,
      ),
      child: Row(
        children: [
          Text(
            '${songs.length} 首',
            style: AppType.caption.copyWith(color: AppColors.inkTertiary),
          ),
          const Spacer(),
          if (!widget.likedMode)
            TextButton.icon(
              onPressed: _addSongs,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加歌曲'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            ),
          const SizedBox(width: AppSpace.sm),
          FilledButton(
            onPressed: songs.isEmpty ? null : () => _playAll(songs),
            // 主 CTA 用主题的墨色实心，全站一致；强调色只留给选中态
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 40),
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow_rounded, size: 18),
                SizedBox(width: 4),
                Text('播放全部'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<SongModel> songs) {
    if (songs.isEmpty) {
      return AppEmptyState(
        icon: widget.likedMode
            ? Icons.favorite_border_rounded
            : Icons.queue_music_rounded,
        title: widget.likedMode ? '还没有喜欢的歌' : '歌单还是空的',
        message: widget.likedMode ? '播放时点一下喜欢，歌就会收进这里' : '从播放列表里挑几首放进来吧',
        actionLabel: widget.likedMode ? null : '添加歌曲',
        onAction: widget.likedMode ? null : _addSongs,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.xs,
        AppSpace.md,
        AppSpace.xxxl,
      ),
      itemCount: songs.length,
      itemBuilder: (_, i) => _buildRow(songs[i], i),
    );
  }

  Widget _buildRow(SongModel song, int index) {
    final hasCover = song.coverUrl != null && song.coverUrl!.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _playFrom(index),
        borderRadius: BorderRadius.circular(AppRadius.row),
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: hasCover
                      ? Image.network(
                          song.coverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const _CoverFallback(),
                        )
                      : const _CoverFallback(),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.xs),
              AppIconButton(
                icon: widget.likedMode
                    ? Icons.favorite_rounded
                    : Icons.remove_circle_outline_rounded,
                size: 40,
                iconSize: 20,
                tooltip: widget.likedMode ? '取消喜欢' : '从歌单移除',
                foreground: widget.likedMode
                    ? AppColors.rose
                    : AppColors.inkDisabled,
                onTap: () => _remove(song),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _playAll(List<SongModel> songs) {
    AudioPlayerService().playSongs(songs);
  }

  void _playFrom(int index) {
    // 从点中的这首开始，后续依次播放（服务层没有「按索引起播」，
    // 直接传子列表，行为一致且不需要改播放器状态机）
    final songs = _songs;
    if (index < 0 || index >= songs.length) return;
    AudioPlayerService().playSongs(songs.sublist(index));
  }

  Future<void> _addSongs() async {
    final picked = await Navigator.push<List<SongModel>>(
      context,
      MaterialPageRoute(builder: (_) => const SongPickerPage()),
    );
    if (picked == null || picked.isEmpty) return;
    final added = await _lib.addSongsToPlaylist(widget.playlistId, picked);
    if (!mounted) return;
    DesignToast.show(context, added > 0 ? '已添加 $added 首' : '这些歌都已在歌单里');
  }

  Future<void> _remove(SongModel song) async {
    if (widget.likedMode) {
      await _lib.toggleLike(song);
      return;
    }
    await _lib.removeSongFromPlaylist(widget.playlistId, song.id);
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null) return;
    await _lib.renamePlaylist(widget.playlistId, name);
  }

  Future<void> _delete() async {
    DesignDialog.showConfirm(
      context,
      titleText: '删除歌单',
      contentText: '删除后无法恢复，歌单里的歌曲不会从曲库移除。',
      onConfirm: () async {
        await _lib.deletePlaylist(widget.playlistId);
        if (mounted) Navigator.pop(context);
      },
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceMuted,
      child: Icon(
        Icons.music_note_rounded,
        size: 18,
        color: AppColors.inkTertiary,
      ),
    );
  }
}

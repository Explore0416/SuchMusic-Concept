import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/user_library_service.dart';
import '../utils/responsive.dart';
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
    final s = Responsive.uiScale(MediaQuery.of(context).size);
    return ValueListenableBuilder<int>(
      valueListenable: _lib.version,
      builder: (_, _, _) {
        final songs = _songs;
        return Scaffold(
          backgroundColor: const Color(0xFFF5F6F8),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            title: Text(_title,
                style:
                    TextStyle(fontSize: 17 * s, fontWeight: FontWeight.w600)),
            actions: [
              if (!widget.likedMode)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, color: Colors.black54),
                  onSelected: (v) async {
                    if (v == 'rename') await _rename(s);
                    if (v == 'delete') await _delete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'delete', child: Text('删除歌单')),
                  ],
                ),
            ],
          ),
          body: Column(
            children: [
              _header(s, songs),
              Expanded(
                child: songs.isEmpty
                    ? Center(
                        child: Text(
                          widget.likedMode
                              ? '还没有喜欢的歌\n播放时点一下 ♡ 就会出现在这里'
                              : '歌单还是空的\n点上方「添加歌曲」从播放列表里选',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13 * s, color: const Color(0xFF999999)),
                        ),
                      )
                    : ListView.separated(
                        padding: EdgeInsets.only(bottom: 16 * s),
                        itemCount: songs.length,
                        separatorBuilder: (_, _) => Divider(
                          height: 1,
                          indent: 16 * s,
                          endIndent: 16 * s,
                          color: const Color(0xFFF0F0F0),
                        ),
                        itemBuilder: (_, i) => _row(songs[i], s, i),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _header(double s, List<SongModel> songs) {
    return Container(
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(16 * s, 10 * s, 16 * s, 12 * s),
      child: Row(
        children: [
          Text(
            '${songs.length} 首',
            style: TextStyle(fontSize: 12 * s, color: const Color(0xFF999999)),
          ),
          const Spacer(),
          if (!widget.likedMode)
            TextButton.icon(
              onPressed: () => _addSongs(s),
              icon: Icon(Icons.add, size: 18 * s),
              label: Text('添加歌曲', style: TextStyle(fontSize: 13 * s)),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF2F84FE),
              ),
            ),
          SizedBox(width: 4 * s),
          FilledButton.icon(
            onPressed: songs.isEmpty ? null : () => _playAll(songs),
            icon: Icon(Icons.play_arrow, size: 18 * s),
            label: Text('播放', style: TextStyle(fontSize: 13 * s)),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2F84FE),
              minimumSize: Size(0, 34 * s),
              padding: EdgeInsets.symmetric(horizontal: 14 * s),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(SongModel song, double s, int index) {
    return ListTile(
      contentPadding: EdgeInsets.symmetric(horizontal: 16 * s, vertical: 2 * s),
      title: Text(
        song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 15 * s, color: Colors.black87),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12 * s, color: const Color(0xFF999999)),
      ),
      trailing: IconButton(
        icon: Icon(Icons.more_horiz, size: 20 * s, color: const Color(0xFFBBBBBB)),
        onPressed: () => _remove(song),
      ),
      onTap: () => _playFrom(index),
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

  Future<void> _addSongs(double s) async {
    final picked = await Navigator.push<List<SongModel>>(
      context,
      MaterialPageRoute(builder: (_) => const SongPickerPage()),
    );
    if (picked == null || picked.isEmpty) return;
    final added =
        await _lib.addSongsToPlaylist(widget.playlistId, picked);
    if (!mounted) return;
    DesignToast.show(
      context,
      added > 0 ? '已添加 $added 首' : '这些歌都已在歌单里',
    );
  }

  Future<void> _remove(SongModel song) async {
    if (widget.likedMode) {
      await _lib.toggleLike(song);
      return;
    }
    await _lib.removeSongFromPlaylist(widget.playlistId, song.id);
  }

  Future<void> _rename(double s) async {
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
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
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

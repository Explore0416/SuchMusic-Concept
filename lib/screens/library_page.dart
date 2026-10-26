import 'package:flutter/material.dart';

import '../services/user_library_service.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';
import 'kugou_playlist_page.dart';
import 'song_picker_page.dart';
import 'user_playlist_detail_page.dart';

/// 「歌单」总页：我喜欢的音乐 / 自建歌单 / 酷狗歌单。
///
/// 三块内容放在同一页，避免「歌单」和「酷狗歌单」两个入口各占一行。
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.embedded = false});

  /// 嵌入首页「歌单」标签时置 true：不套 Scaffold / AppBar，
  /// 由宿主页面提供背景与标题（宽屏时标题已在左侧导航上）。
  final bool embedded;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final UserLibraryService _lib = UserLibraryService.instance;

  static const Color _accent = Color(0xFF2F84FE);
  static const Color _sub = Color(0xFF999999);

  @override
  Widget build(BuildContext context) {
    final s = Responsive.uiScale(MediaQuery.of(context).size);
    return ValueListenableBuilder<int>(
      valueListenable: _lib.version,
      builder: (_, _, _) {
        final body = _buildBody(s);
        if (widget.embedded) {
          // 嵌入首页标签：底部要避开悬浮播放胶囊，留出足够余量
          return ListView(
            padding: EdgeInsets.fromLTRB(12 * s, 8 * s, 12 * s, 108),
            children: _bodyChildren(s),
          );
        }
        return Scaffold(
          backgroundColor: const Color(0xFFF5F6F8),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            title: Text(
              '歌单',
              style: TextStyle(fontSize: 17 * s, fontWeight: FontWeight.w600),
            ),
          ),
          body: body,
        );
      },
    );
  }

  Widget _buildBody(double s) => ListView(
    padding: EdgeInsets.fromLTRB(12 * s, 12 * s, 12 * s, 24 * s),
    children: _bodyChildren(s),
  );

  List<Widget> _bodyChildren(double s) => [
    _card(
      s,
      children: [
        _tile(
          s,
          icon: Icons.favorite,
          iconColor: const Color(0xFFFF5A7A),
          title: '我喜欢的音乐',
          subtitle: _lib.likedSongs.isEmpty
              ? '播放时点 ♡ 收藏到这里'
              : '${_lib.likedSongs.length} 首',
          onTap: () => _openLiked(),
        ),
        _divider(s),
        _tile(
          s,
          icon: Icons.add_circle_outline,
          iconColor: _accent,
          title: '新建歌单',
          subtitle: '从当前播放列表多选添加',
          onTap: () => _createPlaylist(s),
        ),
      ],
    ),
    SizedBox(height: 16 * s),
    _sectionTitle(s, '我的歌单'),
    SizedBox(height: 8 * s),
    if (_lib.playlists.isEmpty)
      _hint(s, '还没有自建歌单，点上方「新建歌单」开始')
    else
      _card(
        s,
        children: [
          for (var i = 0; i < _lib.playlists.length; i++) ...[
            if (i > 0) _divider(s),
            _tile(
              s,
              icon: Icons.queue_music,
              iconColor: _accent,
              title: _lib.playlists[i].name,
              subtitle: '${_lib.playlists[i].songs.length} 首',
              onTap: () => _openPlaylist(_lib.playlists[i].id),
            ),
          ],
        ],
      ),
    SizedBox(height: 16 * s),
    _sectionTitle(s, '酷狗歌单'),
    SizedBox(height: 8 * s),
    _card(
      s,
      children: [
        _tile(
          s,
          icon: Icons.cloud_outlined,
          iconColor: _accent,
          title: '查看酷狗歌单',
          subtitle: '登录后可查看账号歌单，也可粘贴链接导入',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const KugouPlaylistPage()),
          ),
        ),
      ],
    ),
  ];

  Widget _sectionTitle(double s, String text) => Padding(
    padding: EdgeInsets.only(left: 4 * s),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13 * s,
        color: _sub,
        fontWeight: FontWeight.w500,
      ),
    ),
  );

  Widget _hint(double s, String text) => Padding(
    padding: EdgeInsets.symmetric(vertical: 18 * s),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 12 * s, color: _sub),
    ),
  );

  Widget _card(double s, {required List<Widget> children}) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12 * s),
    ),
    child: Column(children: children),
  );

  Widget _divider(double s) => Divider(
    height: 1,
    indent: 56 * s,
    endIndent: 12 * s,
    color: const Color(0xFFF0F0F0),
  );

  Widget _tile(
    double s, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: 14 * s, vertical: 12 * s),
      child: Row(
        children: [
          Icon(icon, size: 22 * s, color: iconColor),
          SizedBox(width: 12 * s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15 * s,
                    color: Colors.black87,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 2 * s),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5 * s, color: _sub),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: 18 * s,
            color: const Color(0xFFCCCCCC),
          ),
        ],
      ),
    ),
  );

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

  Future<void> _createPlaylist(double s) async {
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
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

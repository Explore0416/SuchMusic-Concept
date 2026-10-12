import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/kugou_platform.dart';
import '../models/song_model.dart';
import '../services/kugou_credential_service.dart';
import '../services/sources/kugou_source.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';
import '../widgets/fade_slide_in.dart';
import 'playlist_detail_page.dart';

/// 酷狗歌单页：查看**已登录账号**的歌单 + 通过链接 / ID 导入任意歌单。
///
/// 支持两个平台（概念版 / 原版）：分别展示各自账号的歌单（凭证分区存储）。
class KugouPlaylistPage extends StatefulWidget {
  const KugouPlaylistPage({super.key});

  @override
  State<KugouPlaylistPage> createState() => _KugouPlaylistPageState();
}

/// 一个平台 + 其歌单。
class _PlatformPlaylists {
  _PlatformPlaylists(this.platform, this.playlists);
  final KugouPlatform platform;
  final List<PlaylistModel> playlists;
}

class _KugouPlaylistPageState extends State<KugouPlaylistPage> {
  final _importController = TextEditingController();

  bool _loading = true;
  bool _importing = false;
  List<_PlatformPlaylists> _groups = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final cred = KugouCredentialService.instance;
    final groups = <_PlatformPlaylists>[];
    for (final platform in KugouPlatform.values) {
      if (!cred.hasCredentialsFor(platform)) continue;
      final src = KugouSource(platform: platform);
      final list = await src.userPlaylists();
      groups.add(_PlatformPlaylists(platform, list));
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _loading = false;
    });
  }

  Future<void> _import() async {
    final input = _importController.text.trim();
    if (input.isEmpty) {
      DesignToast.show(context, '请粘贴酷狗歌单链接或歌单 ID');
      return;
    }
    setState(() => _importing = true);
    try {
      // 用**当前有登录态**的平台解析（无则用概念版）
      final platform = _preferredPlatform();
      final src = KugouSource(platform: platform);
      final gcid = await src.resolvePlaylistId(input);
      if (!mounted) return;
      if (gcid == null) {
        DesignToast.show(context, '无法识别歌单，请检查链接或直接粘贴歌单 ID');
        return;
      }
      // 取歌单元信息（失败也不阻塞，用占位信息进入）
      final info = await src.playlistInfo(gcid);
      if (!mounted) return;
      final playlist = info ??
          PlaylistModel(
            id: gcid,
            name: '酷狗歌单',
            source: SongSource.fromKugouPlatform(platform),
          );
      _importController.clear();
      await Navigator.push(
        context,
        fadeSlideRoute(PlaylistDetailPage(playlist: playlist)),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  KugouPlatform _preferredPlatform() {
    final cred = KugouCredentialService.instance;
    for (final p in KugouPlatform.values) {
      if (cred.hasCredentialsFor(p)) return p;
    }
    return KugouPlatform.lite;
  }

  Future<void> _openPlaylist(PlaylistModel playlist) async {
    await Navigator.push(
      context,
      fadeSlideRoute(PlaylistDetailPage(playlist: playlist)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(Responsive.textScaleMin, Responsive.textScaleMax);
    final content = Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        title: const Text('酷狗歌单'),
        backgroundColor: const Color(0xFFF5F6F8),
        elevation: 0,
        foregroundColor: Colors.black,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: Responsive.contentMaxWidth),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.fromLTRB(16 * scale, 8 * scale, 16 * scale, 24),
              children: [
                _buildImportCard(scale),
                SizedBox(height: 18 * scale),
                ..._buildBody(scale),
              ],
            ),
          ),
        ),
      ),
    );
    return content;
  }

  Widget _buildImportCard(double s) {
    return Container(
      padding: EdgeInsets.all(16 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.playlist_add, size: 20, color: Color(0xFF3080FF)),
              const SizedBox(width: 8),
              Text(
                '导入酷狗歌单',
                style: TextStyle(
                  fontSize: 15 * s,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          SizedBox(height: 10 * s),
          TextField(
            controller: _importController,
            minLines: 1,
            maxLines: 2,
            decoration: InputDecoration(
              hintText: '粘贴歌单链接或 ID（如 collection_3_xxx_1_0）',
              hintStyle: TextStyle(fontSize: 13 * s, color: const Color(0xFFAAAAAA)),
              filled: true,
              fillColor: const Color(0xFFF5F6F8),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 12 * s, vertical: 10 * s),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
            style: TextStyle(fontSize: 14 * s),
          ),
          SizedBox(height: 10 * s),
          SizedBox(
            width: double.infinity,
            height: 42 * s,
            child: ElevatedButton(
              onPressed: _importing ? null : _import,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3080FF),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text('导入并打开',
                      style: TextStyle(
                          fontSize: 14 * s, fontWeight: FontWeight.w500)),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBody(double s) {
    if (_loading) {
      return [
        Padding(
          padding: EdgeInsets.only(top: 40 * s),
          child: const Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_groups.isEmpty) {
      return [_buildEmptyHint(s)];
    }
    final widgets = <Widget>[];
    for (final g in _groups) {
      widgets.add(Padding(
        padding: EdgeInsets.only(bottom: 8 * s, top: 4 * s),
        child: Row(
          children: [
            Text(
              g.platform.label,
              style: TextStyle(
                fontSize: 15 * s,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
            SizedBox(width: 8 * s),
            Text('${g.playlists.length} 个歌单',
                style: TextStyle(fontSize: 12 * s, color: const Color(0xFF999999))),
          ],
        ),
      ));
      if (g.playlists.isEmpty) {
        widgets.add(Padding(
          padding: EdgeInsets.only(bottom: 12 * s),
          child: Text('暂无歌单（或登录态已失效）',
              style: TextStyle(fontSize: 13 * s, color: const Color(0xFF999999))),
        ));
        continue;
      }
      for (var i = 0; i < g.playlists.length; i++) {
        widgets.add(FadeSlideIn(
          index: i,
          child: _buildPlaylistTile(g.playlists[i], s),
        ));
      }
    }
    return widgets;
  }

  Widget _buildEmptyHint(double s) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 28 * s, horizontal: 16 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Icon(Icons.library_music_outlined,
              size: 36 * s, color: const Color(0xFFCCCCCC)),
          SizedBox(height: 10 * s),
          Text(
            '尚未登录酷狗账号\n登录后这里会显示你的酷狗歌单',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13 * s, color: const Color(0xFF999999), height: 1.6),
          ),
          SizedBox(height: 6 * s),
          Text(
            '也可以直接在上面粘贴歌单链接导入',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12 * s, color: const Color(0xFFBBBBBB)),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistTile(PlaylistModel pl, double s) {
    return Container(
      margin: EdgeInsets.only(bottom: 8 * s),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openPlaylist(pl),
        child: Padding(
          padding: EdgeInsets.all(10 * s),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 52 * s,
                  height: 52 * s,
                  child: (pl.coverUrl != null && pl.coverUrl!.isNotEmpty)
                      ? Image.network(
                          pl.coverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _coverPlaceholder(s),
                        )
                      : _coverPlaceholder(s),
                ),
              ),
              SizedBox(width: 12 * s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pl.name.isEmpty ? '未命名歌单' : pl.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14 * s,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                    ),
                    if (pl.trackCount != null) ...[
                      SizedBox(height: 4 * s),
                      Text('${pl.trackCount} 首',
                          style: TextStyle(
                              fontSize: 12 * s,
                              color: const Color(0xFF999999))),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFFCCCCCC)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _coverPlaceholder(double s) => Container(
        color: const Color(0xFFEEF1F5),
        child: Icon(Icons.music_note,
            size: 22 * s, color: const Color(0xFFBBBBBB)),
      );
}

/// 供外部（如「我的」页）使用的入口图标（保持风格一致）。
// ignore: unused_element
Widget kugouPlaylistEntryIcon() => SvgPicture.asset(
      'assets/images/svg/Play_cycle.svg',
      width: 20,
      height: 20,
      colorFilter: const ColorFilter.mode(Color(0xFF3080FF), BlendMode.srcIn),
    );

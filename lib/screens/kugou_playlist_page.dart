import 'package:flutter/material.dart';

import '../models/kugou_platform.dart';
import '../models/song_model.dart';
import '../services/kugou_credential_service.dart';
import '../services/sources/kugou_source.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/app_ui.dart';
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
      final playlist =
          info ??
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
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        bottom: false,
        child: ResponsiveContent(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  color: AppColors.brand,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.page,
                      0,
                      AppSpace.page,
                      AppSpace.xxxl,
                    ),
                    children: [_buildImportCard(), ..._buildBody()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.lg,
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
          const Text('酷狗歌单', style: AppType.display),
        ],
      ),
    );
  }

  /// 导入入口：一个输入框 + 一个按钮，说明「没有登录也能用」
  Widget _buildImportCard() {
    return AppCard(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.playlist_add_rounded,
                size: 20,
                color: AppColors.inkSecondary,
              ),
              const SizedBox(width: AppSpace.sm),
              Text(
                '导入酷狗歌单',
                style: AppType.body.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          TextField(
            controller: _importController,
            minLines: 1,
            maxLines: 2,
            style: AppType.body,
            decoration: const InputDecoration(
              hintText: '粘贴歌单链接或 ID（如 collection_3_xxx_1_0）',
            ),
          ),
          const SizedBox(height: AppSpace.md),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton(
              onPressed: _importing ? null : _import,
              // 主 CTA 走主题墨色，不再单独铺一块蓝
              style: FilledButton.styleFrom(minimumSize: const Size(0, 46)),
              child: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('导入并打开'),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_loading) {
      return [
        const Padding(
          padding: EdgeInsets.only(top: AppSpace.xxl),
          child: Center(
            child: CircularProgressIndicator(color: AppColors.brand),
          ),
        ),
      ];
    }
    if (_groups.isEmpty) {
      return [_buildEmptyHint()];
    }

    final widgets = <Widget>[];
    for (final g in _groups) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            4,
            AppSpace.xxl,
            AppSpace.page,
            AppSpace.sm,
          ),
          child: Row(
            children: [
              Text(g.platform.label, style: AppType.title),
              const SizedBox(width: AppSpace.sm),
              AppTag(
                text: '${g.playlists.length} 个',
                color: AppColors.inkTertiary,
                background: AppColors.surfaceMuted,
              ),
            ],
          ),
        ),
      );

      if (g.playlists.isEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: AppSpace.md),
            child: Text(
              '暂无歌单，登录态可能已失效',
              style: AppType.caption.copyWith(color: AppColors.inkTertiary),
            ),
          ),
        );
        continue;
      }

      final rows = <Widget>[];
      for (var i = 0; i < g.playlists.length; i++) {
        if (i > 0) {
          rows.add(const AppHairline(indent: 56, endIndent: AppSpace.lg));
        }
        rows.add(_buildPlaylistTile(g.playlists[i]));
      }
      widgets.add(
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: rows),
        ),
      );
    }
    return widgets;
  }

  Widget _buildEmptyHint() {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.xxl),
      child: AppEmptyState(
        icon: Icons.library_music_rounded,
        title: '还没有看到酷狗歌单',
        message: '登录酷狗账号后会显示在这里；也可以直接粘贴链接导入',
      ),
    );
  }

  Widget _buildPlaylistTile(PlaylistModel pl) {
    final hasCover = pl.coverUrl != null && pl.coverUrl!.isNotEmpty;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openPlaylist(pl),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.md,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: hasCover
                      ? Image.network(
                          pl.coverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const _CoverPlaceholder(),
                        )
                      : const _CoverPlaceholder(),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      pl.name.isEmpty ? '未命名歌单' : pl.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body,
                    ),
                    if (pl.trackCount != null) ...[
                      const SizedBox(height: 3),
                      Text('${pl.trackCount} 首', style: AppType.caption),
                    ],
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.inkDisabled,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.surfaceMuted,
      child: Icon(
        Icons.music_note_rounded,
        size: 20,
        color: AppColors.inkTertiary,
      ),
    );
  }
}

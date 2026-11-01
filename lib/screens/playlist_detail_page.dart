import 'dart:async';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/music_api_service.dart';
import '../services/sources/source_manager.dart';
import '../services/play_context_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

/// 歌单详情 / 每日推荐详情。
///
/// 结构：深色模糊封面做头图，白色内容卡从下方浮起承载曲目列表。
/// 头图固定、列表独立滚动，长时间翻歌时仍能看清这是哪个歌单。
class PlaylistDetailPage extends StatefulWidget {
  final PlaylistModel playlist;

  /// 每日推荐模式：没有歌单 ID，歌曲通过每日推荐接口加载
  final bool isDaily;

  /// 直接使用的封面（如首页传来的第一首歌封面），优先于歌单封面
  final String? coverUrl;

  const PlaylistDetailPage({
    super.key,
    required this.playlist,
    this.isDaily = false,
  }) : coverUrl = null;

  const PlaylistDetailPage.daily({super.key, this.coverUrl})
    : playlist = const PlaylistModel(id: 'daily_recommend', name: '每日推荐'),
      isDaily = true;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  final _apiService = MusicApiService();
  final _audioPlayer = AudioPlayerService();
  List<SongModel> _songs = [];
  bool _loading = true;
  Uint8List? _coverBytes;
  String? _currentSongId;
  StreamSubscription<SongModel?>? _currentSub;
  String? _error;

  static final Dio _coverDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  @override
  void initState() {
    super.initState();
    _loadCover(widget.coverUrl);
    _loadSongs();
    // 跟着播放状态走，列表里能实时标出正在播的那一首
    _currentSongId = _audioPlayer.currentSong?.id;
    _currentSub = _audioPlayer.onCurrentSongChanged.listen((song) {
      if (!mounted) return;
      if (song?.id == _currentSongId) return;
      setState(() => _currentSongId = song?.id);
    });
  }

  @override
  void dispose() {
    _currentSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCover([String? url]) async {
    url ??= widget.playlist.coverUrl;
    if (url == null) return;
    // 网易云封面服务支持 `?param=500y500` 压缩；酷狗封面已是固定尺寸 → 不追加
    final isNetease =
        url.contains('music.126.net') || url.contains('music.163.com');
    final sizedUrl = isNetease ? '${url.split('?').first}?param=500y500' : url;
    try {
      final response = await _coverDio.get(
        sizedUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            if (isNetease) 'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null && mounted) {
        setState(() => _coverBytes = response.data as Uint8List);
      }
    } catch (_) {}
  }

  Future<void> _loadSongs() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final isKugou = widget.playlist.source.isKugou;
    // 按歌单**自身**音源取实现（避免当前音源与歌单来源不一致时取错接口）
    final src = SourceManager().sourceFor(widget.playlist.source);
    final List<SongModel> songs;
    try {
      if (widget.isDaily) {
        songs = isKugou
            ? await src.dailyRecommend()
            : await _apiService.getDailyRecommendSongs();
      } else {
        songs = isKugou
            ? await src.rankSongs(widget.playlist.id)
            : await _apiService.playlistDetail(widget.playlist.id);
      }
    } catch (e) {
      // 网络/接口失败不再抛到界面外：留在本页给出重试出口
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '拿不到这个歌单的内容，检查网络或稍后重试';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _songs = songs;
      _loading = false;
    });
    // 无封面时（如每日推荐）用第一首歌的封面做背景
    if (_coverBytes == null && songs.isNotEmpty) {
      await _loadCover(songs.first.coverUrl);
    }
  }

  Future<void> _playAll() async {
    if (_songs.isEmpty) return;
    _setPlayContext();
    await _audioPlayer.playSongs(_songs);
  }

  Future<void> _playSong(int index) async {
    if (index >= _songs.length) return;
    _setPlayContext();
    await _audioPlayer.playAndAdd(_songs[index]);
  }

  /// 记录播放来源上下文（S1 歌单标签）：歌单名可用于曲风关键词匹配。
  void _setPlayContext() {
    final kind = widget.isDaily
        ? PlaySourceKind.daily
        : (widget.playlist.source.isKugou
              ? PlaySourceKind.rank
              : PlaySourceKind.playlist);
    PlayContextService().setSource(
      kind: kind,
      tags: widget.playlist.name.isNotEmpty
          ? <String>[widget.playlist.name]
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 深色页面：系统栏用浅色图标，避免 ColorOS 手势条自动垫浅色背景
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: AppColors.surface,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF14161D),
        body: Stack(
          children: [
            Positioned.fill(child: _buildBlurredBackground()),
            SafeArea(
              bottom: false,
              child: Column(
                children: [
                  _buildTopBar(),
                  _buildHero(),
                  Expanded(child: _buildContentSheet()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─────────────────────────── 头图 ───────────────────────────

  Widget _buildBlurredBackground() {
    if (_coverBytes == null) {
      return const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF232838), Color(0xFF14161D)],
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(_coverBytes!, fit: BoxFit.cover),
        ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 36, sigmaY: 36),
            child: const ColoredBox(color: Color(0x9914161D)),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.sm,
        0,
      ),
      child: Row(
        children: [
          _glassIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onTap: () => Navigator.maybePop(context),
          ),
          const Spacer(),
          AppTag(
            text: widget.isDaily ? '每日推荐' : widget.playlist.source.label,
            color: Colors.white,
            background: Colors.white.withValues(alpha: 0.24),
          ),
        ],
      ),
    );
  }

  Widget _glassIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: Colors.white.withValues(alpha: 0.12),
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildHero() {
    final count = _songs.isNotEmpty
        ? _songs.length
        : (widget.playlist.trackCount ?? 0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.lg,
        AppSpace.page,
        AppSpace.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _buildCoverThumb(),
              const SizedBox(width: AppSpace.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.playlist.name,
                      style: AppType.title.copyWith(
                        color: Colors.white,
                        height: 1.26,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      _loading ? '正在加载…' : (count > 0 ? '$count 首' : '空歌单'),
                      style: AppType.caption.copyWith(
                        color: Colors.white.withValues(alpha: 0.72),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.lg),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: _songs.isEmpty ? null : _playAll,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: AppColors.ink,
                disabledBackgroundColor: Colors.white.withValues(alpha: 0.3),
                disabledForegroundColor: Colors.white70,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.row),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow_rounded, size: 22),
                  SizedBox(width: 6),
                  Text('播放全部'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverThumb() {
    return Container(
      width: 104,
      height: 104,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: _coverBytes != null
            ? Image.memory(_coverBytes!, fit: BoxFit.cover)
            : const ColoredBox(
                color: Color(0xFF2A2F3C),
                child: Icon(
                  Icons.album_rounded,
                  size: 36,
                  color: Colors.white24,
                ),
              ),
      ),
    );
  }

  // ─────────────────────────── 白色内容卡 ───────────────────────────

  Widget _buildContentSheet() {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
        child: _buildSheetBody(),
      ),
    );
  }

  Widget _buildSheetBody() {
    if (_loading) return _buildSkeletons();

    if (_songs.isEmpty) {
      return AppEmptyState(
        icon: _error == null
            ? Icons.music_off_rounded
            : Icons.cloud_off_rounded,
        title: _error == null ? '这个歌单暂时没有歌' : '加载没成功',
        message: _error ?? '换个歌单看看，或稍后再试',
        actionLabel: '重新加载',
        onAction: _loadSongs,
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.md,
        AppSpace.md,
        AppSpace.md,
        AppSpace.xxxl,
      ),
      itemCount: _songs.length,
      itemBuilder: (_, index) => _buildSongRow(index, _songs[index]),
    );
  }

  Widget _buildSkeletons() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.xl,
        AppSpace.page,
        0,
      ),
      itemCount: 8,
      itemBuilder: (_, _) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            AppSkeleton(width: 20, height: 12, radius: 6),
            SizedBox(width: AppSpace.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSkeleton(width: 180, height: 13, radius: 6),
                  SizedBox(height: AppSpace.sm),
                  AppSkeleton(width: 104, height: 11, radius: 6),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSongRow(int index, SongModel song) {
    final isCurrent = _currentSongId == song.id;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _playSong(index),
        borderRadius: BorderRadius.circular(AppRadius.row),
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: AppType.caption.copyWith(
                    color: isCurrent ? AppColors.brand : AppColors.inkTertiary,
                  ),
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
                      style: AppType.body.copyWith(
                        color: isCurrent ? AppColors.brand : AppColors.ink,
                        fontWeight: isCurrent
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                    if (song.artist.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        song.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.caption,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Icon(
                isCurrent ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
                size: 20,
                color: isCurrent ? AppColors.brand : AppColors.inkDisabled,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

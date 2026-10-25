import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/kgm_decoder.dart';
import '../services/local_music_service.dart';
import '../utils/audio_cover.dart';

/// 本地音乐嵌入视图（首页「本地」标签内容区）：
/// 扫描设备音频文件（MediaStore），支持播放全部/单曲播放/当前播放行高亮。
/// 浅色风格，与首页其他模块一致；无 Scaffold，由宿主页面提供布局。
class LocalMusicView extends StatefulWidget {
  const LocalMusicView({super.key});

  @override
  State<LocalMusicView> createState() => _LocalMusicViewState();
}

class _LocalMusicViewState extends State<LocalMusicView>
    with TickerProviderStateMixin {
  final _audioPlayer = AudioPlayerService();

  /// 扫描结果缓存（静态，跨标签切换/页面重建保留）：
  /// 首页「本地」标签切走会销毁本 widget，切回时直接用缓存避免重新全盘扫描
  static List<SongModel>? _cache;

  /// 播放时按 id 反查原始条目（判断是否加密格式、取真实路径）
  static Map<String, LocalTrack>? _trackCache;
  Map<String, LocalTrack> _tracks = {};

  List<SongModel> _songs = [];
  bool _loading = true;
  bool _granted = false;
  // 刷新按钮的累计旋转圈数（每次点击 +1 圈）
  double _refreshTurns = 0;
  // 骨架屏扫光动画（循环）
  late final AnimationController _shimmerCtrl;

  @override
  void initState() {
    super.initState();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    final cached = _cache;
    if (cached != null) {
      // 有缓存直接显示，不重扫
      setState(() {
        _songs = cached;
        _tracks = _trackCache ?? const {};
        _loading = false;
        _granted = true;
      });
    } else {
      _checkPermissionAndScan();
    }
  }

  @override
  void dispose() {
    _shimmerCtrl.dispose();
    super.dispose();
  }

  /// 刷新：重置旋转动画并重新走权限检查+扫描
  Future<void> _refresh() async {
    setState(() => _refreshTurns += 1);
    await _checkPermissionAndScan();
  }

  Future<void> _checkPermissionAndScan() async {
    setState(() => _loading = true);
    try {
      // 走原生扫描（Kotlin 后台线程）：MediaStore 一次查询 + 目录遍历都在
      // 原生侧完成，主 isolate 不做任何 listSync —— 旧实现的同步全盘遍历
      // 会卡死 UI，切到别的标签也无响应。
      final result = await LocalMusicService.instance.scan();
      if (!mounted) return;
      final tracks = <String, LocalTrack>{
        for (final t in result.tracks) t.id: t,
      };
      final songs = result.tracks
          .map((t) => t.toSongModel())
          .toList(growable: false);
      _cache = songs;
      _trackCache = tracks;
      setState(() {
        _songs = songs;
        _tracks = tracks;
        _granted = result.audioPermission;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _playAll() async {
    if (_songs.isEmpty) return;
    final prepared = <SongModel>[];
    for (final song in _songs) {
      final item = await _playableOf(trackOf(song));
      if (item != null) prepared.add(item);
    }
    if (prepared.isEmpty) return;
    await _audioPlayer.playSongs(prepared);
  }

  Future<void> _playSong(int index) async {
    if (index >= _songs.length) return;
    final song = _songs[index];
    // 点击正在播放的歌曲时切换暂停/继续，避免从头重播
    final current = _audioPlayer.currentSong;
    if (current != null && current.id == song.id) {
      await _audioPlayer.togglePlayPause();
      return;
    }
    final playable = await _playableOf(trackOf(song));
    if (playable == null) return;
    await _audioPlayer.playAndAdd(playable);
  }

  LocalTrack? trackOf(SongModel song) => _tracks[song.id];

  /// 加密格式（.kgm/.kgg 等）先在本机解密到缓存，返回可直接播放的歌曲。
  /// 普通音频原样返回，不做任何额外处理。
  Future<SongModel?> _playableOf(LocalTrack? track) async {
    if (track == null) return null;
    final base = track.toSongModel();
    if (!track.isKgm) return base;
    final path = track.path;
    if (path == null) return base;
    try {
      final decoded = await KgmDecoder.instance.decodeToCache(path);
      return base.copyWith(localUri: decoded.uri.toString());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('解码失败：$e')),
        );
      }
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 15, right: 15, top: 4),
          child: _buildHeader(),
        ),
        Expanded(
          child: _loading
              ? _buildSkeleton()
              : !_granted
                  ? _buildPermissionDenied()
                  : _songs.isEmpty
                      ? _buildEmpty()
                      : _buildSongList(),
        ),
      ],
    );
  }

  /// 骨架屏加载态：与歌曲行同构（44×44 封面块 + 两行文字条），带扫光动画
  Widget _buildSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.only(left: 15, right: 15, top: 4),
      itemCount: 10,
      itemBuilder: (_, index) => _buildSkeletonItem(index),
    );
  }

  Widget _buildSkeletonItem(int index) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          _buildSkeletonBox(44, 44, 4),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 歌名条/歌手条宽度交错，更接近真实列表的观感
                _buildSkeletonBox(index.isEven ? 120 : 88, 10, 3),
                const SizedBox(height: 7),
                _buildSkeletonBox(index.isEven ? 68 : 52, 8, 3),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _buildSkeletonBox(22, 22, 11),
        ],
      ),
    );
  }

  /// 骨架占位块：灰底 + 白色高光随时间从左向右扫过
  Widget _buildSkeletonBox(double w, double h, double radius) {
    const base = Color(0xFFE9E9E9);
    const highlight = Color(0xFFF8F8F8);
    return AnimatedBuilder(
      animation: _shimmerCtrl,
      builder: (context, _) {
        final x = 2 * _shimmerCtrl.value - 1;
        return Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment(x - 1, 0),
              end: Alignment(x + 1, 0),
              colors: const [base, highlight, base],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          '本地音乐',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '${_songs.length}首',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: Color(0xFF9C9C9C),
          ),
        ),
        const Spacer(),
        // 刷新：重新扫描本地音频，点击时图标旋转一圈作反馈
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _loading ? null : _refresh,
          child: AnimatedRotation(
            turns: _refreshTurns,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            child: const SizedBox(
              width: 40,
              height: 31,
              child: Icon(
                Icons.refresh,
                size: 22,
                color: Colors.black87,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        GestureDetector(
          onTap: _playAll,
          child: Container(
            width: 46,
            height: 31,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF3080FF),
              borderRadius: BorderRadius.circular(25),
            ),
            child: SvgPicture.asset(
              'assets/images/svg/Play.svg',
              width: 22,
              height: 22,
              fit: BoxFit.contain,
              colorFilter:
                  const ColorFilter.mode(Colors.white, BlendMode.srcIn),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionDenied() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 48, color: Color(0xFF9C9C9C)),
          const SizedBox(height: 12),
          const Text(
            '需要读取音频文件权限才能扫描本地音乐',
            style: TextStyle(fontSize: 14, color: Color(0xFF9C9C9C)),
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _checkPermissionAndScan,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF3080FF),
                borderRadius: BorderRadius.circular(25),
              ),
              child: const Text(
                '授予权限',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.music_off, size: 48, color: Color(0xFF9C9C9C)),
          SizedBox(height: 12),
          Text(
            '未找到音频文件',
            style: TextStyle(fontSize: 14, color: Color(0xFF9C9C9C)),
          ),
        ],
      ),
    );
  }

  Widget _buildSongList() {
    return ListView.builder(
      padding: EdgeInsets.only(
        left: 15,
        right: 15,
        top: 4,
        bottom: MediaQuery.of(context).padding.bottom + 100,
      ),
      itemCount: _songs.length,
      itemBuilder: (_, index) {
        final song = _songs[index];
        return _buildSongItem(index, song);
      },
    );
  }

  /// 封面缩略图：解析音频内嵌封面（懒加载+缓存），无封面显示灰底音符占位
  Widget _buildCover(SongModel song) {
    final path = song.localPath;
    if (path == null || path.isEmpty) {
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFFEDEDED),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Icon(Icons.music_note, size: 20, color: Color(0xFFB5B5B5)),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: AudioCoverExtractor.extract(path),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Image.memory(
              bytes,
              width: 44,
              height: 44,
              fit: BoxFit.cover,
              cacheWidth: 96,
              gaplessPlayback: true,
            ),
          );
        }
        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFEDEDED),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(Icons.music_note, size: 20, color: Color(0xFFB5B5B5)),
        );
      },
    );
  }

  Widget _buildSongItem(int index, SongModel song) {
    return StreamBuilder<SongModel?>(
      // currentSong 流不回放最新值，用 initialData 播种保证进入页面即高亮
      stream: _audioPlayer.onCurrentSongChanged,
      initialData: _audioPlayer.currentSong,
      builder: (context, snapshot) {
        final isCurrent = snapshot.data?.id == song.id;
        final highlight = const Color(0xFF3080FF);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _playSong(index),
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                _buildCover(song),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.name,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: isCurrent ? highlight : Colors.black87,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (song.artist.isNotEmpty)
                        Text(
                          song.artist,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w400,
                            color: Color(0xFF9C9C9C),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  song.durationText,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: Color(0xFF9C9C9C),
                  ),
                ),
                const SizedBox(width: 10),
                if (isCurrent)
                  Icon(Icons.pause_rounded, size: 16, color: highlight)
                else
                  SvgPicture.asset(
                    'assets/images/svg/Play.svg',
                    width: 16,
                    height: 16,
                    colorFilter: const ColorFilter.mode(
                        Colors.black87, BlendMode.srcIn),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

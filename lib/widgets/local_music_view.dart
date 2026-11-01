import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/kgm_decoder.dart';
import '../services/local_music_service.dart';
import '../theme/app_theme.dart';
import '../utils/audio_cover.dart';
import 'app_ui.dart';

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

  /// 是否已授予「所有文件访问权限」——没有它就只能读系统已索引的音频，
  /// 录音机存的 wav、刚拷进来还没被媒体库收录的文件都会漏掉。
  bool _allFiles = false;
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
        _allFiles = result.allFilesAccess;
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
    if (prepared.isEmpty) {
      _toast('这些文件暂时读不出来，可能是权限或文件已被移动');
      return;
    }
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
    final ok = await _audioPlayer.playAndAdd(playable);
    if (!ok && mounted) {
      _toast(_audioPlayer.lastError ?? '这首歌没能播起来，换一首试试');
    }
  }

  /// 按歌曲反查原始条目。
  ///
  /// 注意 [SongModel.id] 是 `local:<uri>`，而 [_tracks] 的键是**裸 uri**；
  /// 早期直接用 `_tracks[song.id]` 查，永远查不到 → 点击后静默返回，
  /// 表现为「点了没反应、一首也放不出来」。这里以 localUri 为准，id 兜底。
  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  LocalTrack? trackOf(SongModel song) =>
      _tracks[song.localUri] ?? _tracks[song.id];

  /// 加密格式（.kgm/.kgg 等）先在本机解密到缓存，返回可直接播放的歌曲。
  /// 普通音频原样返回，不做任何额外处理。
  Future<SongModel?> _playableOf(LocalTrack? track) async {
    if (track == null) return null;
    final base = track.toSongModel();
    final path = filePathOfUri(track.path) ?? filePathOfUri(base.localPath);
    if (path == null) return base;
    // 只看后缀会骗人：`东风破_MQ.kgg.flac`、把 .kgm 改名成 .mp3 的文件
    // 一旦当普通音频交给播放器，就是一秒一个 "(0) Source error"。
    // 所以以**文件头**为准：密文先解密，解不出再谈其他。
    final encrypted = track.isKgm || await _looksEncrypted(path);
    if (!encrypted) return base;
    try {
      final decoded = await KgmDecoder.instance.decodeToCache(
        path,
        forceAttempt: track.isKgm,
      );
      // localPath 也指向解密产物，播放器才能走 file:// 原生文件通道
      return base.copyWith(
        localUri: decoded.uri.toString(),
        localPath: decoded.path,
      );
    } on KgmDecodeException catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('「${track.name}」$e')));
      }
      return null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('解码失败：$e')));
      }
      return null;
    }
  }

  /// 文件头是否「不像标准音频」——可能是加密壳或未知专有格式。
  Future<bool> _looksEncrypted(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      final raf = await f.open();
      final head = Uint8List.fromList(await raf.read(64));
      await raf.close();
      if (KgmDecoder.looksLikeKgm(head)) return true;
      if (KgmDecoder.looksLikeAudio(head)) return false;
      // 魔数不认识但头部布局像加密文件 → 试解，解错会被音频魔数校验拦下
      return KgmDecoder.canAttemptDecode(head, await f.length());
    } catch (_) {
      return false;
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
    return AppPageHeader(
      title: '本地音乐',
      subtitle: _songs.isEmpty ? '扫描设备上保存的音频' : '${_songs.length} 首，全部保存在本机',
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.sm,
        AppSpace.page,
        AppSpace.lg,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIconButton(
            icon: Icons.refresh_rounded,
            onTap: _loading ? null : _refresh,
            tooltip: '重新扫描',
          ),
          const SizedBox(width: AppSpace.xs),
          FilledButton.icon(
            onPressed: _songs.isEmpty || _loading ? null : _playAll,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            label: const Text('播放全部'),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionDenied() {
    return AppEmptyState(
      icon: Icons.lock_outline_rounded,
      title: '需要读取音频文件权限',
      message: '授权后才能在设备上扫描本地音乐',
      actionLabel: '授予权限',
      onAction: _checkPermissionAndScan,
    );
  }

  Widget _buildEmpty() {
    // 一个都没扫到、又没给「所有文件访问权限」时，多半不是真的没有歌：
    // 录音机存的 .wav、刚拷进来还没被媒体库收录的文件都会漏。
    // 这里直接给出口，而不是让用户面对一句「未找到音频文件」无从下手。
    if (!_allFiles) {
      return AppEmptyState(
        icon: Icons.folder_open_rounded,
        title: '没找到音频文件',
        message:
            '如果手机里确实有歌（尤其是录音机录的 .wav），'
            '多半是权限不够：授予「所有文件访问权限」后重新扫描即可。',
        actionLabel: '去授权',
        onAction: _openAllFilesSettings,
      );
    }
    return AppEmptyState(
      icon: Icons.music_off_rounded,
      title: '未找到音频文件',
      message: '把音乐放进手机存储后，点右上角重新扫描',
    );
  }

  Future<void> _openAllFilesSettings() async {
    await LocalMusicService.instance.openAllFilesSettings();
    // 用户从系统页面返回后自动重扫一次，省掉「还要再点刷新」这一步
    if (mounted) await _checkPermissionAndScan();
  }

  Widget _buildSongList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.xs,
        AppSpace.page,
        AppLayout.bottomInsetWithPlayer,
      ),
      itemCount: _songs.length,
      itemBuilder: (_, index) {
        final song = _songs[index];
        return _buildSongItem(index, song);
      },
    );
  }

  /// 封面缩略图：解析音频内嵌封面（懒加载+缓存），无封面显示占位。
  Widget _buildCover(SongModel song) {
    final path = song.localPath;
    if (path == null || path.isEmpty) {
      return _coverPlaceholder();
    }
    return FutureBuilder<Uint8List?>(
      future: AudioCoverExtractor.extract(path),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              width: 48,
              height: 48,
              fit: BoxFit.cover,
              cacheWidth: 96,
              gaplessPlayback: true,
            ),
          );
        }
        return _coverPlaceholder();
      },
    );
  }

  Widget _coverPlaceholder() {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(
        Icons.music_note_rounded,
        size: 20,
        color: AppColors.inkTertiary,
      ),
    );
  }

  Widget _buildSongItem(int index, SongModel song) {
    return StreamBuilder<SongModel?>(
      // currentSong 流不回放最新值，用 initialData 播种保证进入页面即高亮
      stream: _audioPlayer.onCurrentSongChanged,
      initialData: _audioPlayer.currentSong,
      builder: (context, snapshot) {
        final isCurrent = snapshot.data?.id == song.id;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _playSong(index),
            child: SizedBox(
              height: 66,
              child: Row(
                children: [
                  _buildCover(song),
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
                        const SizedBox(height: 2),
                        Text(
                          song.artist.isEmpty ? '未知歌手' : song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.caption.copyWith(
                            color: AppColors.inkTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Text(
                    song.durationText,
                    style: AppType.caption.copyWith(
                      color: AppColors.inkTertiary,
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(
                      isCurrent
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 22,
                      color: isCurrent
                          ? AppColors.brand
                          : AppColors.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

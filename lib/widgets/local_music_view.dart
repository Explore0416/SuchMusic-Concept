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
      padding: const EdgeInsets.only(
        left: AppSpace.page,
        right: AppSpace.page,
        top: AppSpace.xs,
      ),
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

  /// 骨架占位块：灰底 + 高光随时间从左向右扫过。
  ///
  /// 颜色全部由语义令牌派生（`surfaceMuted` → `surface`），不再硬编码
  /// `0xFFE9E9E9` / `0xFFF8F8F8`，避免暗色/主题调整时漏改。
  Widget _buildSkeletonBox(double w, double h, double radius) {
    const base = AppColors.surfaceMuted;
    const highlight = AppColors.surface;
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
    // 这里直接给出口，而不是让用户面对一句「没找到音频文件」无从下手。
    if (!_allFiles) {
      return _buildEmptyBody(
        icon: Icons.folder_open_rounded,
        hint: '录音和刚拷进来的文件可能还没被媒体库收录，授予「所有文件访问权限」后再扫描',
        actionLabel: '去授权',
        onAction: _openAllFilesSettings,
      );
    }
    return _buildEmptyBody(
      icon: Icons.music_off_rounded,
      actionLabel: '扫描本机',
      onAction: _refresh,
    );
  }

  /// 空状态统一形态：48 图标 + 一句结论 + 一个主按钮（不多堆说明）。
  Widget _buildEmptyBody({
    required IconData icon,
    required String actionLabel,
    required VoidCallback onAction,
    String? hint,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.inkDisabled),
            const SizedBox(height: AppSpace.lg),
            Text('还没有扫描到音频', style: AppType.body),
            if (hint != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: AppType.caption.copyWith(color: AppColors.inkTertiary),
              ),
            ],
            const SizedBox(height: AppSpace.xl),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAllFilesSettings() async {
    await LocalMusicService.instance.openAllFilesSettings();
    // 用户从系统页面返回后自动重扫一次，省掉「还要再点刷新」这一步
    if (mounted) await _checkPermissionAndScan();
  }

  /// 歌曲列表：整块白色卡面（圆角 20 + 发丝边），与 canvas 背景拉开边界。
  ///
  /// 面板本身固定占位，只有内部列表滚动；底部预留「播放卡 + 导航坞」高度，
  /// 保证最后一行能滚到手指够得着的位置。
  Widget _buildSongList() {
    final radius = BorderRadius.circular(AppRadius.card);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.xs,
        AppSpace.page,
        AppLayout.bottomInsetWithPlayer,
      ),
      child: DecoratedBox(
        // 只画边框、并且画在滚动内容之上（foreground）：
        // 行滚过去不会盖住发丝边，也不会像带底色的前景装饰那样糊住列表
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: AppColors.hairline, width: 0.7),
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(
            color: AppColors.surface,
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: _songs.length,
              itemBuilder: (_, index) => _buildSongItem(
                index,
                _songs[index],
                isLast: index == _songs.length - 1,
              ),
            ),
          ),
        ),
      ),
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

  /// 单行歌曲：高 60，按下整行铺 [AppColors.surfaceMuted] 反馈。
  ///
  /// 左起：当前播放竖条（3×24）/ 封面 48 / 歌名+艺人 / 时长 / 更多。
  /// 行间分割线左缩进 68，正好与封面右缘对齐。
  Widget _buildSongItem(
    int index,
    SongModel song, {
    required bool isLast,
  }) {
    return StreamBuilder<SongModel?>(
      // currentSong 流不回放最新值，用 initialData 播种保证进入页面即高亮
      stream: _audioPlayer.onCurrentSongChanged,
      initialData: _audioPlayer.currentSong,
      builder: (context, snapshot) {
        final isCurrent = snapshot.data?.id == song.id;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              color: AppColors.surface,
              child: InkWell(
                onTap: () => _playSong(index),
                // 水波会冲出方角行、盖住发丝边；按下态统一用整行底色更干净
                splashFactory: NoSplash.splashFactory,
                highlightColor: AppColors.surfaceMuted,
                overlayColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.pressed)
                      ? AppColors.surfaceMuted
                      : null,
                ),
                child: SizedBox(
                  height: 60,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 12,
                        child: Center(
                          child: isCurrent
                              ? Container(
                                  width: 3,
                                  height: 24,
                                  decoration: BoxDecoration(
                                    color: AppColors.brand,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                )
                              : null,
                        ),
                      ),
                      _buildCover(song),
                      const SizedBox(width: AppSpace.sm),
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
                                color: isCurrent
                                    ? AppColors.brand
                                    : AppColors.ink,
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
                                color: isCurrent
                                    ? AppColors.inkSecondary
                                    : AppColors.inkTertiary,
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
                      const SizedBox(width: AppSpace.xs),
                      _buildMoreButton(index, song),
                      const SizedBox(width: 6),
                    ],
                  ),
                ),
              ),
            ),
            if (!isLast) const AppHairline(indent: 68),
          ],
        );
      },
    );
  }

  /// 行尾「更多」：44×44 热区，点开歌曲信息面板（播放等动作都在里面）。
  Widget _buildMoreButton(int index, SongModel song) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _showTrackSheet(index, song),
          child: const Icon(
            Icons.more_horiz_rounded,
            size: 20,
            color: AppColors.inkTertiary,
          ),
        ),
      ),
    );
  }

  /// 歌曲信息面板：这份文件到底是什么（格式 / 时长），以及一个播放入口。
  Future<void> _showTrackSheet(int index, SongModel song) async {
    final track = trackOf(song);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.sheet),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.page,
                ),
                child: Row(
                  children: [
                    _buildCover(song),
                    const SizedBox(width: AppSpace.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.body.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            song.artist.isEmpty ? '未知歌手' : song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.caption,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (track != null) ...[
                const SizedBox(height: AppSpace.md),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.page,
                  ),
                  child: Text(
                    '格式 ${track.ext.isEmpty ? '未知' : track.ext.toUpperCase()}，'
                    '时长 ${song.durationText}',
                    style: AppType.caption.copyWith(
                      color: AppColors.inkTertiary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpace.sm),
              AppListTile(
                title: '播放这首歌',
                icon: Icons.play_arrow_rounded,
                showChevron: false,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _playSong(index);
                },
              ),
              const SizedBox(height: AppSpace.sm),
            ],
          ),
        ),
      ),
    );
  }
}

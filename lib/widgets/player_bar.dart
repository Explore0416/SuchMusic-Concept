import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:marquee/marquee.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';

/// 横屏 / 平板形态的**常驻底部播放条**（参考 PC 版 SuchMusic-NG 的 PlayerBar）。
///
/// 解决「横屏下看不到、也控制不了正在播放的歌」的问题：
/// - 左：封面 + 歌名/歌手（点击打开播放页）
/// - 中：播放模式 / 上一首 / 播放暂停（实心圆）/ 下一首
/// - 右：时间 `mm:ss / mm:ss` + 打开播放页
/// - 顶部：细进度线（可拖动 seek）
///
/// 纯展示组件：数据与回调均由外部注入，便于 widget 测试。
class PlayerBar extends StatelessWidget {
  const PlayerBar({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.playMode,
    required this.onTogglePlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onTogglePlayMode,
    required this.onSeek,
    required this.onOpenPlayer,
    this.height = 80,
  });

  final SongModel? song;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final PlayMode playMode;
  final VoidCallback onTogglePlayPause;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onTogglePlayMode;

  /// 拖动/点击进度 → seek 到目标位置
  final ValueChanged<Duration> onSeek;

  /// 打开播放页
  final VoidCallback onOpenPlayer;

  final double height;

  static const Color _accent = Color(0xFF2F84FE);
  static const Color _sub = Color(0xFF838383);

  double get _progress {
    if (duration.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEDEDED))),
      ),
      child: Stack(
        children: [
          // 顶部细进度线（可拖动）
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: 2,
            child: _ProgressLine(
              progress: _progress,
              onSeekFraction: (f) => onSeek(Duration(
                  milliseconds: (duration.inMilliseconds * f).round())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(flex: 3, child: _buildSongInfo()),
                Expanded(flex: 4, child: _buildControls()),
                Expanded(flex: 3, child: _buildActions()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 左：封面 + 歌名/歌手 ──────────────────────────────────
  Widget _buildSongInfo() {
    final name = song?.name ?? '暂无播放';
    final artist = song?.artist ?? '';
    return InkWell(
      onTap: song != null ? onOpenPlayer : null,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 48,
              height: 48,
              child: _PlayerBarCover(song: song),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _marquee(
                  name,
                  const TextStyle(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                if (artist.isNotEmpty)
                  Text(
                    artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _sub, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _marquee(String text, TextStyle style) {
    return SizedBox(
      height: 20,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final tp = TextPainter(
            text: TextSpan(text: text, style: style),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: double.infinity);
          if (tp.width <= constraints.maxWidth) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(text,
                  style: style, maxLines: 1, softWrap: false),
            );
          }
          return Marquee(
            text: text,
            style: style,
            velocity: 22,
            blankSpace: 60,
            pauseAfterRound: const Duration(seconds: 2),
          );
        },
      ),
    );
  }

  // ── 中：播放控制 ──────────────────────────────────────────
  Widget _buildControls() {
    final hasSong = song != null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _iconButton(
          asset: switch (playMode) {
            PlayMode.shuffle => 'assets/images/svg/shuffle-one.svg',
            PlayMode.single => 'assets/images/svg/play-once.svg',
            PlayMode.loop => 'assets/images/svg/Play_cycle.svg',
          },
          size: 20,
          color: _sub,
          onTap: onTogglePlayMode,
          tooltip: '播放模式',
          animate: true,
        ),
        const SizedBox(width: 18),
        _iconButton(
          asset: 'assets/images/svg/Previous.svg',
          size: 24,
          color: Colors.black87,
          onTap: hasSong ? onPrevious : null,
          tooltip: '上一首',
        ),
        const SizedBox(width: 18),
        _playPauseButton(hasSong),
        const SizedBox(width: 18),
        _iconButton(
          asset: 'assets/images/svg/Next.svg',
          size: 24,
          color: Colors.black87,
          onTap: hasSong ? onNext : null,
          tooltip: '下一首',
        ),
      ],
    );
  }

  Widget _playPauseButton(bool enabled) {
    return Tooltip(
      message: isPlaying ? '暂停' : '播放',
      child: SizedBox(
        width: 44,
        height: 44,
        child: Material(
          color: enabled ? _accent : const Color(0xFFC4C4C4),
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? onTogglePlayPause : null,
            child: Center(
              child: SvgPicture.asset(
                isPlaying
                    ? 'assets/images/svg/Pause.svg'
                    : 'assets/images/svg/Play.svg',
                width: 20,
                height: 20,
                colorFilter:
                    const ColorFilter.mode(Colors.white, BlendMode.srcIn),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 右：时间 + 打开播放页 ─────────────────────────────────
  Widget _buildActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '${_fmt(position)} / ${_fmt(duration)}',
          style: const TextStyle(
            color: _sub,
            fontSize: 12,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 12),
        _iconButton(
          asset: 'assets/images/svg/Playlist_Alternate.svg',
          size: 22,
          color: Colors.black87,
          onTap: onOpenPlayer,
          tooltip: '打开播放页',
        ),
      ],
    );
  }

  Widget _iconButton({
    required String asset,
    required double size,
    required Color color,
    required VoidCallback? onTap,
    String? tooltip,
    bool animate = false,
  }) {
    final svg = SvgPicture.asset(
      asset,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(
        onTap == null ? const Color(0xFFC4C4C4) : color,
        BlendMode.srcIn,
      ),
    );
    // 播放模式等「同一按钮换图标」的场景：淡入淡出 + 缩放/旋转，避免生硬跳变
    final icon = animate
        ? AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.65, end: 1.0).animate(animation),
                child: RotationTransition(
                  turns:
                      Tween<double>(begin: -0.28, end: 0.0).animate(animation),
                  child: child,
                ),
              ),
            ),
            child: KeyedSubtree(key: ValueKey<String>(asset), child: svg),
          )
        : svg;
    Widget btn = SizedBox(
      width: 40,
      height: 40,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Center(child: icon),
        ),
      ),
    );
    if (tooltip != null) btn = Tooltip(message: tooltip, child: btn);
    return btn;
  }
}

/// 顶部细进度线：点击/拖动 seek。
class _ProgressLine extends StatelessWidget {
  const _ProgressLine({required this.progress, required this.onSeekFraction});

  final double progress;
  final ValueChanged<double> onSeekFraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        void handle(Offset local) {
          if (w <= 0) return;
          onSeekFraction((local.dx / w).clamp(0.0, 1.0));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => handle(d.localPosition),
          onHorizontalDragUpdate: (d) => handle(d.localPosition),
          child: SizedBox(
            height: 2,
            child: Stack(
              children: [
                Container(color: const Color(0xFFE6E6E6)),
                FractionallySizedBox(
                  widthFactor: progress,
                  child: Container(color: PlayerBar._accent),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 播放条封面（复用 AudioPlayerService 的封面缓存 / 预取）。
class _PlayerBarCover extends StatefulWidget {
  const _PlayerBarCover({required this.song});

  final SongModel? song;

  @override
  State<_PlayerBarCover> createState() => _PlayerBarCoverState();
}

class _PlayerBarCoverState extends State<_PlayerBarCover> {
  @override
  void initState() {
    super.initState();
    _prefetch();
  }

  @override
  void didUpdateWidget(covariant _PlayerBarCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song?.coverUrl != widget.song?.coverUrl) _prefetch();
  }

  void _prefetch() {
    final url = widget.song?.coverUrl;
    if (url == null || url.isEmpty) return;
    AudioPlayerService.preFetchCover(url).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.song?.coverUrl;
    final bytes = (url == null || url.isEmpty)
        ? null
        : (AudioPlayerService.cachedCover(url) ??
            AudioPlayerService.lastCoverBytes);
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover);
    }
    return Image.asset(
      'assets/images/SuchMusic@1x.png',
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) =>
          Container(color: const Color(0xFFE8E8E8)),
    );
  }
}

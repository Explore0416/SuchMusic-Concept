import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:marquee/marquee.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'screens/agreement_page.dart';
import 'screens/home_page.dart';
import 'screens/profile_page.dart';
import 'services/audio_player_handler.dart';
import 'services/audio_player_service.dart';
import 'services/band/band_service.dart';
import 'services/band/band_relay_service.dart';
import 'services/local_audio_intent_service.dart';
import 'services/local_lyric_service.dart';
import 'services/play_history_service.dart';
import 'services/sound_effect_service.dart';
import 'services/app_init.dart';
import 'services/crash_log_service.dart';
import 'services/sources/kugou_device_service.dart';
import 'models/song_model.dart';
import 'utils/player_route.dart';
import 'utils/responsive.dart';
import 'widgets/responsive_scaffold.dart';
import 'widgets/player_bar.dart';
import 'widgets/update_checker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局异常兜底（必须在 runApp 之前安装）：
  // - release 下 build 异常不再整屏灰框（RenderErrorBox），改为极简安全占位；
  // - 捕获并落盘最近异常，便于用户复现时定位。
  CrashLogService.instance.install();
  await AudioService.init(
    builder: () => AudioPlayerHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.suchmusic.audio.v2',
      androidNotificationChannelName: 'SuchMusic概念版',
      androidNotificationChannelDescription: '音乐播放控制',
      androidStopForegroundOnPause: false,
      androidNotificationIcon: 'drawable/ic_notification',
      androidShowNotificationBadge: true,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarContrastEnforced: false,
  ));

  runApp(const MyApp());
  await NeteaseMusicApi.init(debug: true);
  await AudioPlayerService().init();
  // 监听系统「打开方式 / 分享」进来的本地音频（Android）
  LocalAudioIntentService.instance.start();
  // 本地播放历史 + 手动歌词映射（**只存本机，不上传任何数据**）
  await PlayHistoryService().init();
  await LocalLyricService().init();
  // 播放历史用于首页本地个性化推荐；明确不上传云端。
  // 同时结算「上一首」的完成度 / 跳过（切歌时读取 position/duration），
  // 更细腻的偏好信号仅本机留存，不涉及任何网络请求。
  SongModel? lastRecordedSong;
  AudioPlayerService().onCurrentSongChanged.listen((song) {
    if (song == null) return;
    final prev = lastRecordedSong;
    if (prev != null && prev.id != song.id) {
      final ratio = AudioPlayerService().lastCompletionRatio;
      if (ratio >= 0) {
        unawaited(PlayHistoryService().recordCompletion(
          prev,
          completionRatio: ratio,
          skipped: AudioPlayerService().lastPlayWasSkipped,
        ));
      }
    }
    lastRecordedSong = song;
    unawaited(PlayHistoryService().record(song));
  });
  // 恢复上次选择的音效「预设选择」。
  // 注意：启动阶段尚无播放会话，此处**不做实际 apply**；真正的音效应用由
  // AudioPlayerService 监听到 just_audio 会话就绪后调用 setSessionId 触发
  // （效果器必须绑定 App 自己的播放会话，而非全局混音会话 0）。
  unawaited(SoundEffectService.instance.restore());
  // 手环桥接：读取「启用手环控制」开关，按需把 AudioPlayerService 接入手环链路
  // （与 AudioPlayerHandler 同源订阅，命令直接落到 service）。SDK 未就绪时静默不可用。
  unawaited(BandService.instance.init());
  // 电脑控制（局域网中继）：**默认关闭**，仅在用户于「设置 → 手环」显式开启后，
  // 才在私网地址上监听 WebSocket，供 Windows 端 (SuchMusic-NG) 经手机中转控制播放。
  // 未开启时不监听任何端口、不产生任何网络入口。
  unawaited(BandRelayService.instance.init());
  // 酷狗设备注册（取播放直链前置，未注册会被风控拒绝）；
  // 后台进行、失败静默，取链时会自动再补一次。
  unawaited(KugouDeviceService.instance.init());
  markInitialized();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: MaterialApp(
        title: 'SuchMusic概念版',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
          // 全局字体：MiSans（自带 400/500/700 字重）
          fontFamily: 'MiSans',
        ),
        // 全局夹取系统字体缩放至 [0.85, 1.3]，保障无极缩放下不溢出/不截断
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: Responsive.textScaleMin,
          maxScaleFactor: Responsive.textScaleMax,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const MainShell(),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  final AudioPlayerService _audioPlayer = AudioPlayerService();
  StreamSubscription<SongModel?>? _currentSongSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<PlayMode>? _playModeSub;
  SongModel? _currentSong;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  PlayMode _playMode = PlayMode.loop;

  final List<Widget> _pages = const [
    HomePage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    _currentSong = _audioPlayer.currentSong;
    _position = _audioPlayer.position;
    _duration = _audioPlayer.duration;
    _isPlaying = _audioPlayer.isPlaying;
    _playMode = _audioPlayer.playMode;
    _currentSongSub = _audioPlayer.onCurrentSongChanged.listen((song) {
      if (mounted) {
        setState(() {
          _currentSong = song ?? _audioPlayer.currentSong;
        });
      }
    });
    _positionSub = _audioPlayer.onPositionChanged.listen((pos) {
      if (mounted) {
        setState(() => _position = pos);
      }
    });
    _durationSub = _audioPlayer.onDurationChanged.listen((dur) {
      if (mounted) {
        setState(() => _duration = dur);
      }
    });
    _stateSub = _audioPlayer.onStateChanged.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state == PlayerState.playing);
      }
    });
    _playModeSub = _audioPlayer.onPlayModeChanged.listen((mode) {
      if (mounted) {
        setState(() => _playMode = mode);
      }
    });
    // 首次启动（或协议版本更新后）弹出《用户协议》确认弹窗
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showAgreementConsentDialogIfNeed(context);
      // 启动 3 秒后静默检查更新：有新版本时弹提示（远端 force 为 true 时强制更新，无法跳过）
      Timer(const Duration(seconds: 3), () {
        if (mounted) UpdateChecker.check(context, silent: true);
      });
    });
  }

  @override
  void dispose() {
    _currentSongSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _playModeSub?.cancel();
    super.dispose();
  }

  /// 打开播放页（统一底部滑入转场 + 防重复打开）。
  void _openPlayerPage() => openPlayerPage(context);

  @override
  Widget build(BuildContext context) {
    return ResponsiveScaffold(
      currentIndex: _currentIndex,
      onDestinationSelected: (index) => setState(() => _currentIndex = index),
      destinations: const [
        NavDestination(
          icon: Icons.home_outlined,
          selectedIcon: Icons.home,
          label: '首页',
        ),
        NavDestination(
          icon: Icons.person_outline,
          selectedIcon: Icons.person,
          label: '我的',
        ),
      ],
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomBar: _buildTabBar(),
      // 平板 / 横屏：PC 风格底部常驻播放条
      playerBar: PlayerBar(
        song: _currentSong,
        isPlaying: _isPlaying,
        position: _position,
        duration: _duration,
        playMode: _playMode,
        onTogglePlayPause: () => _audioPlayer.togglePlayPause(),
        onPrevious: () => _audioPlayer.playPrevious(),
        onNext: () => _audioPlayer.playNext(),
        onTogglePlayMode: () => _audioPlayer.togglePlayMode(),
        onSeek: (pos) => _audioPlayer.seek(pos),
        onOpenPlayer: _openPlayerPage,
      ),
    );
  }

  Widget _buildTabBar() {
    final barWidth = Responsive.bottomBarWidth(MediaQuery.sizeOf(context));
    final barHeight = 72.0;
    final coverSize = barWidth * (42 / 320);
    final coverTop = (barHeight - coverSize) / 2;
    final iconTop = (barHeight - 36) / 2;
    final pillLeft = barWidth * (91 / 320);
    final pillWidth = barWidth * (138 / 320);

    return Center(
      child: GestureDetector(
        onTapUp: (details) {
          final dx = details.localPosition.dx;
          final dy = details.localPosition.dy;
          final inPill = dx >= pillLeft &&
              dx <= pillLeft + pillWidth &&
              dy >= 8 &&
              dy <= 64;
          if (!inPill) return;
          _openPlayerPage();
        },
        child: Container(
          width: barWidth,
          height: barHeight,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(100),
          ),
          child: Stack(
            children: [
              Positioned(
                left: barWidth * (91 / 320),
                top: 8,
                width: barWidth * (138 / 320),
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F2F4),
                    borderRadius: BorderRadius.circular(323),
                  ),
                ),
              ),
              if (_currentSong != null)
                Positioned(
                  left: barWidth * (91 / 320),
                  top: 8,
                  width: barWidth * (138 / 320),
                  height: 56,
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: PillProgressPainter(
                        progress: _duration.inMilliseconds > 0
                            ? _position.inMilliseconds / _duration.inMilliseconds
                            : 0,
                        pillWidth: barWidth * (138 / 320),
                        pillHeight: 56,
                      ),
                    ),
                  ),
                ),
              Positioned(
                left: barWidth * (30 / 320),
                top: iconTop,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => setState(() => _currentIndex = 0),
                      customBorder: const CircleBorder(),
                      child: Center(
                        child: SvgPicture.string(
                          '<svg viewBox="0 0 24 24"><path fill="${_currentIndex == 0 ? '#2F84FEFF' : '#979797FF'}" d="M13.2 2.65a2 2 0 0 0-2.4 0l-7 5.25A2 2 0 0 0 3 9.5V19a2 2 0 0 0 2 2h3.9a1.1 1.1 0 0 0 1.1-1.1V15a2 2 0 1 1 4 0v4.9a1.1 1.1 0 0 0 1.1 1.1H19a2 2 0 0 0 2-2V9.5a2 2 0 0 0-.8-1.6z"/></svg>',
                          width: 22,
                          height: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: barWidth * (256 / 320),
                top: iconTop,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => setState(() => _currentIndex = 1),
                      customBorder: const CircleBorder(),
                      child: Center(
                        child: SvgPicture.string(
                          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path fill="${_currentIndex == 1 ? '#2F84FEFF' : '#979797FF'}" d="M12 2c5.523 0 10 4.477 10 10s-4.477 10-10 10S2 17.523 2 12 6.477 2 12 2m0 2a8 8 0 1 0 0 16 8 8 0 0 0 0-16m3.167 8c1.012 0 1.833.82 1.833 1.833V14a5 5 0 0 1-10 0v-.167C7 12.821 7.82 12 8.833 12zM15 14H9a3 3 0 1 0 6 0M9 7a1 1 0 0 1 .993.883L10 8v2a1 1 0 0 1-1.993.117L8 10V8a1 1 0 0 1 1-1m5.293.293a1 1 0 0 1 1.497 1.32l-.083.094-.293.293.293.293a1 1 0 0 1-1.32 1.497l-.094-.083-1-1a1 1 0 0 1-.083-1.32l.083-.094z"/></svg>',
                          width: 22,
                          height: 22,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: barWidth * (97 / 320),
                top: coverTop,
                child: ClipOval(
                  child: Container(
                    width: coverSize,
                    height: coverSize,
                    color: const Color(0xFFE8E8E8),
                    child: _buildMiniCoverImage(coverSize),
                  ),
                ),
              ),
              Positioned(
                left: barWidth * (145 / 320),
                top: coverTop + (coverSize - 32) / 2,
                width: barWidth * (74 / 320),
                child: _currentSong != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildScrollText(
                            _currentSong!.name,
                            const TextStyle(
                              color: Colors.black,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                            barWidth * (74 / 320),
                          ),
                          const SizedBox(height: 2),
                          _buildScrollText(
                            _currentSong!.artist,
                            TextStyle(
                              color: Colors.black.withValues(alpha: 0.5),
                              fontSize: 10,
                            ),
                            barWidth * (74 / 320),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '暂无播放',
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.4),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniCoverImage(double size) {
    if (_currentSong?.coverUrl == null) {
      return Image.asset(
        'assets/images/SuchMusic@1x.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    final coverUrl = _currentSong!.coverUrl!;
    final cachedImage = AudioPlayerService.cachedCover(coverUrl);
    if (cachedImage != null) {
      return Image.memory(
        cachedImage,
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    final lastCover = AudioPlayerService.lastCoverBytes;
    if (lastCover != null) {
      AudioPlayerService.preFetchCover(coverUrl).then((_) {
        if (mounted) setState(() {});
      });
      return Image.memory(
        lastCover,
        width: size,
        height: size,
        fit: BoxFit.cover,
      );
    }

    AudioPlayerService.preFetchCover(coverUrl).then((_) {
      if (mounted) setState(() {});
    });
    return Image.asset(
      'assets/images/SuchMusic@1x.png',
      width: size,
      height: size,
      fit: BoxFit.cover,
    );
  }

  Widget _buildScrollText(String text, TextStyle style, double maxWidth) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    if (textPainter.width <= maxWidth) {
      return SizedBox(
        width: maxWidth,
        height: 18,
        child: Text(text, style: style, maxLines: 1, softWrap: false),
      );
    }
    return SizedBox(
      width: maxWidth,
      height: 18,
      child: Marquee(
        text: text,
        style: style,
        velocity: 20,
        blankSpace: 60,
        fadingEdgeStartFraction: 0.06,
        fadingEdgeEndFraction: 0.06,
        pauseAfterRound: const Duration(seconds: 2),
      ),
    );
  }
}

class PillProgressPainter extends CustomPainter {
  final double progress;
  final double pillWidth;
  final double pillHeight;

  PillProgressPainter({
    required this.progress,
    required this.pillWidth,
    required this.pillHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final paint = Paint()
      ..color = const Color(0xFF2F84FE)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    final radius = pillHeight / 2;
    final path = Path();

    path.moveTo(radius, 0);
    path.lineTo(pillWidth - radius, 0);
    path.arcToPoint(
      Offset(pillWidth - radius, pillHeight),
      radius: Radius.circular(radius),
      clockwise: true,
    );
    path.lineTo(radius, pillHeight);
    path.arcToPoint(
      Offset(radius, 0),
      radius: Radius.circular(radius),
      clockwise: true,
    );

    final metric = path.computeMetrics().first;
    final totalLength = metric.length;
    final extractPath = metric.extractPath(0, totalLength * progress);

    canvas.drawPath(extractPath, paint); 
  }

  @override
  bool shouldRepaint(covariant PillProgressPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.pillWidth != pillWidth ||
        oldDelegate.pillHeight != pillHeight;
  }
}
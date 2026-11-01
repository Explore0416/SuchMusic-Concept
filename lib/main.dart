import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import 'app_keys.dart';
import 'package:flutter/services.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'screens/agreement_page.dart';
import 'screens/home_page.dart';
import 'screens/library_page.dart';
import 'screens/local_page.dart';
import 'screens/profile_page.dart';
import 'services/audio_player_handler.dart';
import 'services/audio_player_service.dart';
import 'services/band/band_service.dart';
import 'services/local_audio_intent_service.dart';
import 'services/local_lyric_service.dart';
import 'services/play_history_service.dart';
import 'services/user_library_service.dart';
import 'services/sound_effect_service.dart';
import 'services/app_init.dart';
import 'services/crash_log_service.dart';
import 'services/sources/kugou_device_service.dart';
import 'models/song_model.dart';
import 'utils/player_route.dart';
import 'utils/home_tab.dart';
import 'utils/responsive.dart';
import 'utils/navigation_guard.dart';
import 'theme/app_theme.dart';
import 'widgets/app_bottom_dock.dart';
import 'widgets/design_dialog.dart';
import 'widgets/main_side_nav.dart';
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
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
      systemNavigationBarContrastEnforced: false,
    ),
  );

  runApp(const MyApp());
  // debug: true 会挂 PrettyDioLogger 全量打印每个接口的响应体（歌单详情能打几千行），关闭
  await NeteaseMusicApi.init(debug: false);
  await AudioPlayerService().init();
  // 监听系统「打开方式 / 分享」进来的本地音频（Android）
  LocalAudioIntentService.instance.start();
  // 本地播放历史 + 手动歌词映射（**只存本机，不上传任何数据**）
  await PlayHistoryService().init();
  // 点赞歌曲 + 自建歌单（仅本机）
  await UserLibraryService.instance.init();
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
        unawaited(
          PlayHistoryService().recordCompletion(
            prev,
            completionRatio: ratio,
            skipped: AudioPlayerService().lastPlayWasSkipped,
          ),
        );
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
  // 未开启时不监听任何端口、不产生任何网络入口。
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
        navigatorKey: appNavigatorKey,
        title: 'SuchMusic概念版',
        theme: AppTheme.light(),
        debugShowCheckedModeBanner: false,
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
  StreamSubscription<bool>? _trialSub;
  SongModel? _currentSong;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;

  /// 一级页面：首页 / 本地 / 歌单 / 我的。
  /// 窄屏由底部导航坞切换，宽屏由左侧导航切换，两处共用 [_currentIndex]。
  static const List<Widget> _pages = [
    HomePage(),
    LocalPage(),
    LibraryPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    _currentSong = _audioPlayer.currentSong;
    _position = _audioPlayer.position;
    _duration = _audioPlayer.duration;
    _isPlaying = _audioPlayer.isPlaying;
    _currentSongSub = _audioPlayer.onCurrentSongChanged.listen((song) {
      if (mounted) {
        setState(() {
          _currentSong = song ?? _audioPlayer.currentSong;
          _position = _audioPlayer.position;
          _duration = _audioPlayer.duration;
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
    // 播放状态变化时重建，迷你胶囊的播放图标与进度才跟着刷新
    // 播放状态变化时重建，迷你播放卡的播放/暂停图标才跟着刷新
    _stateSub = _audioPlayer.onStateChanged.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state == PlayerState.playing);
      }
    });
    // VIP 试听片段提示：无权益（非 VIP 且免费听时长未生效）时服务端返回试听地址
    _trialSub = _audioPlayer.onTrialPlaybackChanged.listen((isTrial) {
      if (mounted && isTrial) {
        DesignToast.show(context, 'VIP歌曲试听中');
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
    _trialSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = HomeTab.useSideNav(constraints.maxWidth);

          // 宽屏（平板 / 横屏）：左侧固定导航 + 右侧内容。
          // 一级入口只有一份，宽屏不再叠底部导航坞。
          if (wide) {
            final contentMax = (constraints.maxWidth - MainSideNav.width - 64)
                .clamp(640.0, 980.0);
            return Scaffold(
              backgroundColor: AppColors.canvas,
              body: Row(
                children: [
                  _buildSideNav(bottomPadding),
                  Expanded(
                    child: SafeArea(
                      left: false,
                      bottom: false,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: contentMax),
                          child: IndexedStack(
                            index: _currentIndex,
                            children: _pages,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }

          // 窄屏：内容铺满，底部悬浮「迷你播放卡 + 导航坞」。
          return Stack(
            children: [
              Positioned.fill(
                child: IndexedStack(index: _currentIndex, children: _pages),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_currentSong != null) _buildMiniPlayer(),
                    AppBottomDock(index: _currentIndex, onSelect: _selectTab),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double get _playProgress {
    if (_duration.inMilliseconds <= 0) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  /// 切换一级入口（底部导航坞 / 侧栏共用）
  void _selectTab(int index) {
    if (_currentIndex == index) return;
    setState(() => _currentIndex = index);
  }

  Widget _buildMiniPlayer() {
    final song = _currentSong;
    if (song == null) return const SizedBox.shrink();
    return MiniPlayerCard(
      title: song.name,
      subtitle: song.artist.isEmpty ? '未知歌手' : song.artist,
      cover: _buildMiniCoverImage(44),
      isPlaying: _isPlaying,
      progress: _playProgress,
      onTap: _openPlayerPage,
      onToggle: () => _audioPlayer.togglePlayPause(),
      onSwipeNext: () => _audioPlayer.playNext(),
      onSwipePrevious: () => _audioPlayer.playPrevious(),
    );
  }

  /// 宽屏左侧导航栏（结构与样式见 [MainSideNav]）
  Widget _buildSideNav(double bottomPadding) {
    return MainSideNav(
      index: _currentIndex,
      song: _currentSong,
      isPlaying: _isPlaying,
      onSelect: _selectTab,
      onTogglePlay: () => _audioPlayer.togglePlayPause(),
      onOpenPlayer: _openPlayerPage,
      cover: _currentSong == null ? null : _buildMiniCoverImage(44),
      bottomPadding: bottomPadding,
    );
  }

  /// 打开播放页（统一入口 + 防重复打开）
  void _openPlayerPage() {
    if (NavigationGuard.isPlayerPageOpen) return;
    NavigationGuard.isPlayerPageOpen = true;
    Navigator.push(context, playerPageRoute()).then((_) {
      NavigationGuard.isPlayerPageOpen = false;
    });
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
}

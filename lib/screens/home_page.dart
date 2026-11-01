import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/app_init.dart';
import '../services/music_api_service.dart';
import '../services/play_context_service.dart';
import '../services/recommend_service.dart';
import '../services/sources/source_manager.dart';
import '../theme/app_theme.dart';
import '../utils/navigation_guard.dart';
import '../utils/player_route.dart';
import '../utils/responsive.dart';
import '../widgets/app_ui.dart';
import 'playlist_detail_page.dart';
import 'search_page.dart';

/// 首页：私人 FM 主卡 + 个性化歌单轨 + 榜单 + 歌单广场。
///
/// 视觉走「纸感暖白 + 墨色文字 + 单一钴蓝强调」：标题用大字号建立层级，
/// 内容用横向封面轨组织，避免把十几个模块平铺成一条无尽的列表。
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _apiService = MusicApiService();

  List<PlaylistModel> _rankings = [];
  bool _loadingRankings = true;
  List<SongModel> _hotSongs = [];
  bool _loadingHotSongs = true;

  /// 「猜你想听」：由**本机播放历史**算出，不上传任何数据；为空则不显示该区块
  List<SongModel> _localPicks = [];
  PlaylistModel? _hotChart;
  List<SongModel> _dailySongs = [];
  bool _loadingDailySongs = true;
  List<PlaylistModel> _squarePlaylists = [];
  bool _loadingSquare = true;
  final Random _random = Random();
  String? _fmCoverUrl;
  SongModel? _fmFirstSong;
  StreamSubscription<SongModel?>? _fmSongSub;

  @override
  void initState() {
    super.initState();
    _loadRankings();
    _loadDailySongs();
    _loadPlaylistSquare();
    _loadFmCover();
    _loadLocalPicks();
    // FM 模式切歌时，同步更新首页主卡封面
    _fmSongSub = AudioPlayerService().onCurrentSongChanged.listen((song) {
      final player = AudioPlayerService();
      if (!player.isFmMode || song == null || song.coverUrl == null) return;
      if (song.id == _fmFirstSong?.id) return;
      if (!mounted) return;
      setState(() {
        _fmFirstSong = song;
        _fmCoverUrl = song.coverUrl;
      });
    });
  }

  @override
  void dispose() {
    _fmSongSub?.cancel();
    super.dispose();
  }

  /// 「猜你想听」：本地播放历史 + 当前音源的个性化新歌混排。
  ///
  /// 本地部分完全在本机计算，不上传任何数据；新歌来自用户已登录的音源
  /// （网易云每日推荐 / 私人 FM），未登录或取不到时只用本地结果。
  Future<void> _loadLocalPicks() async {
    // 网络 / 音源异常一律静默：拿不到就整块不显示，不能冒泡成未捕获异常
    try {
      final picks = await RecommendService.instance.smartPicks(limit: 12);
      if (!mounted || picks.isEmpty) return;
      setState(() => _localPicks = picks);
    } catch (e) {
      debugPrint('⚠️ 猜你想听加载失败: $e');
    }
  }

  Future<void> _loadRankings() async {
    await ensureInitialized;
    final sm = SourceManager();
    // 酷狗音源：榜单走酷狗（否则会拿到网易云榜单却取不到歌 → 「为空或加载失败」）
    if (sm.currentSource.isKugou) {
      final rankings = await sm.source.topList();
      final hotChart = rankings.firstWhere(
        (r) => r.name.contains('热歌') || r.name.contains('飙升'),
        orElse: () => rankings.isNotEmpty
            ? rankings.first
            : const PlaylistModel(id: '', name: '', source: SongSource.kugou),
      );
      final songs = hotChart.id.isNotEmpty
          ? await sm.source.rankSongs(hotChart.id, limit: 12)
          : <SongModel>[];
      if (!mounted) return;
      setState(() {
        _rankings = rankings;
        _loadingRankings = false;
        _hotSongs = songs.take(12).toList();
        _loadingHotSongs = false;
        _hotChart = hotChart.id.isNotEmpty ? hotChart : null;
      });
      return;
    }

    final results = await Future.wait([
      _apiService.topList(),
      _apiService.playlistDetail('3778678', subCount: 12, limit: 12),
    ]);
    if (!mounted) return;
    final rankings = results[0] as List<PlaylistModel>;
    final songs = results[1] as List<SongModel>;
    final hotChart = rankings.firstWhere(
      (r) => r.name.contains('热歌'),
      orElse: () =>
          rankings.isNotEmpty ? rankings[0] : PlaylistModel(id: '', name: ''),
    );
    setState(() {
      _rankings = rankings;
      _loadingRankings = false;
      _hotSongs = songs.take(12).toList();
      _loadingHotSongs = false;
      _hotChart = hotChart.id.isNotEmpty ? hotChart : null;
    });
  }

  /// 每日推荐：匿名登录的设备账号也能获取（service 内自动处理），
  /// 请求失败时展示空态
  Future<void> _loadDailySongs() async {
    await ensureInitialized;
    try {
      final sm = SourceManager();
      // 酷狗音源：每日推荐走酷狗（否则会拿到网易云歌曲却取不到播放地址）
      final songs = sm.currentSource.isKugou
          ? await sm.source.dailyRecommend()
          : await _apiService.getDailyRecommendSongs();
      if (!mounted) return;
      setState(() {
        _dailySongs = songs.take(12).toList();
        _loadingDailySongs = false;
      });
    } catch (e) {
      debugPrint('⚠️ 获取每日推荐失败: $e');
      if (!mounted) return;
      setState(() => _loadingDailySongs = false);
    }
  }

  /// 歌单广场：每次随机取一页（'全部'+最热列表总量很大，偏移限制在安全范围
  /// 避免越界），空结果回退第一页。首页只展示 6 个，避免把整页拉成无限长。
  Future<void> _loadPlaylistSquare() async {
    await ensureInitialized;
    final offset = _random.nextInt(150) * 18;
    try {
      var playlists = await _apiService.fetchCategoryPlaylists(
        limit: 18,
        offset: offset,
      );
      if (playlists.isEmpty && offset > 0) {
        playlists = await _apiService.fetchCategoryPlaylists(limit: 18);
      }
      if (!mounted) return;
      setState(() {
        _squarePlaylists = playlists;
        _loadingSquare = false;
      });
    } catch (e) {
      debugPrint('⚠️ 歌单广场拉取失败: $e');
      if (!mounted) return;
      setState(() => _loadingSquare = false);
    }
  }

  void _refreshSquare() {
    if (_loadingSquare) return;
    setState(() => _loadingSquare = true);
    _loadPlaylistSquare();
  }

  void _openSquarePlaylist(PlaylistModel playlist) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlaylistDetailPage(playlist: playlist)),
    );
  }

  /// 私人 FM 主卡背景：取 FM 队列第一首歌的封面，失败时保留品牌渐变。
  /// 同时记住这首歌，点卡片进 FM 时直接从它开始播（/personal_fm 每次调用会刷新队列）
  Future<void> _loadFmCover() async {
    await ensureInitialized;
    try {
      final sm = SourceManager();
      // 与 FM 播放保持一致：酷狗音源用每日推荐（网易云 userRadio 的歌在酷狗下取不到地址）
      final songs = sm.currentSource.isKugou
          ? await sm.source.dailyRecommend()
          : await _apiService.userRadio();
      if (!mounted) return;
      if (songs.isNotEmpty && songs.first.coverUrl != null) {
        setState(() {
          _fmFirstSong = songs.first;
          _fmCoverUrl = songs.first.coverUrl;
        });
      }
    } catch (e) {
      debugPrint('⚠️ 获取FM封面失败: $e');
    }
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour <= 5) return '夜深了';
    if (hour <= 8) return '早上好';
    if (hour <= 11) return '上午好';
    if (hour <= 13) return '中午好';
    if (hour <= 17) return '下午好';
    if (hour <= 19) return '傍晚好';
    return '晚上好';
  }

  String _today() {
    final now = DateTime.now();
    const week = ['一', '二', '三', '四', '五', '六', '日'];
    return '${now.month} 月 ${now.day} 日  星期${week[now.weekday - 1]}';
  }

  void _openRanking(PlaylistModel ranking) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlaylistDetailPage(playlist: ranking)),
    );
  }

  void _openDailyRecommend() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistDetailPage.daily(
          coverUrl: _dailySongs.isNotEmpty ? _dailySongs.first.coverUrl : null,
        ),
      ),
    );
  }

  void _openFm() async {
    if (NavigationGuard.isPlayerPageOpen) return;
    final audioPlayer = AudioPlayerService();
    await audioPlayer.enterFmMode(startSong: _fmFirstSong);
    if (!mounted || NavigationGuard.isPlayerPageOpen) return;
    await openPlayerPage(context);
  }

  void _playSong(SongModel song) {
    final audioPlayer = AudioPlayerService();
    // 记录播放来源上下文（首页推荐/热歌→无歌单标签），供本地曲风推断使用
    PlayContextService().setSource(kind: PlaySourceKind.home);
    audioPlayer.playAndAdd(song);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: ResponsiveContent(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(
            bottom: AppLayout.bottomInsetWithPlayer,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.page,
                  0,
                  AppSpace.page,
                  AppSpace.xxl,
                ),
                child: _buildHero(),
              ),
              if (_localPicks.isNotEmpty)
                _buildSongRail(
                  title: '猜你想听',
                  subtitle: '根据本机播放记录挑选',
                  songs: _localPicks,
                ),
              _buildSongRail(
                title: '每日推荐',
                subtitle: '每天更新，为你挑 12 首',
                songs: _dailySongs,
                loading: _loadingDailySongs,
                onAction: _openDailyRecommend,
                actionLabel: '全部',
              ),
              _buildSongRail(
                title: '热歌推荐',
                songs: _hotSongs,
                loading: _loadingHotSongs,
                actionLabel: '榜单',
                onAction: _hotChart == null
                    ? null
                    : () => _openRanking(_hotChart!),
              ),
              _buildRankingRail(),
              _buildPlaylistSquare(),
              const SizedBox(height: AppSpace.xxl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.sm,
        AppSpace.md,
        AppSpace.xl,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_greeting(), style: AppType.display),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(_today(), style: AppType.caption),
                    const SizedBox(width: AppSpace.sm),
                    _SourceDot(),
                  ],
                ),
              ],
            ),
          ),
          AppIconButton(
            icon: Icons.search_rounded,
            filled: true,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SearchPage()),
            ),
            tooltip: '搜索',
          ),
        ],
      ),
    );
  }

  Widget _buildHero() {
    return GestureDetector(
      onTap: _openFm,
      // 宽屏（横屏 / 平板）下 1.86 的比例会把这张卡撑到接近半屏高，
      // 一屏只看得见一张卡。改成「宽幅横幅」：宽度照满，高度封顶，
      // 竖屏仍按原比例，保证两种形态下都是配角而不是主角。
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final height = width > 560
              ? (width / 3.2).clamp(200.0, 260.0)
              : (width / 1.86).clamp(150.0, 320.0);
          return SizedBox(height: height, child: _buildHeroCard());
        },
      ),
    );
  }

  Widget _buildHeroCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.hero),
        color: AppColors.ink,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.hero),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_fmCoverUrl != null)
              _FmCoverBackground(url: _fmCoverUrl!)
            else
              const _HeroFallback(),
            // 下压渐变，保证白色文字在任何封面上都可读
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x33000000),
                    Color(0x14000000),
                    Color(0xB3000000),
                  ],
                  stops: [0, 0.45, 1],
                ),
              ),
            ),
            Positioned(
              left: 18,
              top: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.24),
                    width: 0.7,
                  ),
                ),
                child: const Text(
                  '私人 FM',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 18,
              right: 18,
              bottom: 16,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          '为你挑选',
                          style: TextStyle(
                            fontSize: 20,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fmFirstSong?.name ?? '根据你的口味实时更新',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            height: 1.3,
                            color: Color(0xCCFFFFFF),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 30,
                      color: AppColors.ink,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 横向封面轨：标题 + 可选右侧动作 + 一排卡片。
  Widget _buildSongRail({
    required String title,
    String? subtitle,
    required List<SongModel> songs,
    bool loading = false,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final showEmpty = !loading && songs.isEmpty;
    if (showEmpty && onAction == null && songs.isEmpty) {
      // 每日推荐为空时保留区块（给重试/入口），其余空轨直接不渲染
      if (title != '每日推荐') return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(
          title: title,
          subtitle: subtitle,
          actionLabel: actionLabel,
          onAction: onAction,
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            0,
            AppSpace.page,
            AppSpace.md,
          ),
        ),
        if (loading)
          _RailSkeleton()
        else if (songs.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.page,
              0,
              AppSpace.page,
              AppSpace.xl,
            ),
            child: Text('暂无内容，稍后再试', style: AppType.caption),
          )
        else
          SizedBox(
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              itemCount: songs.length,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpace.md),
              itemBuilder: (_, i) => _SongRailCard(
                song: songs[i],
                onTap: () => _playSong(songs[i]),
              ),
            ),
          ),
        const SizedBox(height: AppSpace.xxl),
      ],
    );
  }

  Widget _buildRankingRail() {
    if (!_loadingRankings && _rankings.isEmpty) {
      return const SizedBox.shrink();
    }
    final list = _rankings.take(8).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppSectionHeader(
          title: '榜单',
          padding: EdgeInsets.fromLTRB(
            AppSpace.page,
            0,
            AppSpace.page,
            AppSpace.md,
          ),
        ),
        if (_loadingRankings)
          _RailSkeleton()
        else
          SizedBox(
            height: 172,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpace.md),
              itemBuilder: (_, i) {
                final ranking = list[i];
                return SizedBox(
                  width: 124,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openRanking(ranking),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.card),
                            child: _SongCoverImage(
                              url: ranking.coverUrl ?? '',
                              width: 124,
                              height: 124,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        Text(
                          ranking.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.body.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: AppSpace.xxl),
      ],
    );
  }

  /// 歌单广场：3 列 × 2 行，右上角「换一批」。
  Widget _buildPlaylistSquare() {
    if (!_loadingSquare && _squarePlaylists.isEmpty) {
      return const SizedBox.shrink();
    }
    final items = _squarePlaylists.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppSectionHeader(
          title: '歌单广场',
          actionLabel: '换一批',
          onAction: _loadingSquare ? null : _refreshSquare,
          padding: const EdgeInsets.fromLTRB(
            AppSpace.page,
            0,
            AppSpace.page,
            AppSpace.md,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 宽屏多放一列，避免封面被拉成巨幅；行高跟随列宽
              // （固定行高会在宽屏把正方形封面挤出格子）。
              final columns = constraints.maxWidth > 560 ? 4 : 3;
              final cardW =
                  (constraints.maxWidth - AppSpace.sm * (columns - 1)) /
                  columns;
              final count = _loadingSquare ? columns * 2 : items.length;
              return GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: AppSpace.lg,
                  crossAxisSpacing: AppSpace.sm,
                  mainAxisExtent: cardW + 48,
                ),
                itemCount: count,
                itemBuilder: (_, i) {
                  if (_loadingSquare) return _SquareSkeleton(width: cardW);
                  final playlist = items[i];
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _openSquarePlaylist(playlist),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AspectRatio(
                          aspectRatio: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                              AppRadius.row + 2,
                            ),
                            child: _SongCoverImage(
                              url: playlist.coverUrl ?? '',
                              width: cardW,
                              height: cardW,
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        Text(
                          playlist.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.caption.copyWith(
                            color: AppColors.ink,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 歌单卡片：封面 + 歌名 + 歌手，横向轨道用。
class _SongRailCard extends StatelessWidget {
  const _SongRailCard({required this.song, required this.onTap});

  final SongModel song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 132,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: _SongCoverImage(
                url: song.coverUrl ?? '',
                width: 132,
                height: 132,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              song.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.body.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              song.artist.isEmpty ? '未知歌手' : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.caption.copyWith(
                fontSize: 12,
                color: AppColors.inkTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RailSkeleton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        itemCount: 3,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpace.md),
        itemBuilder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSkeleton(width: 132, height: 132, radius: AppRadius.card),
            const SizedBox(height: AppSpace.sm),
            const AppSkeleton(width: 96, height: 12, radius: 4),
            const SizedBox(height: 6),
            const AppSkeleton(width: 60, height: 10, radius: 4),
          ],
        ),
      ),
    );
  }
}

class _SquareSkeleton extends StatelessWidget {
  const _SquareSkeleton({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 1,
          child: AppSkeleton(
            width: width,
            height: width,
            radius: AppRadius.row + 2,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        const AppSkeleton(width: 72, height: 10, radius: 4),
      ],
    );
  }
}

/// 音源标识：小圆点 + 文案，安静地待在标题下方。
class _SourceDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SongSource>(
      stream: SourceManager().onSourceChanged,
      initialData: SourceManager().currentSource,
      builder: (context, snapshot) {
        final kind = snapshot.data ?? SongSource.netease;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: const BoxDecoration(
                color: AppColors.brand,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              kind.label,
              style: AppType.caption.copyWith(color: AppColors.inkTertiary),
            ),
          ],
        );
      },
    );
  }
}

/// 无封面时的主卡底：深色渐变 + 一缕品牌色光晕，不依赖网络。
class _HeroFallback extends StatelessWidget {
  const _HeroFallback();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1B2130), Color(0xFF0E1016)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -40,
            top: -60,
            child: _GlowDot(size: 220, color: Color(0x552F5BFF)),
          ),
          Positioned(
            left: -30,
            bottom: -70,
            child: _GlowDot(size: 180, color: Color(0x33F1546B)),
          ),
        ],
      ),
    );
  }
}

class _GlowDot extends StatelessWidget {
  const _GlowDot({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    );
  }
}

class _SongCoverImage extends StatefulWidget {
  const _SongCoverImage({
    required this.url,
    required this.width,
    required this.height,
  });

  final String url;
  final double width;
  final double height;

  @override
  State<_SongCoverImage> createState() => _SongCoverImageState();
}

class _SongCoverImageState extends State<_SongCoverImage> {
  Uint8List? _imageBytes;
  bool _loading = true;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  @override
  void initState() {
    super.initState();
    if (widget.url.isEmpty) {
      _loading = false;
    } else {
      _loadImage();
    }
  }

  @override
  void didUpdateWidget(covariant _SongCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _imageBytes = null;
      _loading = widget.url.isNotEmpty;
      if (widget.url.isNotEmpty) _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final url = widget.url;
    try {
      final response = await _dio.get(
        '${url.split('?').first}?param=300y300',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      if (!mounted || url != widget.url) return;
      if (response.statusCode == 200 && response.data != null) {
        setState(() {
          _imageBytes = response.data as Uint8List;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const ColoredBox(color: Color(0xFFEDEDE9)),
      );
    }
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    return Container(
      width: widget.width,
      height: widget.height,
      color: const Color(0xFFEDEDE9),
      child: Icon(
        Icons.music_note_rounded,
        color: AppColors.inkTertiary,
        size: widget.width * 0.3,
      ),
    );
  }
}

/// 私人FM主卡背景封面（宽幅裁剪，深色遮罩由外层负责）
class _FmCoverBackground extends StatefulWidget {
  const _FmCoverBackground({required this.url});

  final String url;

  @override
  State<_FmCoverBackground> createState() => _FmCoverBackgroundState();
}

class _FmCoverBackgroundState extends State<_FmCoverBackground> {
  Uint8List? _imageBytes;

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(covariant _FmCoverBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    // FM切歌后URL变化时重新加载封面
    if (oldWidget.url != widget.url) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    final url = widget.url;
    try {
      final response = await _dio.get(
        '${url.split('?').first}?param=800y400',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      // 请求期间URL又变了就丢弃这次结果
      if (url != widget.url) return;
      if (response.statusCode == 200 && response.data != null) {
        if (mounted) {
          setState(() => _imageBytes = response.data as Uint8List);
        }
      }
    } catch (e) {
      debugPrint('🎵 FM封面加载失败: $url | 错误: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    }
    // 加载中/失败时透出底色（深灰），遮罩与文字不受影响
    return const SizedBox.expand();
  }
}

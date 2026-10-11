import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/music_api_service.dart';

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

  static final Dio _coverDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  @override
  void initState() {
    super.initState();
    _loadCover(widget.coverUrl);
    _loadSongs();
  }

  Future<void> _loadCover([String? url]) async {
    url ??= widget.playlist.coverUrl;
    if (url == null) return;
    // 统一压缩到 500px 加载（原图可达数 MB，500px 仅几十 KB），背景/头部共用
    final sizedUrl = '${url.split('?').first}?param=500y500';
    try {
      final response = await _coverDio.get(
        sizedUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
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
    final songs = widget.isDaily
        ? await _apiService.getDailyRecommendSongs()
        : await _apiService.playlistDetail(widget.playlist.id);
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
    await _audioPlayer.playSongs(_songs);
  }

  Future<void> _playSong(int index) async {
    if (index >= _songs.length) return;
    await _audioPlayer.playAndAdd(_songs[index]);
  }

  @override
  Widget build(BuildContext context) {
    // 深色页面：系统栏用浅色图标，避免 ColorOS 手势条自动垫浅色背景
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarContrastEnforced: false,
      ),
      child: Scaffold(
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_songs.isEmpty && !_loading) {
      return Stack(
        children: [
          _buildBlurredBackground(),
          _buildBackButton(),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.music_off, size: 48, color: Colors.white38),
                const SizedBox(height: 12),
                Text(
                  '歌单"${widget.playlist.name}"为空或加载失败',
                  style: const TextStyle(fontSize: 14, color: Colors.white54),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        _buildBlurredBackground(),
        _buildHeaderCover(),
        _buildBackButton(),
        _buildPlaylistInfo(),
        _buildPlayButton(),
        _buildSongCount(),
        if (_loading)
          const Positioned.fill(
            child: Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          )
        else
          _buildSongList(),
      ],
    );
  }

  Widget _buildBlurredBackground() {
    return Positioned.fill(
      child: _coverBytes != null
          ? Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(_coverBytes!, fit: BoxFit.cover),
                ClipRect(
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ],
            )
          : Container(color: const Color(0xFF1a1a2e)),
    );
  }

  Widget _buildHeaderCover() {
    return Positioned(
      left: 0,
      right: 0,
      top: -1,
      height: 218,
      child: _coverBytes != null
          ? Stack(
              fit: StackFit.expand,
              children: [
                Image.memory(_coverBytes!, fit: BoxFit.cover),
                Container(color: Colors.black.withValues(alpha: 0.25)),
              ],
            )
          : Container(color: const Color(0xFF1a1a2e)),
    );
  }

  Widget _buildBackButton() {
    final topPadding = MediaQuery.of(context).padding.top;
    return Positioned(
      left: 8,
      top: topPadding + 4,
      child: IconButton(
        icon: const Icon(Icons.arrow_back_ios, size: 20, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
    );
  }

  Widget _buildPlaylistInfo() {
    final topPadding = MediaQuery.of(context).padding.top;
    return Positioned(
      left: 25,
      top: topPadding + 92,
      right: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.playlist.name,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          if (widget.playlist.description != null &&
              widget.playlist.description!.isNotEmpty)
            Text(
              widget.playlist.description!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: Colors.white,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    final topPadding = MediaQuery.of(context).padding.top;
    return Positioned(
      right: 25,
      top: topPadding + 146,
      child: GestureDetector(
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
            colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
          ),
        ),
      ),
    );
  }

  Widget _buildSongCount() {
    final topPadding = MediaQuery.of(context).padding.top;
    final count = widget.playlist.trackCount ?? _songs.length;
    return Positioned(
      right: 75,
      top: topPadding + 151,
      child: Text(
        '$count首',
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _buildSongList() {
    return Positioned(
      left: 25,
      right: 25,
      top: 217,
      bottom: 0,
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: _songs.length,
        itemBuilder: (_, index) {
          final song = _songs[index];
          return _buildSongItem(index, song);
        },
      ),
    );
  }

  Widget _buildSongItem(int index, SongModel song) {
    return GestureDetector(
      onTap: () => _playSong(index),
      child: SizedBox(
        height: 48,
        child: Row(
          children: [
            SizedBox(
              width: 36,
              child: Text(
                '${index + 1}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.name,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: Colors.white,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (song.artist.isNotEmpty)
                    Text(
                      song.artist,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w400,
                        color: Colors.white54,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SvgPicture.asset(
              'assets/images/svg/Play.svg',
              width: 16,
              height: 16,
              colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
            ),
          ],
        ),
      ),
    );
  }
}
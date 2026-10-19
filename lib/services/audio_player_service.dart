import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/song_model.dart';
import '../utils/app_constants.dart';
import 'island_service.dart';
import 'local_lyric_service.dart';
import 'lyrics_parser.dart';
import 'music_api_service.dart';
import 'notification_lyric_service.dart';
import 'sound_effect_service.dart';
import 'sources/source_manager.dart';

// LyricLine / parseLrc 已提取至 lyrics_parser.dart，此处 re-export 保持既有引用兼容
export 'lyrics_parser.dart' show LyricLine, parseLrc;

/// 本地曲目（含解密后的 .kgm）的直接播放地址。
///
/// 本地曲目没有在线音源，**必须**走 `localUri`；否则会向 SourceManager 取到 null，
/// 导致播放队列为空、时长显示 00:00。抽成纯函数便于单测锁定该不变量。
Uri? localSourceUriOf(SongModel song) {
  final local = song.localUri;
  if (local == null || local.isEmpty) return null;
  return Uri.tryParse(local);
}

enum PlayerState { idle, loading, playing, paused, error }

enum PlayMode { loop, single, shuffle }

class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;

  static final Map<String, Uint8List> _coverCache = {};
  static final Map<String, String> _coverFileCache = {};
  static Uint8List? _lastCoverBytes;
  static final Dio _coverDio = Dio();

  static Uint8List? cachedCover(String url) => _coverCache[url];
  static Uint8List? get lastCoverBytes => _lastCoverBytes;

  static String? coverFileUri(String url) => _coverFileCache[url];

  static Future<void> preFetchCover(String url) async {
    if (_coverCache.containsKey(url)) return;
    try {
      // 压缩到 500px 加载（原图可达数 MB），缓存键仍用原始 URL
      final response = await _coverDio.get(
        '${url.split('?').first}?param=500y500',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'Accept': 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        final bytes = response.data as Uint8List;
        _coverCache[url] = bytes;
        _lastCoverBytes = bytes;

        // 保存到本地文件，用于通知栏封面显示
        try {
          final dir = await getApplicationDocumentsDirectory();
          final coverDir = Directory('${dir.path}/covers');
          if (!await coverDir.exists()) {
            await coverDir.create(recursive: true);
          }
          final fileName = Uri.parse(url).pathSegments.last;
          final file = File('${coverDir.path}/$fileName');
          if (!await file.exists()) {
            await file.writeAsBytes(bytes);
          }
          _coverFileCache[url] = file.path;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 清理封面缓存：内存映射 + 通知栏封面文件 + Flutter 图片缓存。
  /// 不清理登录数据（user_cache.json）。
  /// 返回 (清理条目数, 释放字节数)。
  static Future<(int, int)> clearCoverCache() async {
    var count = _coverCache.length;
    var bytes = 0;
    for (final data in _coverCache.values) {
      bytes += data.length;
    }
    _coverCache.clear();
    _coverFileCache.clear();

    // 通知栏封面文件（磁盘）
    try {
      final dir = await getApplicationDocumentsDirectory();
      final coverDir = Directory('${dir.path}/covers');
      if (await coverDir.exists()) {
        await for (final entity in coverDir.list()) {
          if (entity is File) {
            bytes += await entity.length();
            count += 1;
            await entity.delete();
          }
        }
      }
    } catch (_) {}

    // Flutter 图片缓存（Image 组件解码后的位图）
    bytes += PaintingBinding.instance.imageCache.currentSizeBytes;
    count += PaintingBinding.instance.imageCache.currentSize;
    PaintingBinding.instance.imageCache.clear();

    return (count, bytes);
  }

  AudioPlayerService._internal() {
    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        return;
      }
      if (state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering) {
        _updateState(PlayerState.loading);
      } else if (state.playing) {
        _updateState(PlayerState.playing);
      } else if (state.processingState == ProcessingState.ready) {
        _updateState(PlayerState.paused);
      } else {
        _updateState(PlayerState.idle);
      }
    });

    _player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        if (_isFmMode) {
          await _fetchAndPlayFm();
          return;
        }
        if (_usingConcatenatingSource) {
          if (_playMode == PlayMode.loop) {
            _currentIndex = 0;
            _currentSong = _playlist.isNotEmpty ? _playlist[0] : null;
            _currentSongController.add(_currentSong);
            await _player.seek(Duration.zero);
            await _player.play();
          } else if (_playMode == PlayMode.single && _currentSong != null) {
            await _player.seek(Duration.zero);
            await _player.play();
          } else {
            _updateState(PlayerState.idle);
          }
          return;
        }
        if (_playMode == PlayMode.single && _currentSong != null) {
          await play(_currentSong!);
        } else if (_playlist.isNotEmpty && _currentIndex >= 0) {
          _playHistory.add(_currentIndex);
          if (_playMode == PlayMode.shuffle) {
            _currentIndex = _nextShuffleIndex();
          } else {
            _currentIndex = (_currentIndex + 1) % _playlist.length;
          }
          _savePlaylist();
          await play(_playlist[_currentIndex]);
        } else {
          _updateState(PlayerState.idle);
        }
      }
    });

    _player.currentIndexStream.listen((index) {
      if (index != null && index >= 0 && index < _playlist.length) {
        _currentIndex = index;
        _captureCompletion();
        _currentSong = _playlist[index];
        _currentSongController.add(_currentSong);
        if (_currentSong!.coverUrl != null &&
            _currentSong!.coverUrl!.isNotEmpty) {
          preFetchCover(_currentSong!.coverUrl!);
        }
        _fetchLyrics(_currentSong!);
        _savePlaylist();
      }
    });

    _player.positionStream.listen((pos) {
      _position = pos;
      _positionController.add(pos);
      _updateCurrentLyric(pos);
    });

    _player.durationStream.listen((dur) {
      _duration = dur ?? Duration.zero;
      _durationController.add(dur ?? Duration.zero);
    });

    // 音效：监听 just_audio 的真实音频会话 ID。
    // 这是修复「小米 13 等现代 ROM 挂全局混音导致音效不可用」的关键链路：
    // 效果器必须绑定 App 自己的播放会话（sessionId），而非全局输出混音（0）。
    // 会话变化（含首次就绪、切歌重建会话）时通知原生，让已选音效自动重新生效。
    _player.androidAudioSessionIdStream.listen((id) {
      if (id != null && id > 0) {
        unawaited(SoundEffectService.instance.setSessionId(id));
      }
    });
  }

  static const _playlistFileName = 'playlist.json';

  Future<void> init() async {
    // 启动时应用"与其他应用同时播放"设置
    try {
      final prefs = await SharedPreferences.getInstance();
      await applyMixWithOthers(
          prefs.getBool(AppConstants.allowMixWithOthers) ?? false);
    } catch (_) {}
    await _loadPlaylist();
    // 通知/灵动岛歌词开关（读取失败走默认值）
    await NotificationLyricService.instance.init();
    // 启动时探测一次小米超级岛能力（非小米 / 失败一律静默降级）
    IslandService.instance.capability();
    // 音源路由初始化（读 prefs + 校验酷狗凭证）
    await SourceManager().init();
  }

  /// 应用"与其他应用同时播放"设置
  /// true: 混音模式（iOS mixWithOthers；Android 用 mayDuck 抢占，其他应用只降音量不停止）
  /// false: 默认独占音频焦点（其他应用会暂停）
  static Future<void> applyMixWithOthers(bool allow) async {
    try {
      final session = await AudioSession.instance;
      if (allow) {
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.mixWithOthers,
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
        ));
      } else {
        await session.configure(const AudioSessionConfiguration.music());
      }
    } catch (_) {}
  }

  Future<void> _loadPlaylist() async {
    try {
      final file = await _getPlaylistFile();
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic>) {
        final list = json['playlist'] as List<dynamic>? ?? [];
        _playlist = list
            .map((e) => SongModel.fromStorage(e as Map<String, dynamic>))
            .toList();
        _currentIndex = json['currentIndex'] as int? ?? -1;
        if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
          _currentSong = _playlist[_currentIndex];
          _currentSongController.add(_currentSong);
        }
        _playlistController.add(_playlist);
      }
    } catch (_) {}
  }

  Future<void> _savePlaylist() async {
    try {
      final file = await _getPlaylistFile();
      final data = {
        'playlist': _playlist.map((s) => s.toJson()).toList(),
        'currentIndex': _currentIndex,
      };
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  Future<File> _getPlaylistFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_playlistFileName');
  }

  final AudioPlayer _player = AudioPlayer();

  /// 底层 just_audio / ExoPlayer 的真实音频会话 ID（由 `onAudioSessionIdChanged` 驱动）。
  /// 音效（DynamicsProcessing）必须绑定此会话才能在主流安卓机型上生效；
  /// 为空表示尚未创建播放会话（此时音效 apply 会失败，待会话就绪后自动重试）。
  int? get androidAudioSessionId => _player.androidAudioSessionId;

  PlayerState _state = PlayerState.idle;
  SongModel? _currentSong;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  /// 上一首曲目在「切歌瞬间」的完成度比例 ∈[0,1]（dur<=0 时为 0）。
  /// 供 `main.dart` 结算「完成度 / 跳过」信号使用。**仅本机内存、不上传**。
  double _lastCompletionRatio = -1;

  /// 上一首曲目是否被提前切走（完成度 < skipThreshold）。
  bool _lastPlayWasSkipped = false;

  List<LyricLine> _lyrics = [];
  String _currentLyric = '';

  List<SongModel> _playlist = [];
  int _currentIndex = -1;
  PlayMode _playMode = PlayMode.loop;
  final Random _random = Random();
  List<int> _shuffleQueue = [];
  int _shuffleQueuePos = 0;
  final List<int> _playHistory = [];

  String? _lastError;

  PlayerState get state => _state;

  /// 最近一次播放失败的原因（成功开始时清空），供 UI 提示用。
  String? get lastError => _lastError;
  SongModel? get currentSong => _currentSong;
  bool get isPlaying => _state == PlayerState.playing;
  Duration get position => _position;
  Duration get duration => _duration;

  /// 上一首曲目切歌瞬间的完成度比例（-1 表示无样本）。
  double get lastCompletionRatio => _lastCompletionRatio;

  /// 上一首曲目是否被提前切走。
  bool get lastPlayWasSkipped => _lastPlayWasSkipped;
  String get currentLyric => _currentLyric;
  List<LyricLine> get lyrics => List.unmodifiable(_lyrics);
  int get currentLyricIndex {
    if (_lyrics.isEmpty) return -1;
    for (int i = _lyrics.length - 1; i >= 0; i--) {
      if (_position >= _lyrics[i].timestamp) return i;
    }
    return -1;
  }
  List<SongModel> get playlist => List.unmodifiable(_playlist);
  int get currentIndex => _currentIndex;
  PlayMode get playMode => _playMode;

  bool _isFmMode = false;
  bool get isFmMode => _isFmMode;

  bool _usingConcatenatingSource = false;

  /// 播放请求序号：异步结果应用前校验，避免快切歌时旧结果覆盖新播放
  int _playSeq = 0;

  final StreamController<bool> _fmModeController =
      StreamController<bool>.broadcast();
  Stream<bool> get onFmModeChanged => _fmModeController.stream;

  final StreamController<PlayerState> _stateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<String> _lyricController =
      StreamController<String>.broadcast();
  final StreamController<List<LyricLine>> _lyricsController =
      StreamController<List<LyricLine>>.broadcast();
  final StreamController<List<SongModel>> _playlistController =
      StreamController<List<SongModel>>.broadcast();
  final StreamController<SongModel?> _currentSongController =
      StreamController<SongModel?>.broadcast();
  final StreamController<PlayMode> _playModeController =
      StreamController<PlayMode>.broadcast();

  Stream<PlayerState> get onStateChanged => _stateController.stream;
  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<String> get onLyricChanged => _lyricController.stream;
  Stream<List<LyricLine>> get onLyricsChanged => _lyricsController.stream;
  Stream<List<SongModel>> get onPlaylistChanged => _playlistController.stream;
  Stream<SongModel?> get onCurrentSongChanged => _currentSongController.stream;
  Stream<PlayMode> get onPlayModeChanged => _playModeController.stream;

  void _updateState(PlayerState newState) {
    if (_state != newState) {
      _state = newState;
      _stateController.add(newState);
    }
  }

  void _updateCurrentLyric(Duration position) {
    if (_lyrics.isEmpty) return;

    String newLyric = '';
    for (int i = _lyrics.length - 1; i >= 0; i--) {
      if (position >= _lyrics[i].timestamp) {
        newLyric = _lyrics[i].text;
        break;
      }
    }

    if (newLyric != _currentLyric) {
      _currentLyric = newLyric;
      _lyricController.add(_currentLyric);
    }
  }

  /// 重新为当前歌曲取歌词（用户在播放页手动「搜索歌词」后调用）。
  Future<void> reloadLyrics() async {
    final song = _currentSong;
    if (song == null) return;
    await _fetchLyrics(song);
  }

  Future<void> _fetchLyrics(SongModel song) async {
    _lyrics = [];
    _currentLyric = '';
    _lyricController.add('');
    _lyricsController.add([]);

    // 优先用用户手动指定的歌词（本地音乐识别不到歌词时由用户搜索选择，仅存本机）
    String? manual;
    try {
      manual = LocalLyricService().get(song.id);
    } catch (_) {
      manual = null;
    }
    if (manual != null && manual.isNotEmpty) {
      _lyrics = parseLrc(manual);
      _lyricsController.add(List.unmodifiable(_lyrics));
      _updateCurrentLyric(_position);
      return;
    }

    // 按歌曲归属音源取歌词；失败静默无歌词（与现有行为一致，不回退音源）
    final lrcText = await SourceManager()
        .withFallback<String>(song, (src, s, strict) => src.getLyrics(s));
    if (lrcText != null && lrcText.isNotEmpty) {
      _lyrics = parseLrc(lrcText);
      _lyricsController.add(List.unmodifiable(_lyrics));
      _updateCurrentLyric(_position);
    }
  }

  Future<bool> play(SongModel song, {bool exitFm = true}) async {
    _usingConcatenatingSource = false;
    // 竞态序号：仅最后一次请求结果可被应用
    final seq = ++_playSeq;
    try {
      if (exitFm && _isFmMode) {
        await exitFmMode();
      }
      _lastError = null;
      _updateState(PlayerState.loading);
      _captureCompletion();
      _currentSong = song;
      _currentSongController.add(_currentSong);

      if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
        preFetchCover(song.coverUrl!);
      }

      await _player.stop();

      _fetchLyrics(song);

      // 本地音乐：直接用入站 Uri 播放，不请求任何在线接口
      Uri? sourceUri = localSourceUriOf(song);
      if (sourceUri == null && song.source.isLocal) {
        // 本地曲目没有地址时绝不回退在线音源：那只会拿到 404/断链，
        // 表现为 just_audio 的 "Connection aborted" / "(0) Source error"。
        _lastError = '本地文件路径已失效，请从「本地音乐」重新选择该歌曲';
        _updateState(PlayerState.error);
        return false;
      }
      if (sourceUri == null) {
        final url = await SourceManager().withFallback<String>(
            song, (src, s, strict) => src.getSongUrl(s, strict: strict));
        if (seq != _playSeq) return false; // 已切到更新请求，丢弃过期结果
        if (url == null) {
          _updateState(PlayerState.error);
          return false;
        }
        sourceUri = Uri.parse(url);
      }
      if (seq != _playSeq) return false;

      if (sourceUri.scheme == 'file') {
        // 本地文件走 setFilePath：just_audio 的原生文件通道，
        // 避免把 file:// 当网络流处理时出现 duration=00:00 / 直接失败。
        await _player
            .setFilePath(sourceUri.toFilePath(), preload: true)
            .timeout(const Duration(seconds: 15));
      } else {
        await _player
            .setAudioSource(AudioSource.uri(sourceUri))
            .timeout(const Duration(seconds: 15));
      }
      if (seq != _playSeq) return false;

      await _player.play();

      if (song.coverUrl == null || song.coverUrl!.isEmpty) {
        final detail = await SourceManager().withFallback<SongModel>(
            song, (src, s, strict) => src.getSongDetail(s));
        if (detail != null && detail.coverUrl != null) {
          _currentSong = detail;
          _currentSongController.add(_currentSong);
          preFetchCover(detail.coverUrl!);
          if (_currentIndex >= 0 && _currentIndex < _playlist.length) {
            _playlist[_currentIndex] = detail;
            _playlistController.add(_playlist);
            _savePlaylist();
          }
        }
      }

      return true;
    } on TimeoutException {
      _lastError = '加载音频超时（文件不可读或格式不受支持）';
      _updateState(PlayerState.error);
      return false;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[player] 播放失败: $e');
      _updateState(PlayerState.error);
      return false;
    }
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> resume() async {
    await _player.play();
  }

  Future<void> togglePlayPause() async {
    if (_state == PlayerState.playing) {
      await pause();
    } else if (_state == PlayerState.paused) {
      await resume();
    } else if (_currentSong != null) {
      await play(_currentSong!);
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> stop() async {
    await _player.stop();
    _captureCompletion();
    _currentSong = null;
    _currentSongController.add(null);
    _lyrics = [];
    _currentLyric = '';
    _lyricController.add('');
    _lyricsController.add([]);
    _updateState(PlayerState.idle);
  }

  /// 记录**上一首**在切歌瞬间的完成度（读取 position / duration）。
  ///
  /// 仅内存暂存，供 `main.dart` 在下一首开始时结算「完成度 / 跳过」；
  /// 失败 / 无样本时置 -1，绝不抛异常、不影响主流程。**仅本机、不上传**。
  void _captureCompletion() {
    try {
      if (_currentSong == null) {
        _lastCompletionRatio = -1;
        _lastPlayWasSkipped = false;
        return;
      }
      final dur = _duration.inMilliseconds;
      if (dur <= 0) {
        _lastCompletionRatio = 0;
        _lastPlayWasSkipped = false;
        return;
      }
      final ratio = (_position.inMilliseconds / dur).clamp(0.0, 1.0);
      _lastCompletionRatio = ratio;
      // 0.30 = RecommendationConfig.skipThreshold 默认值
      _lastPlayWasSkipped = ratio < 0.30;
    } catch (_) {
      _lastCompletionRatio = -1;
      _lastPlayWasSkipped = false;
    }
  }

  Future<bool> playAndAdd(SongModel song) async {
    if (_isFmMode) {
      await exitFmMode();
    }
    final existingIndex = _playlist.indexWhere((s) => s.id == song.id);
    if (existingIndex >= 0) {
      if (_currentIndex >= 0 && existingIndex != _currentIndex) {
        _playHistory.add(_currentIndex);
      }
      _currentIndex = existingIndex;
    } else {
      if (_currentIndex >= 0) {
        _playHistory.add(_currentIndex);
      }
      _playlist.insert(0, song);
      _currentIndex = 0;
      _playlistController.add(_playlist);
    }
    _savePlaylist();
    return play(song);
  }

  void addToPlaylist(SongModel song) {
    if (_playlist.indexWhere((s) => s.id == song.id) >= 0) return;
    _playlist.insert(0, song);
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  Future<void> playSongs(List<SongModel> songs) async {
    if (songs.isEmpty) return;
    // 竞态序号：快速切歌 / 换队列时旧结果作废
    final seq = ++_playSeq;
    _usingConcatenatingSource = true;
    if (_isFmMode) {
      await exitFmMode();
    }

    _playlist.clear();
    _playlist.addAll(songs);
    _currentIndex = 0;
    _playlistController.add(_playlist);

    _updateState(PlayerState.loading);
    _captureCompletion();
    _currentSong = songs[0];
    _currentSongController.add(_currentSong);

    if (songs[0].coverUrl != null && songs[0].coverUrl!.isNotEmpty) {
      preFetchCover(songs[0].coverUrl!);
    }

    await _player.stop();

    _fetchLyrics(songs[0]);

    final sources = <AudioSource>[];
    for (final song in songs) {
      if (seq != _playSeq) return; // 队列已切换，放弃本次构建
      // 本地音乐（含解密后的 .kgm）必须用 localUri：它没有在线音源，
      // 走 SourceManager 只会拿到 null → 队列为空 → 直接 error、时长 00:00。
      final localUri = localSourceUriOf(song);
      if (localUri != null) {
        sources.add(AudioSource.uri(localUri));
        continue;
      }
      // 本地曲目缺地址时不回退在线音源（见 play() 同名判断）
      if (song.source.isLocal) continue;
      final url = await SourceManager().withFallback<String>(
          song, (src, s, strict) => src.getSongUrl(s, strict: strict));
      if (url != null) {
        sources.add(AudioSource.uri(Uri.parse(url)));
      }
    }

    if (seq != _playSeq) return;
    if (sources.isEmpty) {
      _lastError = '没有可播放的地址：本地文件路径可能已失效，请重新扫描本地音乐';
      _updateState(PlayerState.error);
      return;
    }

    try {
      await _player
          .setAudioSource(ConcatenatingAudioSource(children: sources))
          .timeout(const Duration(seconds: 15));
      if (seq != _playSeq) return;
      await _player.play();
    } on TimeoutException {
      _lastError = '加载音频超时（文件不可读或格式不受支持）';
      _updateState(PlayerState.error);
      return;
    } catch (e) {
      _lastError = e.toString();
      debugPrint('[player] 批量播放失败: $e');
      _updateState(PlayerState.error);
      return;
    }
    _savePlaylist();
  }

  void togglePlayMode() {
    switch (_playMode) {
      case PlayMode.loop:
        _playMode = PlayMode.single;
        break;
      case PlayMode.single:
        _playMode = PlayMode.shuffle;
        _generateShuffleQueue();
        break;
      case PlayMode.shuffle:
        _playMode = PlayMode.loop;
        break;
    }
    _playModeController.add(_playMode);
  }

  /// 直接设置播放模式（手环 `playback.setMode` 的落地方法，见 ARCH §4.2）。
  ///
  /// 与 [togglePlayMode] 语义一致：改变模式并广播 `onPlayModeChanged`。
  /// 切换到乱序时同样预生成洗牌队列，保证行为与手动切换完全一致。
  /// **新增方法，不改变既有行为**。
  void setPlayMode(PlayMode mode) {
    if (_playMode == mode) return;
    _playMode = mode;
    if (mode == PlayMode.shuffle) {
      _generateShuffleQueue();
    }
    _playModeController.add(_playMode);
  }

  void _generateShuffleQueue() {
    if (_playlist.isEmpty) return;
    _shuffleQueue = List.generate(_playlist.length, (i) => i);
    for (int i = _shuffleQueue.length - 1; i > 0; i--) {
      final j = _random.nextInt(i + 1);
      final tmp = _shuffleQueue[i];
      _shuffleQueue[i] = _shuffleQueue[j];
      _shuffleQueue[j] = tmp;
    }
    final currentInQueue = _shuffleQueue.indexOf(_currentIndex);
    if (currentInQueue >= 0) {
      _shuffleQueue.removeAt(currentInQueue);
      _shuffleQueue.insert(0, _currentIndex);
    }
    _shuffleQueuePos = 0;
  }

  int _nextShuffleIndex() {
    if (_shuffleQueue.isEmpty || _playlist.isEmpty) {
      _generateShuffleQueue();
    }
    _shuffleQueuePos++;
    if (_shuffleQueuePos >= _shuffleQueue.length) {
      _generateShuffleQueue();
      _shuffleQueuePos = 1;
    }
    return _shuffleQueue[_shuffleQueuePos];
  }

  Future<void> playNext() async {
    if (_isFmMode) {
      await _fetchAndPlayFm();
      return;
    }
    if (_playlist.isEmpty || _currentIndex < 0) return;

    if (_usingConcatenatingSource && _playMode != PlayMode.shuffle) {
      await _player.seekToNext();
      return;
    }

    _playHistory.add(_currentIndex);
    if (_playMode == PlayMode.shuffle) {
      _currentIndex = _nextShuffleIndex();
    } else {
      _currentIndex = (_currentIndex + 1) % _playlist.length;
    }
    _savePlaylist();
    await play(_playlist[_currentIndex]);
  }

  Future<void> playPrevious() async {
    if (_isFmMode) return;
    if (_playlist.isEmpty || _currentIndex < 0) return;

    if (_usingConcatenatingSource && _playMode != PlayMode.shuffle) {
      await _player.seekToPrevious();
      return;
    }

    if (_playHistory.isNotEmpty) {
      _currentIndex = _playHistory.removeLast();
    } else if (_playMode == PlayMode.shuffle) {
      _playHistory.add(_currentIndex);
      _currentIndex = _nextShuffleIndex();
    } else {
      _currentIndex =
          (_currentIndex - 1 + _playlist.length) % _playlist.length;
    }
    _savePlaylist();
    await play(_playlist[_currentIndex]);
  }

  Future<void> playAtIndex(int index) async {
    if (_playlist.isEmpty || index < 0 || index >= _playlist.length) return;

    if (_usingConcatenatingSource) {
      await _player.seek(Duration.zero, index: index);
      return;
    }

    if (_currentIndex >= 0 && index != _currentIndex) {
      _playHistory.add(_currentIndex);
    }
    _currentIndex = index;
    _savePlaylist();
    await play(_playlist[_currentIndex]);
  }

  Future<void> removeFromPlaylist(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _playlist.removeAt(index);
    if (_currentIndex == index) {
      if (_playlist.isEmpty) {
        _currentIndex = -1;
        await stop();
      } else {
        _currentIndex = index.clamp(0, _playlist.length - 1);
        await play(_playlist[_currentIndex]);
      }
    } else if (_currentIndex > index) {
      _currentIndex--;
    }
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  Future<void> clearPlaylist() async {
    if (_playlist.isEmpty && !_isFmMode) return;
    _usingConcatenatingSource = false;
    if (_isFmMode) {
      _isFmMode = false;
      _fmModeController.add(false);
    }
    _playlist.clear();
    _currentIndex = -1;
    await stop();
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  /// [startSong] 指定从某首歌开始 FM（如首页卡片封面歌），
  /// 为空时走默认逻辑重新拉取 FM 队列
  Future<void> enterFmMode({SongModel? startSong}) async {
    _isFmMode = true;
    _fmModeController.add(true);
    _playlist.clear();
    _currentIndex = -1;
    _playHistory.clear();
    _playlistController.add(_playlist);
    if (startSong != null) {
      _playlist.add(startSong);
      _currentIndex = 0;
      _playlistController.add(_playlist);
      await play(startSong, exitFm: false);
      return;
    }
    await _fetchAndPlayFm();
  }

  Future<void> _fetchAndPlayFm() async {
    final sm = SourceManager();
    // FM 统一走各音源的个人电台；酷狗在**未登录 / 失败**时用
    // 「每日推荐随机取曲」兜底（网易云 userRadio 本身即个性化电台）。
    var songs = await sm.source.personalFm();
    if (songs.isEmpty && sm.currentSource.isKugou) {
      final daily = await sm.source.dailyRecommend();
      if (daily.isNotEmpty) {
        songs = [daily[Random().nextInt(daily.length)]];
      }
    }
    if (songs.isEmpty) {
      _updateState(PlayerState.error);
      return;
    }
    _playlist.clear();
    _playlist.addAll(songs);
    _currentIndex = 0;
    _playlistController.add(_playlist);
    await play(songs.first, exitFm: false);
  }

  Future<void> exitFmMode() async {
    _isFmMode = false;
    _fmModeController.add(false);
    _playlist.clear();
    _currentIndex = -1;
    _playHistory.clear();
    await stop();
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  Future<void> fmTrash() async {
    final songId = _currentSong?.id;
    if (songId != null) {
      MusicApiService().userRadioTrash(songId);
    }
    await _fetchAndPlayFm();
  }

  void dispose() {
    _player.dispose();
    _fmModeController.close();
    _stateController.close();
    _positionController.close();
    _durationController.close();
    _lyricController.close();
    _lyricsController.close();
    _playlistController.close();
    _currentSongController.close();
    _playModeController.close();
  }
}
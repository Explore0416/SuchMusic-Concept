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
import '../utils/audio_cover.dart';
import 'karaoke/karaoke_model.dart';
import 'karaoke_service.dart';
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
  static final Map<String, Future<void>> _coverFetching = {};
  static const int _coverMemoryLimit = 50; // 内存封面缓存上限（LRU 淘汰）
  static const String _localCoverPrefix = 'local://';
  static Uint8List? _lastCoverBytes;
  static final Dio _coverDio = Dio();

  /// 本地歌曲封面的缓存键（伪 URL，指向音频文件本身）
  static String localCoverKey(String path) => '$_localCoverPrefix$path';

  /// LRU 读取：命中后移到末尾，保证淘汰的是最久未用的
  static Uint8List? _coverFromMemory(String url) {
    final bytes = _coverCache.remove(url);
    if (bytes != null) {
      _coverCache[url] = bytes;
    }
    return bytes;
  }

  static Uint8List? cachedCover(String url) => _coverFromMemory(url);
  static Uint8List? get lastCoverBytes => _lastCoverBytes;

  static String? coverFileUri(String url) => _coverFileCache[url];

  static Future<void> preFetchCover(String url) async {
    if (_coverFromMemory(url) != null) return;
    // 并发去重：同一 URL 的重复请求只发一次
    final inFlight = _coverFetching[url];
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final task = _fetchAndCacheCover(url);
    _coverFetching[url] = task;
    try {
      await task;
    } finally {
      _coverFetching.remove(url);
    }
  }

  static Future<void> _fetchAndCacheCover(String url) async {
    // 本地歌曲封面：local://<音频文件路径> 伪 URL，解析内嵌图后入同一缓存链路
    if (url.startsWith(_localCoverPrefix)) {
      final path = url.substring(_localCoverPrefix.length);
      final bytes = await AudioCoverExtractor.extract(path);
      if (bytes == null || bytes.isEmpty) return;
      _coverCache[url] = bytes;
      while (_coverCache.length > _coverMemoryLimit) {
        _coverCache.remove(_coverCache.keys.first);
      }
      _lastCoverBytes = bytes;
      // 保存到本地文件，用于通知栏封面显示
      try {
        final dir = await getApplicationDocumentsDirectory();
        final coverDir = Directory('${dir.path}/covers');
        if (!await coverDir.exists()) {
          await coverDir.create(recursive: true);
        }
        final ext =
            (bytes.length > 3 && bytes[0] == 0x89) ? 'png' : 'jpg';
        final file =
            File('${coverDir.path}/local_${path.hashCode}.$ext');
        if (!await file.exists()) {
          await file.writeAsBytes(bytes);
        }
        _coverFileCache[url] = file.path;
      } catch (_) {}
      return;
    }
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
        while (_coverCache.length > _coverMemoryLimit) {
          _coverCache.remove(_coverCache.keys.first);
        }
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
    // 音效不走 just_audio 的 AudioPipeline：概念版用原生 DynamicsProcessing
    // （SoundEffectService + SoundEffectBridge），支持 10 段 PEQ 与音量键重建。
    _player = AudioPlayer();
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
            // 必须带 index: 0，否则只会从"当前最后一首"重新播放而不是回到列表开头
            await _player.seek(Duration.zero, index: 0);
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
          _pushPlayHistory(_currentIndex);
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
      // 仅拼接音源模式下播放器索引与播放列表索引一一对应；
      // 单曲模式下播放器索引恒为 0，不能映射回播放列表（否则会覆盖成第一首）
      if (!_usingConcatenatingSource) return;
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
    // 恢复逐字歌词开关与下一首预缓存开关
    try {
      final prefs = await SharedPreferences.getInstance();
      _karaokeEnabled = prefs.getBool(_karaokeEnabledPrefKey) ?? true;
      _karaokePrecacheEnabled =
          prefs.getBool(_karaokePrecacheEnabledPrefKey) ?? true;
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

  late final AudioPlayer _player;

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

  // 逐字歌词（异步生成，就绪后推送给 UI）
  KaraokeSong? _karaoke;
  StreamSubscription<KaraokeState>? _karaokeSub;
  // 逐字歌词开关（持久化）：关闭后 UI 回退普通 LRC，且不再生成逐字数据
  bool _karaokeEnabled = true;
  static const _karaokeEnabledPrefKey = 'karaokeEnabled';
  // 下一首逐字预缓存开关（持久化）：打开后每次切歌自动预缓存下一首
  bool _karaokePrecacheEnabled = false;
  static const _karaokePrecacheEnabledPrefKey = 'karaokePrecacheEnabled';
  // 等待当前歌曲对齐结束后再预缓存的监听（一次性）
  StreamSubscription<KaraokeState>? _precacheSub;
  // 当前歌词原文（重新打开逐字时复用，避免重新拉取导致歌词列表闪烁）
  String _currentLrc = '';

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
  bool get karaokeEnabled => _karaokeEnabled;
  bool get karaokePrecacheEnabled => _karaokePrecacheEnabled;

  bool _isFmMode = false;
  bool get isFmMode => _isFmMode;

  bool _usingConcatenatingSource = false;

  /// 播放请求代际：每次 play/playSongs 自增；
  /// await 返回后若代际不一致，说明已被更新的播放请求取代，应丢弃本次结果
  int _playGeneration = 0;

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
  final StreamController<KaraokeSong?> _karaokeController =
      StreamController<KaraokeSong?>.broadcast();
  final StreamController<bool> _trialController =
      StreamController<bool>.broadcast();

  Stream<PlayerState> get onStateChanged => _stateController.stream;
  Stream<Duration> get onPositionChanged => _positionController.stream;
  Stream<Duration> get onDurationChanged => _durationController.stream;
  Stream<String> get onLyricChanged => _lyricController.stream;
  Stream<List<LyricLine>> get onLyricsChanged => _lyricsController.stream;
  Stream<List<SongModel>> get onPlaylistChanged => _playlistController.stream;
  Stream<SongModel?> get onCurrentSongChanged => _currentSongController.stream;
  Stream<PlayMode> get onPlayModeChanged => _playModeController.stream;
  Stream<KaraokeSong?> get onKaraokeChanged => _karaokeController.stream;

  /// 当前播放是否为 VIP 试听片段（true=试听，false=完整播放，免费听时长生效时为 false）
  Stream<bool> get onTrialPlaybackChanged => _trialController.stream;

  /// 当前歌曲的逐字歌词（可能为 null：未生成/生成中/失败）
  KaraokeSong? get karaoke => _karaoke;

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
    _karaoke = _karaokeEnabled ? KaraokeService().cachedKaraoke(song.id) : null;
    _karaokeController.add(_karaoke);
    _karaokeSub?.cancel();
    _karaokeSub = KaraokeService().onStateChanged.listen((s) {
      if (!_karaokeEnabled) return;
      if (s.songId != _currentSong?.id) return;
      if (s.status == KaraokeStatus.ready) {
        final k = KaraokeService().cachedKaraoke(s.songId);
        if (k != null) {
          _karaoke = k;
          _karaokeController.add(k);
        }
      } else if (s.status == KaraokeStatus.failed &&
          _karaoke?.songId == s.songId) {
        _karaoke = null;
        _karaokeController.add(null);
      }
    });

    // 1) 用户手动指定的歌词优先（本地音乐识别不到时由用户搜索选择，仅存本机）
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
      _currentLrc = manual;
      await _requestKaraoke(song.id, manual, localAudioPath: song.localPath);
      return;
    }

    // 2) 按歌曲归属音源取歌词（网易云 / 酷狗各自接口）；失败静默无歌词
    final lrcText = await SourceManager()
        .withFallback<String>(song, (src, s, strict) => src.getLyrics(s));
    if (_currentSong?.id != song.id) return; // 等待期间已切歌，丢弃过期结果
    if (lrcText != null && lrcText.isNotEmpty) {
      _lyrics = parseLrc(lrcText);
      _lyricsController.add(List.unmodifiable(_lyrics));
      _updateCurrentLyric(_position);
      _currentLrc = lrcText;
      // 触发逐字对齐（后台：下载→解码→isolate 计算，就绪后经上面监听推送）
      await _requestKaraoke(song.id, lrcText, localAudioPath: song.localPath);
    }
    unawaited(_maybePrecacheNext());
  }

  /// 触发逐字对齐（后台：下载→解码→isolate 计算，就绪后经监听推送）。
  /// 逐字开关关闭时直接跳过；缓存命中立即推送。
  Future<void> _requestKaraoke(String songId, String lrcText,
      {String? localAudioPath}) async {
    if (!_karaokeEnabled) return;
    KaraokeService().attachLyrics(songId, lrcText);
    final hit = localAudioPath != null
        ? await KaraokeService().requestLocal(songId, lrcText, localAudioPath)
        : await KaraokeService().request(songId, lrcText);
    if (hit != null && _karaokeEnabled && _currentSong?.id == songId) {
      _karaoke = hit;
      _karaokeController.add(hit);
    }
  }

  /// 逐字歌词开关：关闭立即回退普通歌词；打开后立即重新生成当前歌曲逐字数据
  Future<void> setKaraokeEnabled(bool v) async {
    if (_karaokeEnabled == v) return;
    _karaokeEnabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_karaokeEnabledPrefKey, v);
    } catch (_) {}
    if (!v) {
      _karaoke = null;
      _karaokeController.add(null);
      return;
    }
    final song = _currentSong;
    if (song == null) return;
    if (_currentLrc.isNotEmpty) {
      // 复用当前歌词原文直接重新对齐，避免重新拉歌词导致歌词列表闪烁
      await _requestKaraoke(song.id, _currentLrc,
          localAudioPath: song.isLocal ? song.localPath : null);
    } else {
      _loadLyricsFor(song);
    }
  }

  /// 下一首逐字预缓存开关：打开后立即尝试预缓存；之后每次切歌自动触发
  Future<String?> setKaraokePrecacheEnabled(bool v) async {
    if (_karaokePrecacheEnabled == v) return null;
    _karaokePrecacheEnabled = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_karaokePrecacheEnabledPrefKey, v);
    } catch (_) {}
    if (!v) return null;
    return _maybePrecacheNext();
  }

  /// 预缓存协调：当前歌曲正在对齐时等它结束（就绪/失败）再预缓存，
  /// 避免抢占当前歌曲的计算位；否则立即预缓存下一首。
  /// 返回提示文案（null = 已开始后台缓存或进入等待）。
  Future<String?> _maybePrecacheNext() async {
    if (!_karaokePrecacheEnabled) return null;
    final cur = _currentSong;
    if (cur == null) return null;
    final st = KaraokeService().stateOf(cur.id)?.status;
    final computing = st == KaraokeStatus.downloading ||
        st == KaraokeStatus.decoding ||
        st == KaraokeStatus.aligning;
    if (computing) {
      _precacheSub?.cancel();
      _precacheSub = KaraokeService().onStateChanged.listen((s) {
        if (s.songId != cur.id) return;
        if (s.status == KaraokeStatus.ready ||
            s.status == KaraokeStatus.failed) {
          _precacheSub?.cancel();
          _precacheSub = null;
          _maybePrecacheNext();
        }
      });
      return null;
    }
    _precacheSub?.cancel();
    _precacheSub = null;
    return _precacheNextKaraoke();
  }

  /// 预览下一首（只读，不改变任何播放状态）；无可用下一首返回 null
  SongModel? _peekNextSong() {
    if (_playlist.isEmpty || _currentSong == null || _currentIndex < 0) {
      return null;
    }
    if (_playMode == PlayMode.shuffle) {
      // 随机队列失效时播放中会重建，这里无法预知下一首
      if (_shuffleQueue.isEmpty ||
          _shuffleQueue.any((i) => i >= _playlist.length)) {
        return null;
      }
      final pos = _shuffleQueuePos + 1;
      if (pos >= _shuffleQueue.length) {
        // 走到队尾会重洗队列；队列只剩当前一首时下一首仍是它
        return _shuffleQueue.length == 1 ? _playlist[_shuffleQueue[0]] : null;
      }
      return _playlist[_shuffleQueue[pos]];
    }
    // 顺序/单曲循环：手动切歌均按顺序下一首
    return _playlist[(_currentIndex + 1) % _playlist.length];
  }

  /// 预缓存下一首的逐字歌词（提前取歌词+对齐，切歌时秒出）。
  /// 不受逐字显示开关限制：关掉显示也可提前缓存。
  /// 返回给 UI 的提示文案；null 表示已开始后台缓存。
  Future<String?> _precacheNextKaraoke() async {
    final next = _peekNextSong();
    if (next == null) return '暂无下一首歌曲';
    if (KaraokeService().cachedKaraoke(next.id) != null) {
      return '下一首逐字歌词已缓存';
    }
    if (KaraokeService().stateOf(next.id)?.status == KaraokeStatus.failed) {
      return '下一首逐字歌词暂无法缓存';
    }
    String? lrc;
    if (next.isLocal && next.localPath != null) {
      lrc = await AudioCoverExtractor.extractLyrics(next.localPath!);
    } else {
      lrc = await MusicApiService().getLyrics(next.id);
    }
    if (lrc == null || lrc.trim().isEmpty) return '下一首没有歌词，无法缓存';
    final hit = next.isLocal && next.localPath != null
        ? await KaraokeService().requestLocal(next.id, lrc, next.localPath!)
        : await KaraokeService().request(next.id, lrc);
    if (hit != null) return '下一首逐字歌词已缓存';
    return null;
  }

  /// 清空歌词与卡拉OK状态（切歌时清掉上一首的残留）
  void _clearLyricsState() {
    _lyrics = [];
    _currentLyric = '';
    _lyricController.add('');
    _lyricsController.add([]);
    _karaoke = null;
    _currentLrc = '';
    _karaokeController.add(null);
  }

  /// 按歌曲类型加载歌词：本地歌提取内嵌/同名LRC，在线歌请求接口
  void _loadLyricsFor(SongModel song) {
    if (song.isLocal) {
      _clearLyricsState();
      _extractLocalLyrics(song);
    } else {
      _fetchLyrics(song);
    }
  }

  /// 本地歌曲歌词：同名 .lrc 文件或 mp3 内嵌 USLT 帧；
  /// 有本地音频源，直接跑逐字对齐管线（无需下载）
  Future<void> _extractLocalLyrics(SongModel song) async {
    final songId = song.id;
    _karaokeSub?.cancel();
    _karaokeSub = KaraokeService().onStateChanged.listen((s) {
      if (!_karaokeEnabled) return;
      if (s.songId != _currentSong?.id) return;
      if (s.status == KaraokeStatus.ready) {
        final k = KaraokeService().cachedKaraoke(s.songId);
        if (k != null) {
          _karaoke = k;
          _karaokeController.add(k);
        }
      } else if (s.status == KaraokeStatus.failed &&
          _karaoke?.songId == s.songId) {
        _karaoke = null;
        _karaokeController.add(null);
      }
    });
    final lrc = await AudioCoverExtractor.extractLyrics(song.localPath!);
    if (_currentSong?.id != songId) return; // 等待期间已切歌，丢弃过期结果
    if (lrc != null && lrc.isNotEmpty) {
      _lyrics = parseLrc(lrc);
      _lyricsController.add(List.unmodifiable(_lyrics));
      _updateCurrentLyric(_position);
      _currentLrc = lrc;
      // 本地文件直接送对齐管线生成逐字数据（就绪后经上面监听推送）
      await _requestKaraoke(songId, lrc, localAudioPath: song.localPath);
    }
    unawaited(_maybePrecacheNext());
  }

  Future<bool> play(SongModel song, {bool exitFm = true}) async {
    // 竞态代际：仅最后一次播放请求的结果可被应用
    final gen = ++_playGeneration;
    _usingConcatenatingSource = false;
    try {
      if (exitFm && _isFmMode) {
        _exitFmState();
      }
      _lastError = null;
      _captureCompletion();
      _updateState(PlayerState.loading);

      // 本地曲目判定：优先 localUri（解密后的 .kgm 等），其次 localPath
      final localUri = localSourceUriOf(song);
      final localPath = song.localPath;
      final localFile = (localPath != null && localPath.isNotEmpty)
          ? localPath
          : null;
      final isLocalSong = localUri != null || localFile != null ||
          song.source.isLocal;

      // 本地歌曲：注入 local:// 封面键（走内嵌封面缓存链路），不污染原对象
      final uiSong = localFile != null && song.coverUrl == null
          ? song.copyWith(coverUrl: localCoverKey(localFile))
          : song;
      _currentSong = uiSong;
      _currentSongController.add(_currentSong);

      if (uiSong.coverUrl != null && uiSong.coverUrl!.isNotEmpty) {
        preFetchCover(uiSong.coverUrl!);
      }

      await _player.stop();

      // 本地歌曲：直接播文件，跳过在线取址 / 试听判定 / 封面回填
      if (isLocalSong) {
        final target = localUri ??
            (localFile != null ? Uri.file(localFile) : null);
        if (target == null) {
          // 本地曲目没有地址时绝不回退在线音源：那只会拿到 404/断链，
          // 表现为 just_audio 的 "Connection aborted" / "(0) Source error"。
          _lastError = '本地文件路径已失效，请从「本地音乐」重新选择该歌曲';
          _updateState(PlayerState.error);
          return false;
        }
        _fetchLyrics(uiSong);
        if (target.scheme == 'file') {
          // 原生文件通道：避免把 file:// 当网络流处理时 duration=00:00
          await _player
              .setFilePath(target.toFilePath(), preload: true)
              .timeout(const Duration(seconds: 15));
        } else {
          await _player
              .setAudioSource(AudioSource.uri(target))
              .timeout(const Duration(seconds: 15));
        }
        if (gen != _playGeneration) return true;
        _trialController.add(false);
        await _player.play();
        _savePlaylist();
        return true;
      }

      _fetchLyrics(uiSong);

      // 在线曲目：按歌曲归属音源取地址（网易云 / 酷狗），严格模式下不用兜底外链
      final url = await SourceManager().withFallback<String>(
          song, (src, s, strict) => src.getSongUrl(s, strict: strict));
      if (gen != _playGeneration) {
        return true; // 等待期间用户已切歌，本次请求被取代，不算失败
      }
      if (url == null) {
        _lastError = '音频源未返回可用地址（可能版权受限或需登录）';
        _updateState(PlayerState.error);
        return false;
      }

      // 试听判定：未登录时 VIP 歌（fee=1）只能拿到试听片段
      _trialController.add(
          !MusicApiService().hasCachedUser && (song.fee ?? 0) == 1);

      await _player
          .setAudioSource(AudioSource.uri(Uri.parse(url)))
          .timeout(const Duration(seconds: 15));
      if (gen != _playGeneration) return true;

      await _player.play();

      if (song.coverUrl == null || song.coverUrl!.isEmpty) {
        final detail = await SourceManager().withFallback<SongModel>(
            song, (src, s, strict) => src.getSongDetail(s));
        if (gen != _playGeneration) return true;
        if (detail != null && detail.coverUrl != null) {
          _currentSong = detail;
          _currentSongController.add(_currentSong);
          preFetchCover(detail.coverUrl!);
          // 按 id 定位，避免请求期间播放列表变化导致改错位置
          final idx = _playlist.indexWhere((s) => s.id == song.id);
          if (idx >= 0) {
            _playlist[idx] = detail;
            _playlistController.add(_playlist);
            _savePlaylist();
          }
        }
      }

      return true;
    } on TimeoutException {
      if (gen == _playGeneration) {
        _lastError = '加载音频超时（文件不可读或格式不受支持）';
        _updateState(PlayerState.error);
      }
      return false;
    } catch (e) {
      if (gen == _playGeneration) {
        _lastError = e.toString();
        debugPrint('[player] 播放失败: $e');
        _updateState(PlayerState.error);
      }
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
    _playGeneration++; // 使进行中的 play/playSongs 请求失效
    await _player.stop();
    _captureCompletion();
    _currentSong = null;
    _currentSongController.add(null);
    _lyrics = [];
    _currentLyric = '';
    _lyricController.add('');
    _lyricsController.add([]);
    _karaoke = null;
    _karaokeController.add(null);
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
        _pushPlayHistory(_currentIndex);
      }
      _currentIndex = existingIndex;
    } else {
      _pushPlayHistory(_currentIndex);
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
    // 竞态代际：快速切歌 / 换队列时旧结果作废
    final gen = ++_playGeneration;
    _usingConcatenatingSource = true;
    if (_isFmMode) {
      _exitFmState();
    }

    // 本地歌曲：注入 local:// 封面键（走内嵌封面缓存链路），不污染原列表对象
    final displaySongs = <SongModel>[
      for (final s in songs)
        if (s.localPath != null && s.localPath!.isNotEmpty &&
            s.coverUrl == null)
          s.copyWith(coverUrl: localCoverKey(s.localPath!))
        else
          s,
    ];
    _playlist.clear();
    _playlist.addAll(displaySongs);
    _currentIndex = 0;
    _playlistController.add(_playlist);

    _updateState(PlayerState.loading);
    _captureCompletion();
    _currentSong = displaySongs[0];
    _currentSongController.add(_currentSong);

    if (displaySongs[0].coverUrl != null &&
        displaySongs[0].coverUrl!.isNotEmpty) {
      preFetchCover(displaySongs[0].coverUrl!);
    }

    await _player.stop();
    _fetchLyrics(displaySongs[0]);

    // 并行预取全部播放地址（最多 6 并发），大歌单不再长时间阻塞开播
    final urls = List<String?>.filled(songs.length, null);
    final trialFlags = List<bool>.filled(songs.length, false);
    // 未登录时 VIP 歌（fee=1）必然是试听，不依赖服务端字段
    final anonymous = !MusicApiService().hasCachedUser;
    var cursor = 0;
    Future<void> fetchWorker() async {
      while (cursor < songs.length) {
        final i = cursor++;
        final song = songs[i];
        // 本地歌曲无需在线取址
        if (localSourceUriOf(song) != null || song.source.isLocal) {
          urls[i] = 'local';
          trialFlags[i] = false;
          continue;
        }
        // 按歌曲归属音源取地址（网易云 / 酷狗），严格模式避免拿兜底断链
        final url = await SourceManager().withFallback<String>(
            song, (src, x, strict) => src.getSongUrl(x, strict: strict));
        urls[i] = url;
        trialFlags[i] = anonymous && (song.fee ?? 0) == 1;
      }
    }

    final workerCount = songs.length < 6 ? songs.length : 6;
    await Future.wait(List.generate(workerCount, (_) => fetchWorker()));
    if (gen != _playGeneration) return;

    // 取不到 URL 的歌从列表同步剔除，保证播放器索引与播放列表索引一一对应
    final playable = <SongModel>[];
    final playableTrial = <bool>[];
    final sources = <AudioSource>[];
    for (var i = 0; i < songs.length; i++) {
      final song = songs[i];
      final localUri = localSourceUriOf(song);
      final localPath = song.localPath;
      // 本地音乐（含解密后的 .kgm）优先用 localUri：它没有在线音源，
      // 走 SourceManager 只会拿到 null → 队列为空 → 直接 error、时长 00:00。
      if (localUri != null) {
        playable.add(displaySongs[i]);
        playableTrial.add(false);
        sources.add(AudioSource.uri(localUri));
        continue;
      }
      if (localPath != null && localPath.isNotEmpty) {
        playable.add(displaySongs[i]);
        playableTrial.add(false);
        sources.add(AudioSource.file(localPath));
        continue;
      }
      // 本地曲目缺地址时不回退在线音源（见 play() 同名判断）
      if (song.source.isLocal) continue;
      final url = urls[i];
      if (url != null) {
        playable.add(song);
        playableTrial.add(trialFlags[i]);
        sources.add(AudioSource.uri(Uri.parse(url)));
      }
    }

    if (gen != _playGeneration) return;
    if (playable.isEmpty || sources.isEmpty) {
      _lastError = '没有可播放的地址：本地文件路径可能已失效，请重新扫描本地音乐';
      _updateState(PlayerState.error);
      return;
    }

    if (playable.length != songs.length) {
      _playlist
        ..clear()
        ..addAll(playable);
      _playlistController.add(_playlist);
    }
    // 首歌取不到地址时顺延到下一首可播的歌
    if (_currentSong?.id != playable[0].id) {
      _currentIndex = 0;
      _currentSong = playable[0];
      _currentSongController.add(_currentSong);
      _fetchLyrics(playable[0]);
      if (playable[0].coverUrl != null && playable[0].coverUrl!.isNotEmpty) {
        preFetchCover(playable[0].coverUrl!);
      }
    }

    try {
      await _player
          .setAudioSource(ConcatenatingAudioSource(children: sources))
          .timeout(const Duration(seconds: 15));
      if (gen != _playGeneration) return;
      await _player.play();
      _trialController.add(playableTrial[0]);
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
    if (_playlist.isEmpty) {
      _shuffleQueue = [];
      _shuffleQueuePos = 0;
      return;
    }
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
    if (_playlist.isEmpty) return 0;
    // 播放列表增删后旧队列里可能残留越界索引，需要重建
    if (_shuffleQueue.isEmpty ||
        _shuffleQueue.any((i) => i >= _playlist.length)) {
      _generateShuffleQueue();
    }
    if (_shuffleQueue.isEmpty) return 0;
    _shuffleQueuePos++;
    if (_shuffleQueuePos >= _shuffleQueue.length) {
      _generateShuffleQueue();
      // 重洗后第 0 位是当前歌，从第 1 位取；列表只剩 1 首时只能取 0
      _shuffleQueuePos = _shuffleQueue.length > 1 ? 1 : 0;
    }
    return _shuffleQueue[_shuffleQueuePos];
  }

  /// 记录播放历史（供"上一首"回退），限制长度防止长会话无限增长
  void _pushPlayHistory(int index) {
    if (index < 0) return;
    _playHistory.add(index);
    if (_playHistory.length > 100) {
      _playHistory.removeAt(0);
    }
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

    _pushPlayHistory(_currentIndex);
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
      _pushPlayHistory(_currentIndex);
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
      _pushPlayHistory(_currentIndex);
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

  /// 退出 FM 的纯状态清理（不停止播放器），供 play/playSongs 内部切换时复用，
  /// 避免经过 stop() 导致自身的播放代际被作废
  void _exitFmState() {
    _isFmMode = false;
    _fmModeController.add(false);
    _playlist.clear();
    _currentIndex = -1;
    _playHistory.clear();
    _playlistController.add(_playlist);
    _savePlaylist();
  }

  Future<void> exitFmMode() async {
    _exitFmState();
    await stop();
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
    _karaokeSub?.cancel();
    _precacheSub?.cancel();
    _stateController.close();
    _positionController.close();
    _durationController.close();
    _lyricController.close();
    _lyricsController.close();
    _playlistController.close();
    _currentSongController.close();
    _playModeController.close();
    _karaokeController.close();
  }
}
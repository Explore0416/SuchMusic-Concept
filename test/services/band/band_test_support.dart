// 手环测试公共支撑：可编程伪播放器端口（不依赖 just_audio / IO / 真实网络）。
//
// 供 band_router_test.dart 等复用。
import 'dart:async';

import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/audio_player_service.dart';
import 'package:such_music/services/band/band_router.dart';

/// 可编程伪播放器端口：记录调用、可主动发射状态流（同步广播，保证确定性）。
class TestBandPort implements BandPlayerPort {
  TestBandPort({int playlistLength = 3}) {
    _playlist = List<SongModel>.generate(
      playlistLength,
      (i) => SongModel(
        id: 's$i',
        name: '歌曲$i',
        artist: '歌手$i',
        album: '专辑',
        duration: 200000,
      ),
    );
  }

  /// 调用日志（用于断言副作用次数）。
  final List<String> calls = <String>[];

  late List<SongModel> _playlist;
  PlayerState _state = PlayerState.paused;
  SongModel? _song;
  Duration _pos = Duration.zero;
  final Duration _dur = const Duration(minutes: 3);
  PlayMode _mode = PlayMode.loop;
  int _index = 0;
  final List<LyricLine> _lyrics = const [];
  final int _lyricIndex = -1;

  final StreamController<PlayerState> _stateCtrl =
      StreamController<PlayerState>.broadcast(sync: true);
  final StreamController<SongModel?> _songCtrl =
      StreamController<SongModel?>.broadcast(sync: true);
  final StreamController<Duration> _posCtrl =
      StreamController<Duration>.broadcast(sync: true);
  final StreamController<PlayMode> _modeCtrl =
      StreamController<PlayMode>.broadcast(sync: true);
  final StreamController<String> _lyricCtrl =
      StreamController<String>.broadcast(sync: true);
  final StreamController<List<LyricLine>> _lyricsCtrl =
      StreamController<List<LyricLine>>.broadcast(sync: true);
  final StreamController<List<SongModel>> _playlistCtrl =
      StreamController<List<SongModel>>.broadcast(sync: true);

  void emitState(PlayerState s) {
    _state = s;
    _stateCtrl.add(s);
  }

  void emitMode(PlayMode m) {
    _mode = m;
    _modeCtrl.add(m);
  }

  Future<void> closeAll() async {
    await _stateCtrl.close();
    await _songCtrl.close();
    await _posCtrl.close();
    await _modeCtrl.close();
    await _lyricCtrl.close();
    await _lyricsCtrl.close();
    await _playlistCtrl.close();
  }

  @override
  Future<void> resume() async {
    calls.add('resume');
    emitState(PlayerState.playing);
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    emitState(PlayerState.paused);
  }

  @override
  Future<void> togglePlayPause() async {
    calls.add('toggle');
    emitState(_state == PlayerState.playing
        ? PlayerState.paused
        : PlayerState.playing);
  }

  @override
  Future<void> playNext() async {
    calls.add('next');
    if (_playlist.isNotEmpty) {
      _index = (_index + 1) % _playlist.length;
      _song = _playlist[_index];
    }
  }

  @override
  Future<void> playPrevious() async {
    calls.add('prev');
  }

  @override
  Future<void> seek(int positionMs) async {
    calls.add('seek:$positionMs');
    _pos = Duration(milliseconds: positionMs);
  }

  @override
  Future<void> setMode(String mode) async {
    calls.add('setMode:$mode');
    _mode = playModeOf(mode);
    _modeCtrl.add(_mode);
  }

  @override
  Future<void> playAtIndex(int index) async {
    calls.add('playAtIndex:$index');
    if (index >= 0 && index < _playlist.length) {
      _index = index;
      _song = _playlist[index];
    }
  }

  @override
  Future<void> clearPlaylist() async {
    calls.add('clear');
    _playlist = <SongModel>[];
  }

  @override
  Future<List<Map<String, dynamic>>> search(String keyword, int limit) async {
    calls.add('search:$keyword');
    return List<Map<String, dynamic>>.generate(
      limit,
      (i) => <String, dynamic>{
        'id': 'r$i',
        'name': '结果$i',
        'artist': '歌手$i',
        'album': '专辑$i',
        'durationMs': 200000,
        'source': 'netease',
        'hasCover': false,
      },
    );
  }

  @override
  Future<List<String>> hotSearch() async {
    calls.add('hot');
    return const ['晴天', '周杰伦'];
  }

  @override
  Future<List<String>> searchSuggest(String keyword, int limit) async {
    calls.add('suggest:$keyword');
    return ['$keyword 相关'].take(limit).toList();
  }

  @override
  PlayerState get state => _state;

  @override
  bool get isPlaying => _state == PlayerState.playing;

  @override
  SongModel? get currentSong => _song;

  @override
  Duration get position => _pos;

  @override
  Duration get duration => _dur;

  @override
  PlayMode get playMode => _mode;

  @override
  int get playlistLength => _playlist.length;

  @override
  int get currentIndex => _index;

  @override
  List<LyricLine> get lyrics => _lyrics;

  @override
  int get currentLyricIndex => _lyricIndex;

  @override
  Stream<PlayerState> get onStateChanged => _stateCtrl.stream;

  @override
  Stream<SongModel?> get onCurrentSongChanged => _songCtrl.stream;

  @override
  Stream<Duration> get onPositionChanged => _posCtrl.stream;

  @override
  Stream<PlayMode> get onPlayModeChanged => _modeCtrl.stream;

  @override
  Stream<String> get onLyricChanged => _lyricCtrl.stream;

  @override
  Stream<List<LyricLine>> get onLyricsChanged => _lyricsCtrl.stream;

  @override
  Stream<List<SongModel>> get onPlaylistChanged => _playlistCtrl.stream;
}

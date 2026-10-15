// 手环路由单测（ARCH §3.5 / §3.11）：命令落地、幂等去重、协商与能力门禁、模式映射、节流。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/audio_player_service.dart';
import 'package:such_music/services/band/band_protocol.dart';
import 'package:such_music/services/band/band_router.dart';

/// 可编程伪播放器端口（不依赖 just_audio / IO）。
class FakePort implements BandPlayerPort {
  FakePort({int playlistLength = 3}) {
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

  // 同步广播：让路由监听器在 emit 时立即执行（保证时钟注入的确定性）
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

  void emitPosition(Duration d) => _posCtrl.add(d);
  void emitMode(PlayMode m) {
    _mode = m;
    _modeCtrl.add(m);
  }

  void emitState(PlayerState s) {
    _state = s;
    _stateCtrl.add(s);
  }

  void emitLyric(String t) => _lyricCtrl.add(t);

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
        'name': '一个比较长的搜索结果名称$i - $keyword',
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
    return const ['晴天', '周杰伦', '中国风'];
  }

  @override
  Future<List<String>> searchSuggest(String keyword, int limit) async {
    calls.add('suggest:$keyword');
    return ['$keyword 相关', '$keyword 热门'].take(limit).toList();
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

BandEnvelope _req(String id, String method, [Map<String, dynamic> payload = const {}]) =>
    BandEnvelope.request(id, method, payload: payload);

void main() {
  group('PlayMode ↔ 协议 mode 双向映射', () {
    test('往返一致', () {
      for (final m in PlayMode.values) {
        expect(playModeOf(protocolModeOf(m)), m);
      }
    });

    test('具体值', () {
      expect(protocolModeOf(PlayMode.loop), 'loop');
      expect(protocolModeOf(PlayMode.single), 'single');
      expect(protocolModeOf(PlayMode.shuffle), 'shuffle');
      expect(playModeOf('shuffle'), PlayMode.shuffle);
      expect(playModeOf('unknown'), PlayMode.loop);
    });

    test('PlayerState → 协议 state', () {
      expect(stateCodeOf(PlayerState.idle), 'idle');
      expect(stateCodeOf(PlayerState.loading), 'loading');
      expect(stateCodeOf(PlayerState.playing), 'playing');
      expect(stateCodeOf(PlayerState.paused), 'paused');
      expect(stateCodeOf(PlayerState.error), 'error');
    });
  });

  group('命令落地', () {
    test('playback.pause → port.pause，回 {state}', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRequest(_req('b-1-1', 'playback.pause'));
      expect(res.type, 'res');
      expect(port.calls, contains('pause'));
      expect(res.payload['state'], 'paused');
    });

    test('playback.setMode 落到 port 且回 mode', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRequest(
          _req('b-1-1', 'playback.setMode', {'mode': 'single'}));
      expect(port.calls, contains('setMode:single'));
      expect(res.payload['mode'], 'single');
      expect(port.playMode, PlayMode.single);
    });

    test('queue.play 越界 → E_EMPTY', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router
          .handleRequest(_req('b-1-1', 'queue.play', {'index': 99}));
      expect(res.type, 'err');
      expect(res.payload['code'], 'E_EMPTY');
      expect(port.calls.where((c) => c.startsWith('playAtIndex')), isEmpty);
    });

    test('队列为空时 playback.next → E_EMPTY', () async {
      final port = FakePort(playlistLength: 0);
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRequest(_req('b-1-1', 'playback.next'));
      expect(res.payload['code'], 'E_EMPTY');
      expect(port.calls.where((c) => c == 'next'), isEmpty);
    });

    test('未绑定端口 → E_NOT_READY', () async {
      final router = BandRouter();
      addTearDown(router.dispose);
      final res = await router.handleRequest(_req('b-1-1', 'playback.pause'));
      expect(res.type, 'err');
      expect(res.payload['code'], 'E_NOT_READY');
    });

    test('未知方法 → E_UNSUPPORTED', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRequest(_req('b-1-1', 'does.not.exist'));
      expect(res.type, 'err');
      expect(res.payload['code'], 'E_UNSUPPORTED');
    });

    test('setVolume 明确降级（V8）→ E_UNSUPPORTED missing=volume', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router
          .handleRequest(_req('b-1-1', 'playback.setVolume', {'volume': 50}));
      expect(res.type, 'err');
      expect(res.payload['code'], 'E_UNSUPPORTED');
      expect(res.payload['missing'], 'volume');
    });
  });

  group('幂等去重（同一 req.id 不产生两次副作用）', () {
    test('重复「下一首」只切一次', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final env = _req('b-0001-0007', 'playback.next');
      final r1 = await router.handleRequest(env);
      final r2 = await router.handleRequest(env);

      expect(port.calls.where((c) => c == 'next').length, 1);
      expect(r1.type, 'res');
      expect(r2.type, 'res');
      expect(identical(r1, r2), isTrue, reason: '重复 id 应回放缓存响应');
    });

    test('不同 id 各自执行', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      await router.handleRequest(_req('b-1-1', 'playback.next'));
      await router.handleRequest(_req('b-1-2', 'playback.next'));
      expect(port.calls.where((c) => c == 'next').length, 2);
    });

    test('LRU 容量淘汰后，旧 id 会重新执行', () async {
      final port = FakePort();
      final router = BandRouter(dedupCapacity: 2)..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      await router.handleRequest(_req('id-1', 'playback.next'));
      await router.handleRequest(_req('id-2', 'playback.next'));
      await router.handleRequest(_req('id-3', 'playback.next')); // 淘汰 id-1
      await router.handleRequest(_req('id-1', 'playback.next')); // 重新执行
      expect(port.calls.where((c) => c == 'next').length, 4);
    });
  });

  group('版本 / 能力协商与门禁', () {
    test('hello 协商成功 → 回 hello_ack + 生效能力=交集', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      final events = <BandEnvelope>[];
      final sub = router.onOutgoing.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRequest(_req('b-0001-0000', 'sys.hello', {
        'role': 'band',
        'proto': [1],
        'caps': ['playback', 'queue', 'volume'],
      }));
      await pumpEventQueue();

      expect(res.type, 'res');
      expect(router.sessionVersion, 1);
      expect(router.effectiveCaps, containsAll(<String>['playback', 'queue']));
      expect(router.effectiveCaps, isNot(contains('lyric')));
      expect(events.any((e) => e.event == 'sys.hello_ack'), isTrue);
    });

    test('无公共版本 → E_UNSUPPORTED + E_PROTO', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRequest(
          _req('b-0001-0000', 'sys.hello', {'proto': [2], 'caps': const []}));
      expect(res.type, 'err');
      expect(res.payload['code'], 'E_UNSUPPORTED');
      expect(res.payload['reason'], 'E_PROTO');
    });

    test('未协商到 lyric 能力 → lyric.window 被拒（missing=lyric）', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      await router.handleRequest(_req('b-0001-0000', 'sys.hello', {
        'proto': [1],
        'caps': ['playback', 'queue'],
      }));
      final res = await router.handleRequest(
          _req('b-0001-0001', 'lyric.window', {'index': 0}));
      expect(res.type, 'err');
      expect(res.payload['missing'], 'lyric');
    });
  });

  group('事件联动', () {
    test('onPlayModeChanged → player.mode', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      final events = <BandEnvelope>[];
      final sub = router.onOutgoing.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        router.dispose();
        await port.closeAll();
      });

      port.emitMode(PlayMode.shuffle);
      await pumpEventQueue();

      final modeEvent =
          events.firstWhere((e) => e.event == 'player.mode');
      expect(modeEvent.payload['mode'], 'shuffle');
    });

    test('进度节流 ≤1Hz（时钟注入，确定性）', () async {
      final port = FakePort();
      var now = 1000;
      final router = BandRouter(clock: () => now)..attach(port);
      final events = <BandEnvelope>[];
      final sub = router.onOutgoing.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        router.dispose();
        await port.closeAll();
      });

      port.emitPosition(const Duration(milliseconds: 1000)); // emit
      port.emitPosition(const Duration(milliseconds: 2000)); // 同刻 → 节流
      now = 1500;
      port.emitPosition(const Duration(milliseconds: 3000)); // +500 → 节流
      now = 2000;
      port.emitPosition(const Duration(milliseconds: 4000)); // +1000 → emit
      await pumpEventQueue();

      final progress =
          events.where((e) => e.event == 'player.progress').toList();
      expect(progress.length, 2);
      expect(progress.last.payload['positionMs'], 4000);
    });

    test('search.song 超阈值 → __chunked + xfer.chunk 分片', () async {
      final port = FakePort();
      final router = BandRouter()..attach(port);
      final events = <BandEnvelope>[];
      final sub = router.onOutgoing.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRequest(
          _req('b-1-1', 'search.song', {'keyword': '周杰伦', 'limit': 50}));
      await pumpEventQueue();

      expect(res.type, 'res');
      expect(res.payload['__chunked'], isTrue);
      expect(res.payload['total'], isA<int>());
      final chunks =
          events.where((e) => e.event == 'xfer.chunk').toList();
      expect(chunks, isNotEmpty);
      expect(chunks.first.payload['phase'], 'header');
      expect(chunks.last.payload['phase'], 'end');
    });
  });
}

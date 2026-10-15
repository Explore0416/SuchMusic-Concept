/// SuchMusic 手环通信 · 路由层（命令 → `AudioPlayerService`；状态流 → 协议事件）。
///
/// 关键决策（见 `docs/ARCH-手环通信.md` §4.2）：桥接层订阅 `AudioPlayerService()` **单例**
/// （与 `AudioPlayerHandler` 同源），命令也落在该单例上；**不**改 `AudioPlayerHandler`。
///
/// 本层还负责：
/// - 信封编解码（复用 [BandEnvelope]）与**幂等去重**（最近 64 个 `req.id` 的 LRU，
///   重复命令直接回放缓存响应、不重复执行——**保证重复点「下一首」不会跳多首**）；
/// - 版本 / 能力协商与能力门禁；
/// - 大载荷分片（`xfer.chunk`）。
///
/// 依赖通过 [BandPlayerPort] 抽象注入，便于确定性单测（时钟亦可注入）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import '../../models/song_model.dart';
import '../audio_player_service.dart';
import '../sources/source_manager.dart';
import 'band_chunk.dart';
import 'band_protocol.dart';

/// 播放器端口：把「手环命令落地」与「状态事件源」抽象出来。
///
/// 生产实现为 [AudioPlayerServicePort]（落在 `AudioPlayerService()` 单例上）；
/// 测试可注入伪实现。
abstract class BandPlayerPort {
  // ── 命令 ──────────────────────────────────────────────
  Future<void> resume();
  Future<void> pause();
  Future<void> togglePlayPause();
  Future<void> playNext();
  Future<void> playPrevious();
  Future<void> seek(int positionMs);
  Future<void> setMode(String mode);
  Future<void> playAtIndex(int index);
  Future<void> clearPlaylist();
  Future<List<Map<String, dynamic>>> search(String keyword, int limit);
  Future<List<String>> hotSearch();
  Future<List<String>> searchSuggest(String keyword, int limit);

  // ── 读取 ──────────────────────────────────────────────
  PlayerState get state;
  bool get isPlaying;
  SongModel? get currentSong;
  Duration get position;
  Duration get duration;
  PlayMode get playMode;
  int get playlistLength;
  int get currentIndex;
  List<LyricLine> get lyrics;
  int get currentLyricIndex;

  // ── 事件流 ────────────────────────────────────────────
  Stream<PlayerState> get onStateChanged;
  Stream<SongModel?> get onCurrentSongChanged;
  Stream<Duration> get onPositionChanged;
  Stream<PlayMode> get onPlayModeChanged;
  Stream<String> get onLyricChanged;
  Stream<List<LyricLine>> get onLyricsChanged;
  Stream<List<SongModel>> get onPlaylistChanged;
}

/// `AudioPlayerService()` 单例适配器（与 `AudioPlayerHandler` 同源，互不耦合）。
class AudioPlayerServicePort implements BandPlayerPort {
  AudioPlayerServicePort([AudioPlayerService? service])
      : _s = service ?? AudioPlayerService();

  final AudioPlayerService _s;

  @override
  Future<void> resume() => _s.resume();

  @override
  Future<void> pause() => _s.pause();

  @override
  Future<void> togglePlayPause() => _s.togglePlayPause();

  @override
  Future<void> playNext() => _s.playNext();

  @override
  Future<void> playPrevious() => _s.playPrevious();

  @override
  Future<void> seek(int positionMs) =>
      _s.seek(Duration(milliseconds: positionMs));

  @override
  Future<void> setMode(String mode) async {
    // 直接置模式（新增的 `setPlayMode`，文档 §4.2 建议方案之一），避免循环切换的副作用。
    _s.setPlayMode(playModeOf(mode));
  }

  @override
  Future<void> playAtIndex(int index) => _s.playAtIndex(index);

  @override
  Future<void> clearPlaylist() => _s.clearPlaylist();

  @override
  Future<List<Map<String, dynamic>>> search(String keyword, int limit) async {
    final list = await SourceManager().source.search(keyword, limit: limit);
    return list.map(songDto).toList();
  }

  @override
  Future<List<String>> hotSearch() async {
    try {
      return await SourceManager().source.hotSearch();
    } catch (_) {
      return const [];
    }
  }

  @override
  Future<List<String>> searchSuggest(String keyword, int limit) async {
    try {
      final list = await SourceManager().source.searchSuggest(keyword);
      return list.take(limit).toList();
    } catch (_) {
      return const [];
    }
  }

  @override
  PlayerState get state => _s.state;

  @override
  bool get isPlaying => _s.isPlaying;

  @override
  SongModel? get currentSong => _s.currentSong;

  @override
  Duration get position => _s.position;

  @override
  Duration get duration => _s.duration;

  @override
  PlayMode get playMode => _s.playMode;

  @override
  int get playlistLength => _s.playlist.length;

  @override
  int get currentIndex => _s.currentIndex;

  @override
  List<LyricLine> get lyrics => _s.lyrics;

  @override
  int get currentLyricIndex => _s.currentLyricIndex;

  @override
  Stream<PlayerState> get onStateChanged => _s.onStateChanged;

  @override
  Stream<SongModel?> get onCurrentSongChanged => _s.onCurrentSongChanged;

  @override
  Stream<Duration> get onPositionChanged => _s.onPositionChanged;

  @override
  Stream<PlayMode> get onPlayModeChanged => _s.onPlayModeChanged;

  @override
  Stream<String> get onLyricChanged => _s.onLyricChanged;

  @override
  Stream<List<LyricLine>> get onLyricsChanged => _s.onLyricsChanged;

  @override
  Stream<List<SongModel>> get onPlaylistChanged => _s.onPlaylistChanged;
}

/// `PlayerState` → 协议 `state`（§3.5.1）。
String stateCodeOf(PlayerState s) => switch (s) {
      PlayerState.idle => 'idle',
      PlayerState.loading => 'loading',
      PlayerState.playing => 'playing',
      PlayerState.paused => 'paused',
      PlayerState.error => 'error',
    };

/// `PlayMode` → 协议 `mode`（一一对应）。
String protocolModeOf(PlayMode m) => switch (m) {
      PlayMode.loop => 'loop',
      PlayMode.single => 'single',
      PlayMode.shuffle => 'shuffle',
    };

/// 协议 `mode` → `PlayMode`（未知值回退 [PlayMode.loop]）。
PlayMode playModeOf(String mode) => switch (mode) {
      'single' => PlayMode.single,
      'shuffle' => PlayMode.shuffle,
      _ => PlayMode.loop,
    };

/// `SongModel` → 协议 `song` DTO（字段名冻结）。
Map<String, dynamic> songDto(SongModel? s) {
  if (s == null) return const {};
  return <String, dynamic>{
    'id': s.id,
    'name': s.name,
    'artist': s.artist,
    'album': s.album,
    'durationMs': s.duration ?? 0,
    'source': s.source.code,
    'hasCover': s.coverUrl != null && s.coverUrl!.isNotEmpty,
  };
}

/// 简易 LRU 缓存（插入序 LinkedHashMap，超容量淘汰最旧）。
class BandLruCache<K, V> {
  BandLruCache(this.capacity);

  final int capacity;
  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  int get length => _map.length;

  /// 命中则返回并刷新为「最近使用」。
  V? get(K key) {
    final v = _map.remove(key);
    if (v != null) _map[key] = v;
    return v;
  }

  void put(K key, V value) {
    _map.remove(key);
    _map[key] = value;
    while (_map.length > capacity) {
      _map.remove(_map.keys.first);
    }
  }

  void clear() => _map.clear();
}

/// 手环路由：命令落地 + 事件推送 + 幂等去重 + 协商。
class BandRouter {
  BandRouter({
    int dedupCapacity = 64,
    int Function()? clock,
  })  : _dedup = BandLruCache<String, BandEnvelope>(dedupCapacity),
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  BandPlayerPort? _port;
  final BandLruCache<String, BandEnvelope> _dedup;
  final int Function() _clock;

  final StreamController<BandEnvelope> _outgoing =
      StreamController<BandEnvelope>.broadcast();
  final List<StreamSubscription<dynamic>> _subs = [];

  /// 会话协议版本（协商后固定；未协商时为 null）。
  int? sessionVersion;

  /// 生效能力（= 手环能力 ∩ 本端能力）。
  List<String> effectiveCaps = kAllCaps;

  /// 手环上报的能力。
  List<String> bandCaps = const [];

  late final String _bootId =
      ((_clock() & 0xFFFF) | 0x1000).toRadixString(16).padLeft(4, '0');
  int _seq = 0;

  /// 下行流：需要发回手环的事件 / 响应（由 `BandService` 经原生通道送出）。
  Stream<BandEnvelope> get onOutgoing => _outgoing.stream;

  /// 绑定端口：订阅 `AudioPlayerService()` 单例的事件流并转为协议事件。
  void attach(BandPlayerPort port) {
    detach();
    _port = port;
    _subs.add(port.onStateChanged.listen((s) => pushEvent('player.state', {
          'state': stateCodeOf(s),
          'playing': s == PlayerState.playing,
        })));
    _subs.add(port.onCurrentSongChanged
        .listen((s) => pushEvent('player.song', {'song': songDto(s)})));
    _subs.add(port.onPositionChanged.listen(_onPosition));
    _subs.add(port.onPlayModeChanged.listen(
        (m) => pushEvent('player.mode', {'mode': protocolModeOf(m)})));
    _subs.add(port.onLyricChanged.listen(_onLyricText));
    _subs.add(port.onLyricsChanged.listen((lines) => pushEvent('lyric.meta', {
          'songId': _port?.currentSong?.id ?? '',
          'has': lines.isNotEmpty,
          'count': lines.length,
        })));
    _subs.add(port.onPlaylistChanged.listen((list) => pushEvent('player.queue', {
          'count': list.length,
          'currentIndex': _port?.currentIndex ?? -1,
        })));
  }

  /// 解绑端口（取消全部订阅）。
  void detach() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _port = null;
  }

  /// 处理一条手环 `req`：幂等去重后分发，并缓存响应。
  Future<BandEnvelope> handleRequest(BandEnvelope req) async {
    final id = req.id;
    if (id != null) {
      final cached = _dedup.get(id);
      if (cached != null) return cached; // 幂等：重复 id 直接回放，不重复执行
    }
    BandEnvelope res;
    try {
      res = await _dispatch(req);
    } catch (e) {
      res = BandEnvelope.error(req.id ?? '', BandErrorCode.internal, e.toString());
    }
    if (id != null) _dedup.put(id, res);
    return res;
  }

  /// 主动推送事件（供 `BandService` / UI 使用）。
  void pushEvent(String event, Map<String, dynamic> payload, {String? cap}) {
    final need = cap ?? BandProtocol.eventCap(event);
    // 能力门禁：手环未协商到该能力则不发送该事件（§3.3 降级）
    if (need != null && !effectiveCaps.contains(need)) return;
    _outgoing.add(BandEnvelope.event(event, payload: payload, id: _nextId(), ts: _clock()));
  }

  /// 生成全量状态快照（§3.5.1）。
  Map<String, dynamic> stateSnapshot() {
    final p = _port;
    final lines = p?.lyrics ?? const <LyricLine>[];
    return <String, dynamic>{
      'state': stateCodeOf(p?.state ?? PlayerState.idle),
      'playing': p?.isPlaying ?? false,
      'song': songDto(p?.currentSong),
      'positionMs': p?.position.inMilliseconds ?? 0,
      'durationMs': p?.duration.inMilliseconds ?? 0,
      'mode': protocolModeOf(p?.playMode ?? PlayMode.loop),
      'volume': 80,
      'queue': <String, dynamic>{
        'count': p?.playlistLength ?? 0,
        'currentIndex': p?.currentIndex ?? -1,
      },
      'lyric': <String, dynamic>{
        'has': lines.isNotEmpty,
        'count': lines.length,
      },
      'ts': _clock(),
    };
  }

  /// 释放资源。
  void dispose() {
    detach();
    _dedup.clear();
    _outgoing.close();
  }

  // ── 事件转换 ──────────────────────────────────────────────

  int? _lastProgressMs;

  void _onPosition(Duration pos) {
    final now = _clock();
    final last = _lastProgressMs;
    // 进度节流：≤1 次/秒（§3.11）
    if (last != null && now - last < 1000) return;
    _lastProgressMs = now;
    pushEvent('player.progress', <String, dynamic>{
      'positionMs': pos.inMilliseconds,
      'durationMs': _port?.duration.inMilliseconds ?? 0,
      'ts': now,
    });
  }

  void _onLyricText(String text) {
    final p = _port;
    final idx = p?.currentLyricIndex ?? -1;
    final lines = p?.lyrics ?? const <LyricLine>[];
    final ts =
        (idx >= 0 && idx < lines.length) ? lines[idx].timestamp.inMilliseconds : 0;
    pushEvent('lyric.line', <String, dynamic>{
      'songId': p?.currentSong?.id ?? '',
      'index': idx,
      'text': text,
      't': ts,
    });
  }

  // ── 请求分发 ──────────────────────────────────────────────

  Future<BandEnvelope> _dispatch(BandEnvelope req) async {
    final id = req.id ?? '';
    final method = req.method;
    if (method == null || method.isEmpty) {
      return BandEnvelope.error(id, BandErrorCode.badReq, 'missing method');
    }

    // 能力门禁（sys.* / state.get / song.info 无能力要求）
    final needCap = BandProtocol.methodCap(method);
    if (needCap != null && !effectiveCaps.contains(needCap)) {
      return BandEnvelope(
        v: kProtocolVersion,
        id: id,
        type: 'err',
        payload: <String, dynamic>{
          'code': BandErrorCode.unsupported,
          'message': 'capability not negotiated: $needCap',
          'missing': needCap,
        },
      );
    }

    switch (method) {
      case 'sys.hello':
        return _handleHello(id, req.payload);
      case 'sys.ping':
        return BandEnvelope.response(id, payload: {'t': _clock()});
      case 'state.get':
        return BandEnvelope.response(id, payload: stateSnapshot());

      case 'playback.play':
        final p = _requirePort(id);
        if (p is BandEnvelope) return p;
        final port = p as BandPlayerPort;
        if (port.state == PlayerState.idle) {
          await port.togglePlayPause();
        } else {
          await port.resume();
        }
        return BandEnvelope.response(id, payload: {'state': stateCodeOf(port.state)});
      case 'playback.pause':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          await port.pause();
          return BandEnvelope.response(id, payload: {'state': stateCodeOf(port.state)});
        }
      case 'playback.toggle':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          await port.togglePlayPause();
          return BandEnvelope.response(id, payload: {'state': stateCodeOf(port.state)});
        }
      case 'playback.next':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          if (port.playlistLength == 0) {
            return BandEnvelope.error(id, BandErrorCode.empty, 'queue is empty');
          }
          await port.playNext();
          return BandEnvelope.response(id, payload: {'song': songDto(port.currentSong)});
        }
      case 'playback.prev':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          if (port.playlistLength == 0) {
            return BandEnvelope.error(id, BandErrorCode.empty, 'queue is empty');
          }
          await port.playPrevious();
          return BandEnvelope.response(id, payload: {'song': songDto(port.currentSong)});
        }
      case 'playback.seek':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          final pos = (req.payload['positionMs'] as num?)?.toInt() ?? 0;
          await port.seek(pos);
          return BandEnvelope.response(id, payload: {'positionMs': pos});
        }
      case 'playback.setMode':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          final mode = req.payload['mode']?.toString() ?? 'loop';
          await port.setMode(mode);
          return BandEnvelope.response(id, payload: {'mode': protocolModeOf(port.playMode)});
        }
      case 'playback.setVolume':
        // 文档 V8：`AudioPlayerService` 无 `setVolume`；明确降级，不静默忽略。
        return BandEnvelope(
          v: kProtocolVersion,
          id: id,
          type: 'err',
          payload: <String, dynamic>{
            'code': BandErrorCode.unsupported,
            'message': 'volume control not supported by phone service (ARCH V8)',
            'missing': 'volume',
          },
        );

      case 'queue.play':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          final index = (req.payload['index'] as num?)?.toInt() ?? -1;
          if (index < 0 || index >= port.playlistLength) {
            return BandEnvelope.error(id, BandErrorCode.empty, 'index out of range');
          }
          await port.playAtIndex(index);
          return BandEnvelope.response(id, payload: {'song': songDto(port.currentSong)});
        }
      case 'queue.clear':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          await (p as BandPlayerPort).clearPlaylist();
          return BandEnvelope.response(id, payload: {'ok': true});
        }

      case 'search.song':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          final keyword = req.payload['keyword']?.toString() ?? '';
          final limit = (req.payload['limit'] as num?)?.toInt() ?? 10;
          final results = await port.search(keyword, limit);
          final entity = <String, dynamic>{
            'query': keyword,
            'total': results.length,
            'results': results,
          };
          final payload = _maybeChunk('search_result', entity, {'query': keyword});
          return BandEnvelope.response(id, payload: payload);
        }
      case 'search.suggest':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          final keyword = req.payload['keyword']?.toString() ?? '';
          final limit = (req.payload['limit'] as num?)?.toInt() ?? 6;
          final items = await port.searchSuggest(keyword, limit);
          return BandEnvelope.response(id, payload: {'items': items});
        }
      case 'search.hot':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final items = await (p as BandPlayerPort).hotSearch();
          return BandEnvelope.response(id, payload: {'items': items});
        }

      case 'lyric.window':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          final port = p as BandPlayerPort;
          final songId = req.payload['songId']?.toString() ??
              port.currentSong?.id ??
              '';
          final index = (req.payload['index'] as num?)?.toInt() ??
              port.currentLyricIndex;
          final before = (req.payload['before'] as num?)?.toInt() ?? 3;
          final after = (req.payload['after'] as num?)?.toInt() ?? 8;
          final entity = _lyricWindow(port, songId, index, before, after);
          final payload =
              _maybeChunk('lyric_window', entity, {'songId': songId, 'start': entity['start']});
          return BandEnvelope.response(id, payload: payload);
        }

      case 'song.info':
        {
          final p = _requirePort(id);
          if (p is BandEnvelope) return p;
          return BandEnvelope.response(
              id, payload: {'song': songDto((p as BandPlayerPort).currentSong)});
        }

      case 'cover.get':
        return BandEnvelope(
          v: kProtocolVersion,
          id: id,
          type: 'err',
          payload: <String, dynamic>{
            'code': BandErrorCode.unsupported,
            'message': 'cover transfer not enabled',
            'missing': 'cover',
          },
        );

      case 'xfer.nack':
        // 缺片重传在传输层处理；此处仅确认（幂等）。
        return BandEnvelope.response(id, payload: {'ok': true});

      default:
        return BandEnvelope(
          v: kProtocolVersion,
          id: id,
          type: 'err',
          payload: <String, dynamic>{
            'code': BandErrorCode.unsupported,
            'message': 'unknown method: $method',
            'missing': null,
          },
        );
    }
  }

  /// 握手：版本 / 能力协商 + 回 `sys.hello_ack`。
  BandEnvelope _handleHello(String id, Map<String, dynamic> payload) {
    final bandProto = (payload['proto'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        <int>[1];
    final caps = (payload['caps'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        <String>[];

    final v = BandProtocol.negotiateVersion(bandProto, kSupportedProtocols);
    if (v == null) {
      return BandEnvelope(
        v: kProtocolVersion,
        id: id,
        type: 'err',
        payload: <String, dynamic>{
          'code': BandErrorCode.unsupported,
          'message': 'no common protocol',
          'reason': 'E_PROTO',
        },
      );
    }
    sessionVersion = v;
    bandCaps = caps;
    effectiveCaps = BandProtocol.negotiateCaps(caps, kAllCaps);

    // 回 hello_ack 事件（旁路能力门禁：握手帧无条件发送）
    _outgoing.add(BandEnvelope.event(
      'sys.hello_ack',
      id: _nextId(),
      ts: _clock(),
      payload: <String, dynamic>{
        'proto': kSupportedProtocols,
        'caps': effectiveCaps,
        'server': <String, dynamic>{'app': 'suchmusic', 'ver': '0.13.0'},
        'clock': _clock(),
      },
    ));

    return BandEnvelope.response(id, payload: <String, dynamic>{
      'ok': true,
      'v': v,
      'caps': effectiveCaps,
    });
  }

  /// 大载荷分片：超阈值返回 `__chunked` 占位，并经 `xfer.chunk` 事件下发实体。
  Map<String, dynamic> _maybeChunk(
    String kind,
    Map<String, dynamic> entity,
    Map<String, dynamic>? meta,
  ) {
    final text = jsonEncode(entity);
    final bytes = utf8.encode(text);
    if (bytes.length <= BandChunkCodec.chunkMaxBytes) {
      return entity; // 内联
    }
    final tid = 't-${_seq.toRadixString(16).padLeft(4, '0')}';
    final frames =
        BandChunkCodec.splitText(tid: tid, kind: kind, text: text, meta: meta);
    for (final frame in frames) {
      pushEvent('xfer.chunk', frame);
    }
    return <String, dynamic>{
      '__chunked': true,
      'tid': tid,
      'total': frames.length - 2,
      'bytes': bytes.length,
      'crc32': BandChunkCodec.crc32Hex(bytes),
    };
  }

  Map<String, dynamic> _lyricWindow(
    BandPlayerPort port,
    String songId,
    int index,
    int before,
    int after,
  ) {
    final lines = port.lyrics;
    if (lines.isEmpty) {
      return <String, dynamic>{'songId': songId, 'start': 0, 'lines': const []};
    }
    final center = index < 0 ? 0 : index;
    final start = (center - before).clamp(0, lines.length - 1);
    final end = (center + after + 1).clamp(start, lines.length);
    final window = <Map<String, dynamic>>[];
    for (var i = start; i < end; i++) {
      window.add(<String, dynamic>{
        't': lines[i].timestamp.inMilliseconds,
        'text': lines[i].text,
      });
    }
    return <String, dynamic>{'songId': songId, 'start': start, 'lines': window};
  }

  /// 返回端口；未绑定则返回 `E_NOT_READY` 错误信封。
  Object _requirePort(String id) {
    final p = _port;
    if (p == null) {
      return BandEnvelope.error(id, BandErrorCode.notReady, 'player not attached');
    }
    return p;
  }

  String _nextId() => 'p-$_bootId-${(_seq++).toRadixString(16).padLeft(4, '0')}';
}

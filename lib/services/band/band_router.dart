/// SuchMusic 手环通信 · 路由层（命令 → `AudioPlayerService`；状态流 → 协议事件）。
///
/// 关键决策（见 `docs/ARCH-手环通信.md` §4.2）：桥接层订阅 `AudioPlayerService()` **单例**
/// （与 `AudioPlayerHandler` 同源），命令也落在该单例上；**不**改 `AudioPlayerHandler`。
///
/// 本层还负责：
/// - 信封编解码（复用 [BandEnvelope]）与**幂等去重**（最近 64 个 `req.id` 的 LRU，
///   重复命令直接回放缓存响应、不重复执行——**保证重复点「下一首」不会跳多首**）；
/// - 版本 / 能力协商与能力门禁；
/// - **会话就绪闸门**：会话 READY（成功 `sys.hello`）之前仅放行 `sys.*`，其余回 `E_NOT_READY`；
/// - 大载荷分片（`xfer.chunk`）与**定向投递**（分片只回发触发它的会话）。
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

/// 手环（interconnect）会话的固定标识。
///
/// `BandService` 在调用 [BandRouter.handleRaw] 时以该值作为会话 id——与局域网 WS 的
/// 每连接会话（连接 id）区分开，从而让「会话就绪闸门」与「定向投递」在两条路径上一致生效。
const String kBandSession = 'band';

/// 计算下行帧 [env] 应投递的会话集合（纯函数，供各传输层复用，便于单测）。
///
/// - [BandEnvelope.target] 为 `null` → 全局事件，投递给 [onlineSessions] 中的**全部**会话（广播）；
/// - 非 `null` → 仅投递给该目标会话；目标不在线则返回空集（丢弃，避免串扰）。
Set<String> outgoingTargets(BandEnvelope env, Iterable<String> onlineSessions) {
  final target = env.target;
  if (target == null) return onlineSessions.toSet();
  return onlineSessions.contains(target) ? <String>{target} : <String>{};
}

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

  /// 已就绪的会话集合（成功完成 `sys.hello` 协商的会话 id）。
  ///
  /// 该状态**按会话隔离**：一个会话握手成功不会让其它会话“顺手”变为就绪，
  /// 从而在多客户端（局域网 WS）场景下仍能强制「先握手」。
  final Set<String> _readySessions = <String>{};

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

  /// 是否已绑定播控端口。
  bool get hasPort => _port != null;

  /// 会话是否已就绪（已成功完成 `sys.hello` 协商）。
  bool isSessionReady(String session) => _readySessions.contains(session);

  /// 重置会话就绪状态（清空 → 需重新握手）。
  ///
  /// 传输层在**建立连接 / 重连 / 断开**时调用：避免连接 id 复用导致新连接“继承”上一次的
  /// 就绪状态（否则可绕过握手闸门）。
  void resetSession(String session) => _readySessions.remove(session);

  /// 传输无关的**统一入口**：把来自任一传输（手环 interconnect / 局域网 WS）的原始帧
  /// （UTF-8 JSON 字符串）解码后路由，返回需回送的响应帧 JSON；无需回执时返回 null。
  ///
  /// 两条传输路径共用本方法 → **行为一致**；`req.id` 去重发生在 [handleRequest] 上，
  /// 故同样跨连接幂等。
  ///
  /// [session] 为发起该帧的会话标识（手环传 [kBandSession]，局域网 WS 传连接 id）。
  /// **非 null 时启用「会话就绪闸门」**：未完成 `sys.hello` 的会话发非 `sys.*` 方法会被
  /// 拒绝（`E_NOT_READY`），且不产生任何副作用。为 null 表示进程内直连（纯单测 / 内部调用），
  /// 不做闸门——**所有外部传输都必须传入真实会话 id**。
  Future<String?> handleRaw(String raw, {String? session}) async {
    BandEnvelope env;
    try {
      env = BandEnvelope.decode(raw);
    } on BandEnvelopeException {
      return null; // E_BADREQ：丢弃，不重试
    } on FormatException {
      return null; // 非法 JSON：丢弃
    }
    if (env.type != 'req') return null; // res/err/evt 无需回执
    final res = await handleRequest(env, session: session);
    return res.encode();
  }

  /// 处理一条手环 `req`：**会话就绪闸门 → 幂等去重 → 分发**，并缓存响应。
  ///
  /// [session] 语义同 [handleRaw]。
  ///
  /// 注：`sys.hello` **不参与** LRU 去重——握手必须对**发起它的会话**生效（幂等），否则
  /// 相同 `req.id` 的握手被跨会话去重回放时，新会话不会被登记为就绪，其后续命令会被闸门
  /// 全部拒绝。命令类方法（`playback.*` / `queue.*` …）的去重语义保持不变。
  Future<BandEnvelope> handleRequest(BandEnvelope req,
      {String? session}) async {
    final id = req.id;
    final method = req.method;
    final isHello = method == 'sys.hello';

    // ── 会话就绪闸门（READY 之前仅放行 `sys.*`）────────────────────────────
    // 该判定**先于**去重与分发：未握手阶段的拒绝（a）不产生任何副作用，
    // （b）不写进去重缓存，故「握手后同 id 重发」仍能正常执行——不破坏 `req.id` 幂等语义。
    if (session != null &&
        method != null &&
        !isSessionReady(session) &&
        !BandProtocol.isPreReadyMethod(method)) {
      return BandEnvelope.error(id ?? '', BandErrorCode.notReady,
          'session not ready: sys.hello required before $method');
    }

    if (id != null && !isHello) {
      final cached = _dedup.get(id);
      if (cached != null) return cached; // 幂等：重复 id 直接回放，不重复执行
    }
    BandEnvelope res;
    try {
      res = await _dispatch(req, session);
    } catch (e) {
      res = BandEnvelope.error(req.id ?? '', BandErrorCode.internal, e.toString());
    }
    if (id != null && !isHello) _dedup.put(id, res);
    return res;
  }

  /// 主动推送事件（供 `BandService` / UI 使用）。
  ///
  /// [target] 为内部路由提示：非空表示**定向投递**给该会话（如某请求触发的分片），
  /// 为 null 表示全局事件（广播给全部会话）。详见 [outgoingTargets]。
  void pushEvent(String event, Map<String, dynamic> payload,
      {String? cap, String? target}) {
    final need = cap ?? BandProtocol.eventCap(event);
    // 能力门禁：手环未协商到该能力则不发送该事件（§3.3 降级）
    if (need != null && !effectiveCaps.contains(need)) return;
    _outgoing.add(BandEnvelope.event(event,
        payload: payload, id: _nextId(), ts: _clock(), target: target));
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
    _readySessions.clear();
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

  Future<BandEnvelope> _dispatch(BandEnvelope req, String? session) async {
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
        return _handleHello(id, req.payload, session);
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
          final payload = _maybeChunk('search_result', entity, {'query': keyword},
              target: session);
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
          final payload = _maybeChunk(
              'lyric_window', entity, {'songId': songId, 'start': entity['start']},
              target: session);
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
  ///
  /// 协商成功后把 [session] 标记为**就绪**（解除会话就绪闸门）；[session] 为 null 表示
  /// 进程内直连，不登记会话。
  BandEnvelope _handleHello(
      String id, Map<String, dynamic> payload, String? session) {
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
    // 握手成功 → 该会话就绪（仅对该会话生效，不波及其它连接的闸门状态）。
    if (session != null) _readySessions.add(session);

    // 回 hello_ack 事件（旁路能力门禁：握手帧无条件发送）。
    // **定向投递**给发起握手的会话（避免广播给无关的其它连接）。
    _outgoing.add(BandEnvelope.event(
      'sys.hello_ack',
      id: _nextId(),
      ts: _clock(),
      target: session,
      payload: <String, dynamic>{
        'proto': kSupportedProtocols,
        'caps': effectiveCaps,
        'server': <String, dynamic>{'app': 'suchmusic', 'ver': '0.14.0'},
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
  ///
  /// [target] 为发起该请求的会话：分片**只定向投递**给该会话，绝不广播给其它连接
  /// （否则多客户端时 A 触发的搜索分片可能被 B 误组装）。
  Map<String, dynamic> _maybeChunk(
    String kind,
    Map<String, dynamic> entity,
    Map<String, dynamic>? meta, {
    String? target,
  }) {
    final text = jsonEncode(entity);
    final bytes = utf8.encode(text);
    if (bytes.length <= BandChunkCodec.chunkMaxBytes) {
      return entity; // 内联
    }
    final tid = 't-${_seq.toRadixString(16).padLeft(4, '0')}';
    final frames =
        BandChunkCodec.splitText(tid: tid, kind: kind, text: text, meta: meta);
    for (final frame in frames) {
      pushEvent('xfer.chunk', frame, target: target);
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

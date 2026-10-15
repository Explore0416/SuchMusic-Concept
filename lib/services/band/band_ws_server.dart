/// SuchMusic 局域网中继 · WebSocket 服务端（`dart:io`，**不新增任何第三方依赖**）。
///
/// 使用内置的 [HttpServer] + [WebSocketTransformer]：
/// - 只在**私网接口地址**上监听（经 [NetworkInterface.list] 筛选，绝不绑定 `0.0.0.0`）；
/// - 升级前先经 [LanRelayCore.handleConnect] 完成「路径 / 私网来源 / 令牌」三重校验，
///   未通过者直接以 HTTP 状态码拒绝（不升级、不留连接）；
/// - 文本帧与二进制帧都能接收：文本按 JSON 原样处理，二进制按 UTF-8 解码为 JSON；
/// - 订阅共享 [BandRouter.onOutgoing]，把手环事件与命令响应**广播**给全部 Windows 客户端。
///
/// 传输被收敛为可注入的 [RelaySocket] 抽象，便于测试替换（核心逻辑则在
/// `band_relay_core.dart` 内以纯逻辑单测覆盖，不依赖真实网络）。
library;

import 'dart:async';
import 'dart:io';

import 'band_protocol.dart';
import 'band_relay_core.dart';
import 'band_relay_security.dart';
import 'band_router.dart';

/// 传输抽象：一个已建立的客户端连接（生产实现为 `dart:io` 的 [WebSocket]）。
///
/// 抽出该接口是为了让上层不必关心具体 socket 实现；单测可直接注入伪实现。
abstract class RelaySocket {
  /// 连接 id（与 [LanRelayCore] 登记的一致）。
  String get id;

  /// 远端地址。
  String get remoteAddress;

  /// 发送一个文本帧（协议信封 JSON 走此路径）。
  void sendText(String text);

  /// 发送一个二进制帧（UTF-8 JSON 字节）。
  void sendBinary(List<int> bytes);

  /// 关闭连接。
  Future<void> close([int? code, String? reason]);
}

/// 服务启动结果。
class RelayServerInfo {
  const RelayServerInfo({required this.port, required this.addresses});

  /// 实际监听端口。
  final int port;

  /// 可连接地址列表（`ip:port`，仅私网）。
  final List<String> addresses;
}

/// 局域网 WebSocket 服务端。
class BandWsServer {
  BandWsServer({
    required this.router,
    this.preferredPort = kRelayDefaultPort,
    this.onConnectionChanged,
  });

  /// 复用的协议路由（与手环路径同一实例）。
  final BandRouter router;

  /// 期望端口（被占用时自动回退到临时端口）。
  final int preferredPort;

  /// 连接数 / 状态变化回调（供 UI 刷新）。
  final void Function()? onConnectionChanged;

  LanRelayCore? _core;
  HttpServer? _server;
  StreamSubscription<BandEnvelope>? _outgoingSub;
  final List<RelaySocket> _sockets = <RelaySocket>[];
  int _seq = 0;
  Timer? _handshakeTimer;

  /// 是否正在监听。
  bool get running => _server != null;

  /// 实际端口（未启动为 0）。
  int get port => _server?.port ?? 0;

  /// 当前令牌（未启动为 null）。**调用方不得写日志**。
  String? get token => _core?.token;

  /// 核心实例（供 UI / 测试读取连接信息）。
  LanRelayCore? get core => _core;

  /// 可连接地址（`ip:port`）。
  List<String> get addresses {
    final s = _server;
    if (s == null) return const <String>[];
    return <String>['${s.address.address}:${s.port}'];
  }

  /// 启动服务；无可用私网接口或绑定失败时返回 null（表现为「不可用」）。
  ///
  /// [token] 为空时自动生成一次性令牌。
  Future<RelayServerInfo?> start({String? token}) async {
    if (_server != null) {
      return RelayServerInfo(port: port, addresses: addresses);
    }
    final t = (token == null || token.isEmpty)
        ? RelaySecurity.generateToken()
        : token;
    final core = LanRelayCore(router: router, token: t);

    final candidates = await lanAddresses();
    if (candidates.isEmpty) return null;

    HttpServer? server;
    for (final addr in candidates) {
      try {
        server = await HttpServer.bind(addr, preferredPort, shared: false);
        break;
      } catch (_) {
        // 端口被占用 / 地址不可绑：试下一个私网地址。
      }
    }
    if (server == null) {
      // 退回到首个私网地址的临时端口。
      try {
        server = await HttpServer.bind(candidates.first, 0, shared: false);
      } catch (_) {
        return null;
      }
    }

    _core = core;
    _server = server;
    _outgoingSub = router.onOutgoing.listen(_broadcast);
    // 周期扫描握手超时，关闭未及时 sys.hello 的连接。
    _handshakeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      for (final id in core.handshakeTimeouts()) {
        _closeById(id, 1008, 'handshake timeout');
      }
    });
    server.listen(_handleRequest, onError: (_) {});
    return RelayServerInfo(port: server.port, addresses: addresses);
  }

  /// 停止服务并关闭所有连接。
  Future<void> stop() async {
    _handshakeTimer?.cancel();
    _handshakeTimer = null;
    await _outgoingSub?.cancel();
    _outgoingSub = null;
    for (final sock in List<RelaySocket>.from(_sockets)) {
      await sock.close(1001, 'server closing');
    }
    _sockets.clear();
    final s = _server;
    _server = null;
    _core = null;
    try {
      await s?.close(force: true);
    } catch (_) {}
  }

  // ── 内部 ──────────────────────────────────────────────────

  Future<void> _handleRequest(HttpRequest request) async {
    final core = _core;
    if (core == null) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await _safeClose(request);
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await _safeClose(request);
      return;
    }

    final remote = request.connectionInfo?.remoteAddress.address ?? '';
    final id = 'c-${_seq++}';
    final decision = core.handleConnect(
      connectionId: id,
      requestPath: request.uri.path,
      remoteAddress: remote,
      queryToken: request.uri.queryParameters['token'],
      authorization: request.headers.value(HttpHeaders.authorizationHeader),
    );
    if (!decision.accepted) {
      request.response.statusCode = decision.statusCode;
      await _safeClose(request);
      onConnectionChanged?.call();
      return;
    }

    WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(request);
    } catch (_) {
      core.onClose(id);
      onConnectionChanged?.call();
      return;
    }

    final socket = _IoSocket(id, ws, remote);
    _sockets.add(socket);
    onConnectionChanged?.call();
    ws.listen(
      (Object? data) => _onData(core, id, data),
      onDone: () => _onDone(core, id),
      onError: (_) => _onDone(core, id),
      cancelOnError: true,
    );
  }

  Future<void> _onData(LanRelayCore core, String id, Object? data) async {
    if (data == null) return;
    final frame = data is List<int> ? data : data.toString();
    final responses = await core.onFrame(id, frame);
    final socket = _socketById(id);
    if (socket == null) return;
    for (final f in responses) {
      socket.sendText(f);
    }
    onConnectionChanged?.call();
  }

  void _onDone(LanRelayCore core, String id) {
    core.onClose(id);
    _sockets.removeWhere((s) => s.id == id);
    onConnectionChanged?.call();
  }

  void _broadcast(BandEnvelope env) {
    final frame = env.encode();
    for (final s in List<RelaySocket>.from(_sockets)) {
      s.sendText(frame);
    }
  }

  Future<void> _closeById(String id, int code, String reason) async {
    final socket = _socketById(id);
    if (socket == null) return;
    _core?.onClose(id);
    _sockets.removeWhere((s) => s.id == id);
    await socket.close(code, reason);
    onConnectionChanged?.call();
  }

  RelaySocket? _socketById(String id) {
    for (final s in _sockets) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _safeClose(HttpRequest request) async {
    try {
      await request.response.close();
    } catch (_) {}
  }

  /// 枚举本机私网 IPv4 地址（回环与链路本地除外），**绝不返回 0.0.0.0**。
  static Future<List<InternetAddress>> lanAddresses() async {
    final result = <InternetAddress>[];
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.address == '0.0.0.0' || addr.isLoopback) continue;
          if (RelaySecurity.isPrivate(addr.address)) result.add(addr);
        }
      }
    } catch (_) {
      // 平台不支持 / 无网络：视为没有可用私网地址。
    }
    return result;
  }
}

/// [WebSocket] 的 [RelaySocket] 实现。
class _IoSocket implements RelaySocket {
  _IoSocket(this.id, this._ws, this.remoteAddress);

  @override
  final String id;

  @override
  final String remoteAddress;

  final WebSocket _ws;

  @override
  void sendText(String text) {
    try {
      _ws.add(text);
    } catch (_) {}
  }

  @override
  void sendBinary(List<int> bytes) {
    try {
      _ws.add(bytes);
    } catch (_) {}
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    try {
      await _ws.close(code, reason);
    } catch (_) {}
  }
}

/// SuchMusic 局域网中继 · 传输无关核心（连接状态机 + 统一路由）。
///
/// 设计目标（`docs/ARCH-手环通信.md` §4.3）：把「来自手环 interconnect 的消息」与
/// 「来自局域网 WS 的消息」统一到**同一套内部处理路径**——两条路径都经
/// [BandRouter.handleRaw] 解码并路由，因此：
/// - **行为一致**：同一请求在两条路径下的响应与副作用完全相同；
/// - **幂等跨连接**：`req.id` 的 LRU(64) 去重发生在共享的 [router] 上，重复命令
///   无论来自哪条连接都只执行一次。
///
/// 本类**不接触任何 socket**：连接由外部以 [RelayConnection] 的 id 描述，收发由传输层
/// （`band_ws_server.dart`）负责，从而可在单测中完全脱离真实网络。
library;

import 'dart:convert';

import 'band_protocol.dart';
import 'band_relay_security.dart';
import 'band_router.dart';

/// 约定的中继 WebSocket 路径。
const String kRelayPath = '/suchmusic';

/// 默认监听端口（ARCH §4.3）。
const int kRelayDefaultPort = 8787;

/// 连接生命周期状态。
enum RelayConnState {
  /// 已接受连接、等待 `sys.hello` 握手。
  handshaking,

  /// 握手完成（收到合法 `sys.hello`），可正常收发。
  ready,

  /// 已关闭。
  closed,
}

/// 连接裁决结果（对应 WS 升级时的处理）。
class RelayDecision {
  const RelayDecision.accept()
      : accepted = true,
        statusCode = 101,
        reason = 'accepted';

  const RelayDecision.reject(this.statusCode, this.reason) : accepted = false;

  /// 是否允许建立连接。
  final bool accepted;

  /// 101 = 升级成功；401 = 令牌无效 / 缺失；403 = 非私网来源；404 = 路径非法。
  final int statusCode;

  /// 人类可读原因（**不含令牌内容**）。
  final String reason;

  @override
  String toString() => accepted ? 'accept' : 'reject($statusCode: $reason)';
}

/// 一个已登记的中继连接（纯描述 + 状态，不持有 socket）。
class RelayConnection {
  RelayConnection({
    required this.id,
    required this.remoteAddress,
    required this.connectedAt,
  });

  /// 连接 id（由传输层分配，全局唯一）。
  final String id;

  /// 远端地址（已通过私网校验）。
  final String remoteAddress;

  /// 建立时间（ms，来源为注入时钟）。
  final int connectedAt;

  /// 当前状态。
  RelayConnState state = RelayConnState.handshaking;

  /// 握手 `sys.hello` 中上报的角色（`windows` / `band` / …）。
  String? role;

  /// 最近一次收到帧的时间（ms）。
  int? lastSeenAt;
}

/// 局域网中继核心：与传输无关，可注入 [BandRouter] 与时钟，确定性单测。
class LanRelayCore {
  LanRelayCore({
    required this.router,
    required this.token,
    this.clock,
    this.path = kRelayPath,
    this.handshakeTimeoutMs = 5000,
  });

  /// 复用的协议路由（与手环 interconnect 路径**同一个实例** → 幂等去重跨连接生效）。
  final BandRouter router;

  /// 当前配对令牌（可经 [LanRelayCore] 重建或由门面在轮换时替换）。
  String token;

  /// 注入时钟（默认系统毫秒时钟）。
  final int Function()? clock;

  /// 只接受该 WS 路径，其余 404。
  final String path;

  /// 握手超时（ms）：连接建立后需在此时间内收到 `sys.hello`。
  final int handshakeTimeoutMs;

  final Map<String, RelayConnection> _conns = <String, RelayConnection>{};
  RelayConnection? _last;

  /// 当前在线连接数。
  int get connectionCount => _conns.length;

  /// 全部在线连接。
  Iterable<RelayConnection> get connections => _conns.values;

  /// 最近一次建立（或被接受）的连接。
  RelayConnection? get lastConnection => _last;

  /// 最近一次连接结果描述（供 UI 展示，**不含令牌**）。
  String lastConnectionSummary = '暂无';

  int _now() => (clock ?? () => DateTime.now().millisecondsSinceEpoch)();

  /// 处理一次连接请求：依次校验 **路径 → 私网来源 → 令牌**，全部通过才登记连接。
  ///
  /// 任一步失败即拒绝（返回对应状态码），**且不登记连接**（实现「否则立即断开」）。
  RelayDecision handleConnect({
    required String connectionId,
    required String requestPath,
    required String remoteAddress,
    String? queryToken,
    String? authorization,
  }) {
    if (requestPath != path) {
      lastConnectionSummary = '拒绝：路径非法';
      return const RelayDecision.reject(404, 'not found');
    }
    if (!RelaySecurity.isPrivate(remoteAddress)) {
      lastConnectionSummary = '拒绝：非局域网来源';
      return const RelayDecision.reject(403, 'non-private source rejected');
    }
    final presented = RelaySecurity.extractToken(
      queryToken: queryToken,
      authorization: authorization,
    );
    if (!RelaySecurity.verifyToken(token, presented)) {
      // 注意：**不记录令牌本身**，仅记录校验失败的事实。
      lastConnectionSummary = '拒绝：令牌校验失败';
      return const RelayDecision.reject(401, 'invalid or missing token');
    }
    final conn = RelayConnection(
      id: connectionId,
      remoteAddress: remoteAddress,
      connectedAt: _now(),
    );
    _conns[connectionId] = conn;
    _last = conn;
    lastConnectionSummary = '已连接 ${conn.remoteAddress}';
    return const RelayDecision.accept();
  }

  /// 收到一帧（文本 [String] 或二进制 `List<int>`）：解码 → 统一路由 → 返回需回送的帧。
  ///
  /// 与手环 interconnect 路径共用 [BandRouter.handleRaw]，**行为完全一致**。
  /// 无响应（res/err/evt 或非法帧）时返回空列表。
  Future<List<String>> onFrame(String connectionId, Object frame) async {
    final conn = _conns[connectionId];
    if (conn == null) return const <String>[];
    conn.lastSeenAt = _now();

    final raw = decodeFrame(frame);
    if (raw == null) return const <String>[];

    _maybeAdvanceHandshake(conn, raw);

    final response = await router.handleRaw(raw);
    return response == null ? const <String>[] : <String>[response];
  }

  /// 连接关闭：从登记表移除，状态置 [RelayConnState.closed]。
  void onClose(String connectionId) {
    final conn = _conns.remove(connectionId);
    if (conn != null) {
      conn.state = RelayConnState.closed;
      lastConnectionSummary = '已断开 ${conn.remoteAddress}';
    }
  }

  /// 握手超时扫描：返回所有「仍处于 [RelayConnState.handshaking] 且已超时」的连接 id。
  ///
  /// 调用方（传输层）据返回值关闭这些连接。
  List<String> handshakeTimeouts() {
    final now = _now();
    final expired = <String>[];
    for (final c in _conns.values) {
      if (c.state == RelayConnState.handshaking &&
          now - c.connectedAt > handshakeTimeoutMs) {
        expired.add(c.id);
      }
    }
    return expired;
  }

  /// 把帧标准化为字符串：文本帧原样返回；二进制帧按 UTF-8 解码；其余返回 null。
  static String? decodeFrame(Object frame) {
    if (frame is String) return frame;
    if (frame is List<int>) {
      try {
        return utf8.decode(frame);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _maybeAdvanceHandshake(RelayConnection conn, String raw) {
    if (conn.state != RelayConnState.handshaking) return;
    try {
      final env = BandEnvelope.decode(raw);
      if (env.type == 'req' && env.method == 'sys.hello') {
        conn.state = RelayConnState.ready;
        conn.role = env.payload['role']?.toString();
        lastConnectionSummary = '已就绪（${conn.role ?? 'unknown'}）';
      }
    } catch (_) {
      // 非法帧不推进握手，交由 handleRaw 统一丢弃（E_BADREQ）。
    }
  }
}

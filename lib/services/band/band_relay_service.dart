/// SuchMusic 局域网中继 · 服务门面（对 UI 暴露开关 / 地址 / 令牌 / 状态）。
///
/// 组合 [BandWsServer]（传输）与共享的 [BandRouter]（业务路由，与手环路径同源）：
/// - **默认关闭**，必须由用户在「设置 → 手环 → 电脑控制（局域网）」内显式开启；
/// - 开启时生成一次性配对令牌，并只在私网地址上监听（见 `band_ws_server.dart`）；
/// - 关闭即停止监听并断开全部连接、令牌失效；
/// - 令牌**不写入任何日志**。
library;

import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'band_router.dart';
import 'band_service.dart';
import 'band_ws_server.dart';

/// 中继运行状态。
enum RelayStatus {
  /// 未开启（默认）。
  disabled,

  /// 正在启动。
  starting,

  /// 运行中（已在私网监听）。
  running,

  /// 不可用（无可用私网接口 / 绑定失败 / 平台不支持）。
  unavailable,
}

/// 局域网中继服务单例。
class BandRelayService {
  BandRelayService._internal();

  static final BandRelayService instance = BandRelayService._internal();

  /// 使能开关持久化 key。
  static const String _prefEnabledKey = 'band_relay_enabled';

  /// 可注入的路由（测试用；为空则复用 [BandService] 的 router）。
  BandRouter? routerOverride;

  BandWsServer? _server;
  bool _enabled = false;
  bool _initialized = false;
  RelayStatus _status = RelayStatus.disabled;
  List<String> _addresses = const <String>[];

  final StreamController<RelayStatus> _statusCtrl =
      StreamController<RelayStatus>.broadcast();

  /// 状态 / 连接数变化流。
  Stream<RelayStatus> get onStatusChanged => _statusCtrl.stream;

  /// 是否已开启。
  bool get enabled => _enabled;

  /// 当前状态。
  RelayStatus get status => _status;

  /// 是否正在监听。
  bool get running => _server?.running ?? false;

  /// 当前配对令牌（未开启为 null）。
  String? get token => _server?.token;

  /// 可连接地址（`ip:port`）。
  List<String> get addresses => _addresses;

  /// 当前在线连接数。
  int get connectionCount => _server?.core?.connectionCount ?? 0;

  /// 最近一次连接状态描述。
  String get lastConnectionSummary =>
      _server?.core?.lastConnectionSummary ?? '暂无';

  /// 初始化：读取开关并按需启动。可重复调用（幂等）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefEnabledKey) ?? false;
    } catch (_) {
      _enabled = false;
    }
    if (_enabled) {
      await start();
    } else {
      _setStatus(RelayStatus.disabled);
    }
  }

  /// 启用 / 停用中继。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabledKey, value);
    } catch (_) {}
    if (value) {
      await start();
    } else {
      await stop();
    }
  }

  /// 启动监听（已在运行则直接返回）。
  Future<void> start() async {
    if (_server?.running ?? false) return;
    _setStatus(RelayStatus.starting);
    final router = _resolveRouter();
    final server = BandWsServer(router: router, onConnectionChanged: _notify);
    final info = await server.start();
    if (info == null) {
      _server = null;
      _addresses = const <String>[];
      _setStatus(RelayStatus.unavailable);
      return;
    }
    _server = server;
    _addresses = info.addresses;
    _setStatus(RelayStatus.running);
  }

  /// 停止监听、断开全部连接、令牌失效。
  Future<void> stop() async {
    await _server?.stop();
    _server = null;
    _addresses = const <String>[];
    _setStatus(RelayStatus.disabled);
  }

  /// 轮换配对令牌：已连接的客户端将失效，需用新令牌重新连接。
  Future<void> rotateToken() async {
    if (!(_server?.running ?? false)) return;
    await stop();
    await start();
  }

  /// 释放资源（主要供测试）。
  Future<void> dispose() async {
    await stop();
    if (!_statusCtrl.isClosed) await _statusCtrl.close();
  }

  // ── 内部 ──────────────────────────────────────────────────

  /// 解析要复用的路由：默认复用 [BandService] 的同一个 router，确保命令 / 事件 /
  /// 幂等去重与手环路径共用一套逻辑；若尚未绑定播控端口则补绑一次。
  BandRouter _resolveRouter() {
    final override = routerOverride;
    if (override != null) return override;
    final router = BandService.instance.router;
    if (!router.hasPort) {
      router.attach(AudioPlayerServicePort());
    }
    return router;
  }

  void _notify() {
    // 连接数 / 最近连接状态变化 → 借状态流通知 UI 刷新。
    if (!_statusCtrl.isClosed) _statusCtrl.add(_status);
  }

  void _setStatus(RelayStatus s) {
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
  }
}

/// 便于排查：本机是否具备可用于中继的私网接口（真机定位用，不涉及令牌）。
Future<bool> relayHasLanAddress() async {
  try {
    final list = await BandWsServer.lanAddresses();
    return list.isNotEmpty;
  } on SocketException {
    return false;
  }
}

/// SuchMusic 手环通信 · 服务门面（对 UI 暴露连接状态与使能开关）。
///
/// 组合 [BandChannel]（原生通道）与 [BandRouter]（命令/事件路由）：
/// - UI 只需读 [state] / [sdkReady] / [wearAppInstallState] 并订阅 [onStateChanged]；
/// - 开关 [setEnabled] 决定是否把 `AudioPlayerService()` 接入手环链路。
///
/// 一切失败静默降级（复用 [BandChannel] 的容错），非 Android / 无 AAR 时表现为
/// `unavailable`，不抛异常。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'band_channel.dart';
import 'band_protocol.dart';
import 'band_router.dart';

/// 手环连接状态。
enum BandConnectionState { unavailable, disconnected, connecting, ready }

/// 手环服务单例。
class BandService {
  BandService._internal();

  static final BandService instance = BandService._internal();

  /// 使能开关持久化 key。
  static const String _prefEnabledKey = 'band_control_enabled';

  final BandChannel _channel = BandChannel();
  final BandRouter _router = BandRouter();

  final StreamController<BandConnectionState> _stateController =
      StreamController<BandConnectionState>.broadcast();

  StreamSubscription<BandChannelEvent>? _nativeSub;
  StreamSubscription<BandEnvelope>? _outgoingSub;

  bool _initialized = false;
  bool _enabled = false;
  bool _sdkReady = false;
  BandConnectionState _state = BandConnectionState.unavailable;
  String _wearApp = 'unknown';

  /// 状态变化流（连接状态）。
  Stream<BandConnectionState> get onStateChanged => _stateController.stream;

  /// 是否已启用「手环控制」。
  bool get enabled => _enabled;

  /// 当前连接状态。
  BandConnectionState get state => _state;

  /// SDK 是否就绪（本机是否放置并加载了官方 AAR）。
  bool get sdkReady => _sdkReady;

  /// 手环端快应用安装状态：`installed` / `not_installed` / `unknown`。
  String get wearAppInstallState => _wearApp;

  /// 协商后的会话协议版本（未握手为 null）。
  int? get sessionVersion => _router.sessionVersion;

  /// 生效能力（手环能力 ∩ 本端能力）。
  List<String> get effectiveCaps => _router.effectiveCaps;

  /// 路由实例（供高级用途 / 测试）。
  BandRouter get router => _router;

  /// 初始化：读取开关、探测 SDK、按需启动链路。可重复调用（幂等）。
  Future<void> init() async {
    if (_initialized) {
      await refresh();
      return;
    }
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefEnabledKey) ?? false;
    } catch (_) {
      _enabled = false;
    }
    _listenNative();
    await refresh();
    if (_enabled && _sdkReady) {
      await _start();
    }
  }

  /// 启用 / 停用「手环控制」。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefEnabledKey, value);
    } catch (_) {}
    if (value) {
      _listenNative();
      await _start();
    } else {
      await _stop();
    }
  }

  /// 重新探测 SDK / 连接状态 / 快应用安装状态。
  Future<void> refresh() async {
    _sdkReady = await _channel.available();
    _wearApp = await _channel.wearAppInstallState();
    final raw = await _channel.state();
    _setState(_sdkReady ? _parseState(raw) : BandConnectionState.unavailable);
  }

  /// 诊断信息（真机定位用）。
  Future<Map<String, dynamic>?> diagnose() => _channel.diagnose();

  /// 手机端搜索页「发送到手环」：把关键词推给手环搜索页（§3.10 方案 B）。
  void pushSearchPreset(String keyword) {
    if (!_enabled) return;
    _router.pushEvent('search.preset', <String, dynamic>{'keyword': keyword});
  }

  /// 释放资源（主要供测试）。
  Future<void> dispose() async {
    await _nativeSub?.cancel();
    await _outgoingSub?.cancel();
    _nativeSub = null;
    _outgoingSub = null;
    _router.dispose();
    await _stateController.close();
  }

  // ── 内部 ──────────────────────────────────────────────────

  void _listenNative() {
    _nativeSub ??= _channel.events().listen(_onNativeEvent, onError: (_) {});
    _outgoingSub ??= _router.onOutgoing.listen((env) {
      _channel.send(env.encode());
    });
  }

  Future<void> _start() async {
    // 命令落地 + 状态订阅：挂在 AudioPlayerService() 单例（与 AudioPlayerHandler 同源）
    _router.attach(AudioPlayerServicePort());
    if (!_sdkReady) {
      _sdkReady = await _channel.available();
    }
    if (!_sdkReady) {
      _setState(BandConnectionState.unavailable);
      return;
    }
    final ok = await _channel.start();
    _setState(ok
        ? BandConnectionState.connecting
        : BandConnectionState.unavailable);
  }

  Future<void> _stop() async {
    await _channel.stop();
    _router.detach();
    _setState(_sdkReady
        ? BandConnectionState.disconnected
        : BandConnectionState.unavailable);
  }

  void _onNativeEvent(BandChannelEvent event) {
    switch (event.type) {
      case BandEventType.message:
        final json = event.json;
        if (json != null) _handleIncoming(json);
        break;
      case BandEventType.state:
        _setState(_parseState(event.state));
        break;
      case BandEventType.unknown:
        break;
    }
  }

  Future<void> _handleIncoming(String json) async {
    BandEnvelope env;
    try {
      env = BandEnvelope.decode(json);
    } catch (e) {
      debugPrint('⚠️ 手环信封解析失败，已丢弃: $e');
      return;
    }
    if (env.type == 'req') {
      final res = await _router.handleRequest(env);
      await _channel.send(res.encode());
    }
    // res / err / evt 来自手环：本端无需回执（evt 不回执，res/err 仅日志）
  }

  void _setState(BandConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  BandConnectionState _parseState(String? s) => switch (s) {
        'ready' => BandConnectionState.ready,
        'connecting' => BandConnectionState.connecting,
        'disconnected' => BandConnectionState.disconnected,
        _ => BandConnectionState.unavailable,
      };
}

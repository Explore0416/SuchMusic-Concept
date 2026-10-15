/// SuchMusic 手环通信 · 原生通道封装（MethodChannel + EventChannel）。
///
/// 与 Kotlin 侧 `BandChannelBridge` 对接：
/// - `MethodChannel("com.lightningteam.suchmusic/band")`：可用性 / 连接 / 发送 / 诊断；
/// - `EventChannel("com.lightningteam.suchmusic/band_events")`：上行消息与状态变化。
///
/// 风格与既有 `SoundEffectService` 一致：**任何失败静默降级**，返回安全值而非抛异常；
/// 仅当通道本身不存在（`MissingPluginException`）时才熔断。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生事件类型。
enum BandEventType { message, state, unknown }

/// 原生事件快照。
class BandChannelEvent {
  const BandChannelEvent({required this.type, this.json, this.state});

  final BandEventType type;

  /// `type == message` 时的原始信封 JSON。
  final String? json;

  /// `type == state` 时的连接状态字符串。
  final String? state;
}

/// 原生通道封装。
class BandChannel {
  BandChannel();

  static const MethodChannel _method =
      MethodChannel('com.lightningteam.suchmusic/band');
  static const EventChannel _events =
      EventChannel('com.lightningteam.suchmusic/band_events');

  /// 通道本身不存在时熔断（如非 Android 平台 / 引擎未注册）。
  bool _broken = false;
  bool _warnLogged = false;

  bool get isBroken => _broken;

  /// 原生事件流：上行消息 + 连接状态。
  Stream<BandChannelEvent> events() {
    return _events.receiveBroadcastStream().map(_parseEvent).handleError((Object e) {
      _handleError(e);
    });
  }

  /// SDK 是否就绪（运行时可加载官方 AAR）。
  Future<bool> available() async {
    if (_broken) return false;
    try {
      final ok = await _method.invokeMethod<bool>('available');
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 当前连接状态字符串。
  Future<String> state() async {
    if (_broken) return 'unavailable';
    try {
      final s = await _method.invokeMethod<String>('state');
      return (s == null || s.isEmpty) ? 'unavailable' : s;
    } catch (e) {
      _handleError(e);
      return 'unavailable';
    }
  }

  /// 启动链路。
  Future<bool> start() async {
    if (_broken) return false;
    try {
      final ok = await _method.invokeMethod<bool>('start');
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 停止链路。
  Future<bool> stop() async {
    if (_broken) return false;
    try {
      final ok = await _method.invokeMethod<bool>('stop');
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 下发一段信封 JSON 到手环。
  Future<bool> send(String json) async {
    if (_broken) return false;
    try {
      final ok = await _method.invokeMethod<bool>('send', <String, dynamic>{
        'json': json,
      });
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 手环端快应用安装状态：`installed` / `not_installed` / `unknown`。
  Future<String> wearAppInstallState() async {
    if (_broken) return 'unknown';
    try {
      final s = await _method.invokeMethod<String>('wearAppInstalled');
      return (s == null || s.isEmpty) ? 'unknown' : s;
    } catch (e) {
      _handleError(e);
      return 'unknown';
    }
  }

  /// 诊断信息（真机定位用）。
  Future<Map<String, dynamic>?> diagnose() async {
    if (_broken) return null;
    try {
      final raw = await _method.invokeMethod<Map<dynamic, dynamic>>('diagnose');
      if (raw == null) return null;
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      _handleError(e);
      return null;
    }
  }

  BandChannelEvent _parseEvent(Object? raw) {
    if (raw is Map) {
      final type = raw['type']?.toString();
      switch (type) {
        case 'message':
          return BandChannelEvent(
              type: BandEventType.message, json: raw['json']?.toString());
        case 'state':
          return BandChannelEvent(
              type: BandEventType.state, state: raw['state']?.toString());
      }
    }
    return const BandChannelEvent(type: BandEventType.unknown);
  }

  /// 统一错误处理：区分「通道不存在」（真熔断）与「业务性失败」（不熔断）。
  void _handleError(Object e) {
    final isMissingChannel = e is MissingPluginException;
    if (!_warnLogged) {
      _warnLogged = true;
      debugPrint(isMissingChannel
          ? '⚠️ 手环通道不可用，已静默降级: $e'
          : '⚠️ 手环调用失败（不熔断，后续仍会重试）: $e');
    }
    if (isMissingChannel) {
      _broken = true;
    }
  }
}

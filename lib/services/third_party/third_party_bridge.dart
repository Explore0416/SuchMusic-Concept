import 'dart:async';

import 'package:flutter/services.dart';

/// `PackageManager` 查到的「本机已安装应用信息」（ARCHITECTURE §8.2）。
class InstalledAppInfo {
  const InstalledAppInfo({
    this.installed = false,
    this.label = '',
    this.signatureSha256 = '',
    this.versionName = '',
  });

  /// 未安装时的兜底值。
  static const InstalledAppInfo notInstalled = InstalledAppInfo();

  final bool installed;

  /// 系统展示的应用名（授权确认页优先用它，ARCH T10）。
  final String label;

  /// 首个签名证书的 SHA-256（小写 hex）；取不到时为空串。
  final String signatureSha256;

  final String versionName;

  factory InstalledAppInfo.fromMap(Object? raw) {
    if (raw is! Map) return InstalledAppInfo.notInstalled;
    return InstalledAppInfo(
      installed: raw['installed'] == true,
      label: (raw['label'] ?? '').toString(),
      signatureSha256: (raw['signatureSha256'] ?? '').toString().toLowerCase(),
      versionName: (raw['versionName'] ?? '').toString(),
    );
  }

  @override
  String toString() =>
      'InstalledAppInfo(installed=$installed, label=$label, versionName=$versionName)';
}

/// `sendClientCallback` 的返回值（ARCHITECTURE §6.4）。
class ClientCallbackResult {
  const ClientCallbackResult({required this.sent, this.reason});

  /// 目标包没有可接收回调的页面。
  static const ClientCallbackResult noCallbackActivity =
      ClientCallbackResult(sent: false, reason: 'no_callback_activity');

  final bool sent;
  final String? reason;

  factory ClientCallbackResult.fromMap(Object? raw) {
    if (raw is! Map) {
      return const ClientCallbackResult(
        sent: false,
        reason: 'bridge_error',
      );
    }
    return ClientCallbackResult(
      sent: raw['sent'] == true,
      reason: raw['reason']?.toString(),
    );
  }

  @override
  String toString() => 'ClientCallbackResult(sent=$sent, reason=$reason)';
}

/// 原生桥抽象（ARCHITECTURE §8.2）。
///
/// 抽成接口的唯一目的：单元测试注入假实现，**绝不在单测里触发 MethodChannel**。
abstract class ThirdPartyBridge {
  /// PackageManager 查包信息（是否安装 / 应用名 / 签名指纹 / 版本号）。
  Future<InstalledAppInfo> getInstalledAppInfo(String packageName);

  /// 用 explicit intent 把 code / port / state 投给目标包。
  Future<ClientCallbackResult> sendClientCallback(
    String packageName,
    Map<String, Object?> extras,
  );

  /// 冷启动时的初始深链（无则返回 null）。
  Future<String?> getLaunchUri();

  /// 读取目标应用的图标（PNG 字节）；取不到返回 null。
  ///
  /// 授权确认页用它画出「真实图标」；为 null 时退回「surfaceMuted 底 + 首字」。
  Future<Uint8List?> getAppIcon(String packageName);

  /// 发一条「第三方应用访问」系统通知（静默续期专用，ARCH §6.6）。
  ///
  /// 通道 `third_party_access` / 重要性 `IMPORTANCE_DEFAULT` / 点击拉起本 App。
  Future<void> showAccessNotice({required String title, required String content});

  /// `onNewIntent` 收到 `suchmusic://` 时推送的 Uri 字符串流。
  Stream<String> get deepLinks;
}

/// 基于 MethodChannel / EventChannel 的真实实现。
///
/// 通道名与 `ThirdPartyBridge.kt` 中的常量严格一致；
/// 原生侧未注册通道时全部方法降级为「查不到 / 未送达」，不抛异常。
class MethodChannelThirdPartyBridge implements ThirdPartyBridge {
  MethodChannelThirdPartyBridge({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ??
            const MethodChannel('com.lightningteam.suchmusic/third_party'),
        _events = eventChannel ??
            const EventChannel('com.lightningteam.suchmusic/third_party_events');

  /// MethodChannel 名（与 Kotlin 侧 `ThirdPartyBridge.CHANNEL` 一致）。
  static const String channelName = 'com.lightningteam.suchmusic/third_party';

  /// EventChannel 名（与 Kotlin 侧 `ThirdPartyBridge.EVENTS_CHANNEL` 一致）。
  static const String eventsChannelName =
      'com.lightningteam.suchmusic/third_party_events';

  final MethodChannel _method;
  final EventChannel _events;

  @override
  Future<InstalledAppInfo> getInstalledAppInfo(String packageName) async {
    try {
      final result = await _method.invokeMethod<Object?>(
        'getInstalledAppInfo',
        <String, Object?>{'package': packageName},
      );
      return InstalledAppInfo.fromMap(result);
    } on PlatformException {
      return InstalledAppInfo.notInstalled;
    } on MissingPluginException {
      return InstalledAppInfo.notInstalled;
    }
  }

  @override
  Future<ClientCallbackResult> sendClientCallback(
    String packageName,
    Map<String, Object?> extras,
  ) async {
    try {
      final result = await _method.invokeMethod<Object?>(
        'sendClientCallback',
        <String, Object?>{
          'package': packageName,
          'extras': extras,
        },
      );
      return ClientCallbackResult.fromMap(result);
    } on PlatformException catch (e) {
      return ClientCallbackResult(sent: false, reason: 'platform_error:${e.code}');
    } on MissingPluginException {
      return const ClientCallbackResult(
        sent: false,
        reason: 'channel_unavailable',
      );
    }
  }

  @override
  Future<String?> getLaunchUri() async {
    try {
      final result = await _method.invokeMethod<Object?>('getLaunchUri');
      if (result is Map) {
        final uri = (result['uri'] ?? '').toString();
        return uri.isEmpty ? null : uri;
      }
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<Uint8List?> getAppIcon(String packageName) async {
    try {
      final result = await _method.invokeMethod<Uint8List>(
        'getAppIcon',
        <String, Object?>{'package': packageName},
      );
      return (result == null || result.isEmpty) ? null : result;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> showAccessNotice({
    required String title,
    required String content,
  }) async {
    try {
      await _method.invokeMethod<Object?>(
        'showAccessNotice',
        <String, Object?>{'title': title, 'content': content},
      );
    } on PlatformException {
      // 通道异常（如未授予通知权限）不得影响授权主流程
    } on MissingPluginException {
      // 非 Android 平台没有原生实现，静默跳过
    }
  }

  @override
  Stream<String> get deepLinks => _events.receiveBroadcastStream().map(
        (dynamic event) => event?.toString() ?? '',
      ).where((String uri) => uri.isNotEmpty);
}

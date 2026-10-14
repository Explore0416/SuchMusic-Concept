import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'brand_island_service.dart';

/// 超级岛能力检测结果。
class IslandCapability {
  const IslandCapability({
    required this.isMiui,
    required this.supported,
    required this.canShowFocus,
    required this.reason,
  });

  final bool isMiui;
  final bool supported;
  final bool canShowFocus;
  final String reason;

  /// 未初始化 / 检测失败时的默认值（一律降级）
  static const IslandCapability unsupported = IslandCapability(
    isMiui: false,
    supported: false,
    canShowFocus: false,
    reason: 'not_supported',
  );
}

/// MethodChannel 封装 + 能力检测缓存。
///
/// 主方案是 audio_service 通知副标题（全 Android 生效）；
/// 本服务仅作小米超级岛**增强**，任何失败静默降级，绝不阻断播放。
class IslandService {
  IslandService._internal();

  static final IslandService instance = IslandService._internal();

  /// 与 Kotlin 侧 [IslandBridge.CHANNEL] 保持一致
  static const MethodChannel _channel =
      MethodChannel('com.lightningteam.suchmusic/island');

  static const String defaultIslandId = 'such_music_lyric';

  IslandCapability? _capability;
  bool _checked = false;
  bool _warnLogged = false;

  /// 熔断标志：focus 相关 channel 调用**首次失败**即置位，
  /// 之后所有 applyFocus / clearFocus 直接返回 false（不再发起高频无效调用）。
  bool _focusDisabled = false;

  /// 能力检测（结果缓存，仅真正探测一次）
  Future<IslandCapability> capability() async {
    final cached = _capability;
    if (_checked && cached != null) return cached;
    _checked = true;
    try {
      final raw = await _channel.invokeMethod<dynamic>('capability');
      if (raw is Map) {
        _capability = IslandCapability(
          isMiui: raw['isMiui'] == true,
          supported: raw['supported'] == true,
          canShowFocus: raw['canShowFocus'] == true,
          reason: (raw['reason'] ?? 'ok').toString(),
        );
      } else {
        _capability = IslandCapability.unsupported;
      }
    } catch (e) {
      // 非小米 / 通道不可用 → 静默降级，不打屏
      _capability = IslandCapability.unsupported;
      debugPrint('⚠️ 超级岛能力检测失败，已静默降级: $e');
    }
    return _capability!;
  }

  /// 是否支持超级岛增强（需 supported 且已授权 canShowFocus）
  bool get supported {
    final cap = _capability;
    return cap != null && cap.supported && cap.canShowFocus;
  }

  /// 注入 / 更新超级岛参数。失败返回 false（不抛出）。
  ///
  /// 首次失败即置内存熔断标志，后续调用直接返回 false、不再发起 channel 调用。
  Future<bool> applyFocus({
    required String title,
    required String content,
    String islandId = defaultIslandId,
  }) async {
    // 非小米设备：交给多品牌适配器（vivo 原子通知 / OPPO 流体云原生规范 /
    // 荣耀与未知小厂 → 标准 MediaStyle 通知兜底）。内部按品牌自行判定，失败静默。
    if (!supported) {
      unawaited(BrandIslandService.instance.applyFocus(title: title, content: content));
      return false;
    }
    if (_focusDisabled) return false; // 已熔断：不再发起 channel 调用
    try {
      final ok = await _channel.invokeMethod<bool>('applyFocus', {
        'title': title,
        'content': content,
        'islandId': islandId,
      });
      return ok == true;
    } catch (e) {
      _focusDisabled = true; // 熔断：后续直接跳过
      if (!_warnLogged) {
        _warnLogged = true; // 只记一条 warning，避免刷屏
        debugPrint('⚠️ 超级岛 focus 注入失败，已熔断后续调用: $e');
      }
      return false;
    }
  }

  /// 清除超级岛参数（停止播放 / 关闭开关时调用）。
  ///
  /// 与 [applyFocus] 共用熔断标志：一旦熔断，后续调用直接返回 false。
  Future<bool> clearFocus() async {
    if (!supported) {
      unawaited(BrandIslandService.instance.clearFocus());
      return false;
    }
    if (_focusDisabled) return false; // 已熔断：不再发起 channel 调用
    try {
      final ok = await _channel.invokeMethod<bool>('clearFocus');
      return ok == true;
    } catch (_) {
      _focusDisabled = true; // 熔断：后续直接跳过
      return false;
    }
  }
}

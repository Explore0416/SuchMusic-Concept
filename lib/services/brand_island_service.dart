import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 多品牌灵动胶囊 / 小窗的能力检测结果。
///
/// [strategy] 取值：`miui_focus_param` / `vivo_superx` /
/// `native_live_updates` / `fallback`。
class BrandIslandCapability {
  const BrandIslandCapability({
    required this.brand,
    required this.supported,
    required this.strategy,
    required this.reason,
  });

  /// xiaomi / vivo / honor / oppo / huawei / generic
  final String brand;

  /// 该品牌是否有可用的胶囊 / 小窗增强（false 时走原生兜底）
  final bool supported;

  /// 采用的注入策略
  final String strategy;

  /// 不支持时的原因（ok / no_public_api / os_version_too_low / …）
  final String reason;

  /// 未初始化 / 检测失败时的默认值（一律降级到原生兜底）
  static const BrandIslandCapability unsupported = BrandIslandCapability(
    brand: 'generic',
    supported: false,
    strategy: 'fallback',
    reason: 'not_supported',
  );
}

/// MethodChannel 封装 + 能力检测缓存。
///
/// 主方案仍是 audio_service 通知副标题（全 Android 生效，由
/// `NotificationLyricService` 负责）；本服务只做**品牌增强**，
/// 任何失败静默降级，绝不阻断播放。
///
/// 不支持的设备（荣耀 / 华为 / 通用）直接走原生兜底，不发起高频 channel 调用。
class BrandIslandService {
  BrandIslandService._internal();

  static final BrandIslandService instance = BrandIslandService._internal();

  /// 与 Kotlin 侧 `BrandIslandBridge.CHANNEL` 保持一致
  static const MethodChannel _channel =
      MethodChannel('com.lightningteam.suchmusic/brand_island');

  BrandIslandCapability? _capability;
  bool _checked = false;
  bool _warnLogged = false;

  /// 熔断标志：channel 调用首次失败即置位，之后直接返回 false
  bool _disabled = false;

  /// 能力检测（结果缓存，仅真正探测一次）
  Future<BrandIslandCapability> capability() async {
    final cached = _capability;
    if (_checked && cached != null) return cached;
    _checked = true;
    try {
      final raw = await _channel.invokeMethod<dynamic>('capability');
      if (raw is Map) {
        _capability = BrandIslandCapability(
          brand: (raw['brand'] ?? 'generic').toString(),
          supported: raw['supported'] == true,
          strategy: (raw['strategy'] ?? 'fallback').toString(),
          reason: (raw['reason'] ?? 'ok').toString(),
        );
      } else {
        _capability = BrandIslandCapability.unsupported;
      }
    } catch (e) {
      _capability = BrandIslandCapability.unsupported;
      debugPrint('⚠️ 多品牌胶囊能力检测失败，已静默降级: $e');
    }
    return _capability!;
  }

  /// 是否已检测到可用能力（未检测过返回 false，由调用方先 await capability()）
  bool get supported => _capability?.supported == true;

  /// 写入 / 更新胶囊内容（标题 + 歌词行）。失败返回 false（不抛出）。
  Future<bool> applyFocus({
    required String title,
    required String content,
  }) async {
    if (_disabled) return false; // 已熔断：不再发起 channel 调用
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('applyFocus', {
        'title': title,
        'content': content,
      });
      return ok == true;
    } catch (e) {
      _disabled = true; // 熔断：后续直接跳过
      if (!_warnLogged) {
        _warnLogged = true; // 只记一条 warning，避免刷屏
        debugPrint('⚠️ 多品牌胶囊注入失败，已熔断后续调用: $e');
      }
      return false;
    }
  }

  /// 清除胶囊展示（停止播放 / 关闭开关时调用）。失败返回 false（不抛出）。
  Future<bool> clearFocus() async {
    if (_disabled) return false;
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('clearFocus');
      return ok == true;
    } catch (_) {
      _disabled = true;
      return false;
    }
  }
}

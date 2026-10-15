import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 单个音效预设（code 与原生侧一一对应）。
class SoundEffectPreset {
  const SoundEffectPreset({
    required this.code,
    required this.name,
    required this.desc,
  });

  /// 预设标识，如 `default` / `origin_voice` / `jbl_flip`
  final String code;

  /// 展示名（中文）
  final String name;

  /// 一句话说明
  final String desc;

  /// 通道未就绪时的兜底列表，保证 UI 永远可渲染。
  static const List<SoundEffectPreset> fallback = [
    SoundEffectPreset(code: 'default', name: '默认', desc: '不做任何增益，保持原声'),
    SoundEffectPreset(code: 'origin_voice', name: '原声人声', desc: '突出人声与齿音，适合流行 / 人声'),
    SoundEffectPreset(code: 'jbl_flip', name: 'JBL Flip', desc: '推动低频动态，适合蓝牙小音箱'),
    SoundEffectPreset(code: 'jbl_partybox', name: 'JBL PartyBox', desc: '强低频氛围，适合派对音箱'),
    SoundEffectPreset(code: 'n12t_origin', name: 'N12T 原声', desc: '强低频 + 收敛中高频，厚重风格'),
    SoundEffectPreset(
        code: 'hxcore_surround', name: 'HxCore 环绕', desc: '左右声道差异化曲线，声场更宽'),
  ];

  /// 由通道返回的 map 构造；字段缺失时回退空串。
  factory SoundEffectPreset.fromMap(Object? raw) {
    if (raw is Map) {
      return SoundEffectPreset(
        code: (raw['code'] ?? '').toString(),
        name: (raw['name'] ?? '').toString(),
        desc: (raw['desc'] ?? '').toString(),
      );
    }
    return const SoundEffectPreset(code: '', name: '', desc: '');
  }

  /// 按名称查找（找不到时返回 [fallback] 首项「默认」）。
  static SoundEffectPreset byCode(
      List<SoundEffectPreset> presets, String? code) {
    if (code == null || code.isEmpty || code == off) {
      return presets.isEmpty ? fallback.first : presets.first;
    }
    for (final p in presets) {
      if (p.code == code) return p;
    }
    return presets.isEmpty ? fallback.first : presets.first;
  }

  /// 关闭音效的状态码（与原生 `PRESET_OFF` 一致）
  static const String off = 'off';
}

/// 音效服务：封装 `com.lightningteam.suchmusic/soundfx` 通道。
///
/// 与 [IslandService] 同风格：**任何失败都静默降级**，返回安全值而不是抛出异常，
/// 音效功能不可用时 UI 仍可正常展示。
class SoundEffectService {
  SoundEffectService._internal();

  static final SoundEffectService instance = SoundEffectService._internal();

  /// 与 Kotlin 侧 `SoundEffectBridge.CHANNEL` 保持一致
  static const MethodChannel _channel =
      MethodChannel('com.lightningteam.suchmusic/soundfx');

  /// 通道本身不存在时熔断（如非 Android 平台 / 引擎未注册）。
  /// **业务性失败不熔断**：否则启动时 (sessionId 为 null) 的必然失败会永久
  /// 掩盖后续本可成功的调用，导致整个进程内音效"死掉"。
  bool _broken = false;

  bool _warnLogged = false;

  /// 当前系统是否支持（Android 9 / API 28+ 的 DynamicsProcessing，真实探测）。
  Future<bool> available() async {
    if (_broken) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('available');
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 可用预设列表；通道不可用时返回 [SoundEffectPreset.fallback]。
  Future<List<SoundEffectPreset>> presets() async {
    if (_broken) return SoundEffectPreset.fallback;
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('presets');
      final list = raw ?? const <dynamic>[];
      if (list.isEmpty) return SoundEffectPreset.fallback;
      final parsed = list
          .map(SoundEffectPreset.fromMap)
          .where((p) => p.code.isNotEmpty)
          .toList(growable: false);
      return parsed.isEmpty ? SoundEffectPreset.fallback : parsed;
    } catch (e) {
      _handleError(e);
      return SoundEffectPreset.fallback;
    }
  }

  /// 应用预设；成功返回 true，失败 / 不支持返回 false。
  ///
  /// [sessionId] 为播放音频会话 ID（来自 `AudioPlayer.androidAudioSessionId`）。
  /// 原生侧会用它创建 DynamicsProcessing（**绑定 App 自己的播放会话**，
  /// 而非已被现代 ROM 拒绝的全局混音会话 0）。为空时原生回退到已记录会话 / 0。
  Future<bool> apply(String code, {int? sessionId}) async {
    if (_broken || code.isEmpty) return false;
    try {
      final args = <String, dynamic>{'code': code};
      if (sessionId != null && sessionId > 0) {
        args['sessionId'] = sessionId;
      }
      final ok = await _channel.invokeMethod<bool>('apply', args);
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 通知原生当前播放音频会话 ID。原生会用新会话重新应用「期望的预设」，
  /// 使已选音效在会话就绪 / 切歌重建会话后自动重新生效。
  /// [sessionId] 为空或 <= 0 时返回 false（尚无有效会话，稍后回调会再次触发）。
  Future<bool> setSessionId(int? sessionId) async {
    if (_broken || sessionId == null || sessionId <= 0) return false;
    try {
      final ok = await _channel
          .invokeMethod<bool>('setSessionId', {'id': sessionId});
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 诊断信息：用于真机定位音效问题（返回 null 表示通道不可用）。
  /// 含 `sdkInt` / `deviceModel` / `success` / `lastError` / `lastStrategy` /
  /// `currentCode` / `desiredCode` / `sessionId` / `enabled`。
  Future<Map<String, dynamic>?> diagnose() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('diagnose');
      if (raw == null) return null;
      return raw.map((key, value) => MapEntry(key.toString(), value));
    } catch (e) {
      _handleError(e);
      return null;
    }
  }

  /// 关闭音效（释放原生实例）。
  Future<bool> disable() async {
    if (_broken) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('disable');
      return ok == true;
    } catch (e) {
      _handleError(e);
      return false;
    }
  }

  /// 当前生效的 preset code；未启用时返回 `off`。
  Future<String> current() async {
    if (_broken) return SoundEffectPreset.off;
    try {
      final code = await _channel.invokeMethod<String>('current');
      return (code == null || code.isEmpty) ? SoundEffectPreset.off : code;
    } catch (e) {
      _handleError(e);
      return SoundEffectPreset.off;
    }
  }

  /// 启动恢复：仅同步原生侧「已保存的预设选择」，**不做实际 apply**。
  ///
  /// 启动阶段 just_audio 尚未创建音频会话，此时 apply 必然失败（并会打印误导性
  /// 提示）；真正的 apply 由 [AudioPlayerService] 监听到会话就绪后调用
  /// [setSessionId] 触发。原生侧的 `desiredCode` 已记住上次选择，无需在此重放。
  /// 返回已保存的 code（无选择时为 `off`）。
  Future<String> restore() async {
    return current();
  }

  /// 统一的错误处理：区分「通道本身不存在」（真熔断）与「业务性失败」（不熔断）。
  void _handleError(Object e) {
    // 只有 MethodChannel 无对应 handler（MissingPluginException）才视为通道不存在。
    // 本项目原生侧所有方法均 try/catch 返回安全值，不会抛 PlatformException；
    // 业务性失败（如会话未就绪导致 apply 返回 false）不抛异常，即便抛了也不熔断。
    final isMissingChannel = e is MissingPluginException;
    if (!_warnLogged) {
      _warnLogged = true; // 只记一条，避免刷屏
      debugPrint(isMissingChannel
          ? '⚠️ 音效通道不可用，已静默降级: $e'
          : '⚠️ 音效调用失败（不熔断，后续仍会重试）: $e');
    }
    if (isMissingChannel) {
      _broken = true;
    }
  }
}

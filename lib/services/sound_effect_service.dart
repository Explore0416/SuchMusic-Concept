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

  /// 通道首次失败后熔断：后续直接返回安全值，避免刷屏调用。
  bool _broken = false;

  bool _warnLogged = false;

  /// 当前系统是否支持（Android 9 / API 28+ 的 DynamicsProcessing）。
  Future<bool> available() async {
    if (_broken) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('available');
      return ok == true;
    } catch (e) {
      _markBroken(e);
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
      _markBroken(e);
      return SoundEffectPreset.fallback;
    }
  }

  /// 应用预设；成功返回 true，失败 / 不支持返回 false。
  Future<bool> apply(String code) async {
    if (_broken || code.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('apply', {'code': code});
      return ok == true;
    } catch (e) {
      _markBroken(e);
      return false;
    }
  }

  /// 关闭音效（释放原生实例）。
  Future<bool> disable() async {
    if (_broken) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('disable');
      return ok == true;
    } catch (e) {
      _markBroken(e);
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
      _markBroken(e);
      return SoundEffectPreset.off;
    }
  }

  /// 启动恢复：原生侧已用 SharedPreferences 记住上次选择，
  /// 这里重新触发一次 apply，让 DynamicsProcessing 实例在本次进程内生效。
  /// 未选择音效（off）或不可用时静默返回 false。
  Future<bool> restore() async {
    final code = await current();
    if (code == SoundEffectPreset.off) return false;
    return apply(code);
  }

  void _markBroken(Object e) {
    _broken = true;
    if (!_warnLogged) {
      _warnLogged = true; // 只记一条，避免刷屏
      debugPrint('⚠️ 音效通道不可用，已静默降级: $e');
    }
  }
}

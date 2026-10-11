import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/song_model.dart';
import '../../utils/app_constants.dart';
import '../kugou_credential_service.dart';
import 'kugou_source.dart';
import 'music_source.dart';
import 'netease_source.dart';

/// 音源路由 / 回退 / 切换 / 持久化（ARCH §4.5）。
class SourceManager {
  SourceManager._internal();

  static final SourceManager _instance = SourceManager._internal();

  factory SourceManager() => _instance;

  final NeteaseSource _netease = NeteaseSource();
  final KugouSource _kugou = KugouSource();

  SongSource _current = SongSource.netease;
  bool _fallbackEnabled = AppConstants.defaultKugouFallbackEnabled;
  bool _initialized = false;

  final StreamController<SongSource> _controller =
      StreamController<SongSource>.broadcast();

  final StreamController<String> _fallbackController =
      StreamController<String>.broadcast();

  /// 音源切换广播
  Stream<SongSource> get onSourceChanged => _controller.stream;

  /// 回退提示广播（UI 轻提示「已回退网易云」用）
  Stream<String> get onFallbackHint => _fallbackController.stream;

  /// 当前音源标识
  SongSource get currentSource => _current;

  /// 当前音源实现
  MusicSource get source => sourceFor(_current);

  /// 失败自动回退开关
  bool get fallbackEnabled => _fallbackEnabled;

  MusicSource sourceFor(SongSource kind) =>
      kind == SongSource.kugou ? _kugou : _netease;

  /// 读取 prefs 恢复当前音源 + 校验凭证
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _current = SongSource.fromCode(prefs.getString(AppConstants.musicSource));
      _fallbackEnabled = prefs.getBool(AppConstants.kugouFallbackEnabled) ??
          AppConstants.defaultKugouFallbackEnabled;
      await KugouCredentialService.instance.init();
      // 未配置凭证时不允许默认停在酷狗
      if (_current == SongSource.kugou && !_kugou.isConfigured) {
        debugPrint('⚠️ 酷狗凭证缺失，自动回退网易云');
        _current = SongSource.netease;
      }
      debugPrint('🎵 当前音源: ${_current.label}');
    } catch (e) {
      debugPrint('⚠️ 音源初始化失败，使用默认网易云: $e');
      _current = SongSource.netease;
    }
    // 初始化结束后广播一次，让未及时订阅的 UI 也能同步
    _controller.add(_current);
  }

  /// 切换音源：持久化 + 广播，**不清空播放队列**（Q7/U-9）
  Future<void> switchTo(SongSource kind) async {
    if (kind == _current) return;
    _current = kind;
    _controller.add(kind);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.musicSource, kind.code);
    } catch (e) {
      debugPrint('⚠️ 保存音源选择失败: $e');
    }
    debugPrint('🎵 切换音源 → ${kind.label}（播放队列保留）');
  }

  Future<void> setFallbackEnabled(bool enabled) async {
    _fallbackEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.kugouFallbackEnabled, enabled);
    } catch (e) {
      debugPrint('⚠️ 保存回退开关失败: $e');
    }
  }

  /// 统一回退：按 `song.source` 路由主音源；主音源失败且开启回退时切网易云重试。
  ///
  /// - [run] 接收「(音源, 歌曲, strict)」：主音源阶段 strict=false；
  ///   回退分支 strict=true（用于 [MusicSource.getSongUrl] 的严格失败判定）。
  /// - 回退前先用 [MusicSource.resolveCounterpart] 按「歌名 + 歌手」解析出网易云
  ///   对端歌曲，**不使用**源歌曲的 id 请求对端（否则必然取不到）。解析不到 → 回退失败。
  /// - 返回空值（null / 空串 / 空集合）视为失败。网易云自身不跨音源回退。
  ///
  /// [resolve] 仅供测试注入假解析器（避免真实网络）；为空时默认用网易云搜索匹配。
  Future<T?> withFallback<T>(
    SongModel song,
    Future<T?> Function(MusicSource source, SongModel song, bool strict) run, {
    Future<SongModel?> Function(SongModel song)? resolve,
  }) async {
    final primary = sourceFor(song.source);
    // 主音源阶段：非严格（网易云仍可用兜底外链，不破坏原有可播放能力）
    final result = await run(primary, song, false);
    if (_hasValue(result)) return result;
    if (primary.kind == SongSource.netease || !_fallbackEnabled) {
      return result;
    }

    // 回退网易云：先解析对端歌曲（歌名 + 歌手 搜索匹配）
    final resolver = resolve ?? _netease.resolveCounterpart;
    final counterpart = await resolver(song);
    if (counterpart == null) {
      debugPrint('⚠️ 主音源(${primary.displayName})失败，且未能匹配到网易云对端歌曲，回退失败');
      return result;
    }
    debugPrint(
        '🔄 主音源(${primary.displayName})失败，回退网易云（匹配到《${counterpart.name}》）');

    // 回退分支：严格模式判定真实成功与否（拿不到有效地址即回退失败）
    final fallbackResult = await run(_netease, counterpart, true);
    if (!_hasValue(fallbackResult)) {
      debugPrint('⚠️ 回退网易云仍失败（strict 模式未取得有效结果）');
      return result;
    }
    _fallbackController.add('已回退网易云');
    return fallbackResult;
  }

  bool _hasValue(Object? value) {
    if (value == null) return false;
    if (value is String) return value.isNotEmpty;
    if (value is Iterable) return value.isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    return true;
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_constants.dart';

/// 歌词 → 通知副标题 的去抖 / 节流服务。
///
/// 数据链路（ARCH §3.2）：歌词行变化 → 本服务（去抖 + 节流 ≤2 次/秒 +
/// 空行过滤）→ [onSubtitleChanged] 文本流 → `AudioPlayerHandler` 更新
/// `MediaItem.artist`（副标题）。
class NotificationLyricService {
  NotificationLyricService._internal();

  static final NotificationLyricService instance =
      NotificationLyricService._internal();

  /// 节流：同秒内最多 2 次
  static const int _maxPerSecond = 2;

  /// 两次更新最小间隔（≈2 次/秒）
  static const Duration _minInterval = Duration(milliseconds: 500);

  bool _enabled = AppConstants.defaultNotifyLyricEnabled;
  bool get enabled => _enabled;

  String _lastLine = '';
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _windowStart = DateTime.fromMillisecondsSinceEpoch(0);
  int _windowCount = 0;

  final StreamController<String> _subtitleController =
      StreamController<String>.broadcast();

  /// 副标题文本流（已过滤空行 / 已节流）；空串表示回退到歌手-专辑
  Stream<String> get onSubtitleChanged => _subtitleController.stream;

  /// 读取持久化开关
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(AppConstants.notifyLyricEnabled) ??
          AppConstants.defaultNotifyLyricEnabled;
    } catch (e) {
      debugPrint('⚠️ 读取通知歌词开关失败，使用默认值: $e');
    }
  }

  /// 切换开关：只改内存标志 + 写 prefs，不重连音频服务 / 不重启播放
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(AppConstants.notifyLyricEnabled, enabled);
    }).catchError((Object e) {
      debugPrint('⚠️ 写入通知歌词开关失败: $e');
    });
    if (!enabled) {
      reset();
    } else if (_lastLine.isNotEmpty) {
      // 重新开启：把上一有效行再推一次
      _subtitleController.add(_lastLine);
    }
  }

  /// 输入原始歌词行（含空行过滤 / 文本变化去重 / 节流）
  void feed(String line) {
    final text = line.trim();
    if (text.isEmpty) return; // 空行：沿用上一有效行，不更新
    if (text == _lastLine) return; // 仅文本变化时触发
    _lastLine = text;
    if (!_enabled) return;

    final now = DateTime.now();
    // 频率窗口
    if (now.difference(_windowStart).inMilliseconds >= 1000) {
      _windowStart = now;
      _windowCount = 0;
    }
    if (_windowCount >= _maxPerSecond) return;
    if (now.difference(_lastEmit) < _minInterval) return;

    _windowCount++;
    _lastEmit = now;
    _subtitleController.add(text);
  }

  /// 重置（切歌 / 停止播放 / 关闭开关时调用）
  void reset() {
    _lastLine = '';
    _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
    _windowStart = DateTime.fromMillisecondsSinceEpoch(0);
    _windowCount = 0;
    _subtitleController.add('');
  }
}

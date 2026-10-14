import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地「手动指定歌词」映射服务（单例）：`songId -> 歌词原文（LRC 或纯文本）`。
///
/// ── 用途 ─────────────────────────────────────────────────────
/// 自动匹配歌词时会遇到「识别不到 / 匹配错」的情况（尤其本地音乐、翻唱、
/// 冷门音源曲目）。此时由**用户自己搜索并选择**一条歌词，本服务把用户的
/// 选择按 songId 记下来；下次播放同一首歌时优先用这条，不再重新匹配。
///
/// ── 数据边界 ─────────────────────────────────────────────────
/// 仅保存在本机 SharedPreferences，不上传云端；随设置备份导出 / 导入迁移。
///
/// ── 设计约定 ─────────────────────────────────────────────────
/// 所有 IO 用 try/catch 兜底，读写失败时不向 UI 抛异常（最坏只是丢一次映射）。
class LocalLyricService {
  static final LocalLyricService _instance = LocalLyricService._internal();
  factory LocalLyricService() => _instance;
  LocalLyricService._internal();

  /// SharedPreferences 中存放映射 JSON 字符串的 key。
  static const String storageKey = 'local_lyrics_v1';

  /// 快照结构版本（restore 时校验，版本不符直接丢弃）。
  static const int snapshotVersion = 1;

  SharedPreferences? _prefs;
  final Map<String, String> _map = {};

  /// 已手动指定的歌词条数（UI 展示 / 备份计数用）。
  int get count => _map.length;

  /// 只读视图：`songId -> 歌词文本`。
  Map<String, String> get all => Map.unmodifiable(_map);

  /// 从 SharedPreferences 载入映射。重复调用安全（重新读盘覆盖内存）。
  Future<void> init() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return;
      if (json['version'] is int && json['version'] != snapshotVersion) return;
      _map.clear();
      final lyrics = json['lyrics'];
      if (lyrics is! Map) return;
      for (final entry in lyrics.entries) {
        final id = entry.key.toString();
        final text = entry.value?.toString();
        if (id.isEmpty || text == null || text.isEmpty) continue;
        _map[id] = text;
      }
    } catch (_) {
      // 读盘 / 解析失败：静默降级为「无手动歌词」
    }
  }

  /// 取某首歌手动指定的歌词；未指定返回 null（调用方再走自动匹配）。
  String? get(String songId) => _map[songId];

  /// 是否已有手动指定的歌词。
  bool has(String songId) => _map.containsKey(songId);

  /// 设置（或覆盖）某首歌的歌词。[text] 为空串时等价于 [remove]。
  Future<void> set(String songId, String text) async {
    if (songId.isEmpty) return;
    if (text.trim().isEmpty) {
      await remove(songId);
      return;
    }
    _map[songId] = text;
    await _save();
  }

  /// 删除某首歌的手动歌词（恢复为自动匹配）。
  Future<void> remove(String songId) async {
    if (_map.remove(songId) == null) return;
    await _save();
  }

  /// 清空全部手动歌词。
  Future<void> clear() async {
    if (_map.isEmpty) return;
    _map.clear();
    await _save();
  }

  // ── 快照（供备份导出 / 导入，见 SettingsBackupService）────────

  /// 导出可序列化的快照：`{'version':1,'lyrics':{id:text}}`。
  Map<String, dynamic> snapshot() => {
        'version': snapshotVersion,
        'lyrics': Map<String, String>.from(_map),
      };

  /// 从快照恢复；返回成功恢复的条目数（0 表示快照无效或为空）。
  Future<int> restore(Object? json) async {
    if (json is! Map<String, dynamic>) return 0;
    if (json['version'] is int && json['version'] != snapshotVersion) return 0;
    final lyrics = json['lyrics'];
    if (lyrics is! Map) return 0;
    _map.clear();
    for (final entry in lyrics.entries) {
      final id = entry.key.toString();
      final text = entry.value?.toString();
      if (id.isEmpty || text == null || text.isEmpty) continue;
      _map[id] = text;
    }
    if (_map.isEmpty) return 0;
    await _save();
    return _map.length;
  }

  Future<void> _save() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(snapshot()));
    } catch (_) {
      // 写盘失败：内存映射仍有效，下次启动前不落盘即可
    }
  }
}

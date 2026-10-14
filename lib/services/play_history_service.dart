import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song_model.dart';

/// **本地**播放历史与偏好统计服务（单例）。
///
/// ── 数据边界（重要）───────────────────────────────────────────
/// 本服务记录和使用的全部数据 **只保存在本机**（SharedPreferences），
/// **不会上传到任何云端服务器、不会随登录态同步、不会参与任何网络请求**。
/// 推荐结果完全由本机播放行为离线推导，卸载 App 即随本机存储一并清除。
///
/// ── 职责 ─────────────────────────────────────────────────────
/// 1. [record]：记一次播放（次数 +1、刷新最近播放时间、累加当前小时段）。
/// 2. [suggest]：按 [recommendationScore] 打分排序，返回本地个性化推荐。
/// 3. [snapshot] / [restore]：导出 / 恢复快照，供 [SettingsBackupService] 备份用。
///
/// ── 设计约定 ─────────────────────────────────────────────────
/// - **纯函数与副作用分离**：打分逻辑是导出的顶层纯函数 [recommendationScore]，
///   不读时钟、不读 IO，便于单测；本类只负责取数（时钟 / 存储）与写盘。
/// - **所有 IO 用 try/catch 兜底**，任何读写失败都不向 UI 抛异常。
class PlayHistoryService {
  static final PlayHistoryService _instance = PlayHistoryService._internal();
  factory PlayHistoryService() => _instance;
  PlayHistoryService._internal();

  // ── 持久化 ────────────────────────────────────────────────

  /// SharedPreferences 中存放播放历史 JSON 字符串的 key。
  static const String storageKey = 'play_history_v1';

  /// 快照结构版本（restore 时校验，版本不符直接丢弃）。
  static const int snapshotVersion = 1;

  /// 最多保留的歌曲条数，超出按「最久未播放」淘汰。
  static const int maxEntries = 300;

  /// 一天的小时段数量（hourCounts 长度固定为 24）。
  static const int hoursPerDay = 24;

  SharedPreferences? _prefs;
  final Map<String, _PlayStat> _stats = {};

  /// 已记录的歌曲数（调试 / UI 展示用）。
  int get count => _stats.length;

  /// 全部条目的累计播放次数（即打分公式里的 totalPlays）。
  int get totalPlays =>
      _stats.values.fold<int>(0, (sum, e) => sum + e.count);

  /// 从 SharedPreferences 载入历史。重复调用安全（会重新读盘覆盖内存）。
  Future<void> init() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getString(storageKey);
      if (raw == null || raw.isEmpty) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return;
      _stats.clear();
      for (final entry in _decodeEntries(json['entries'])) {
        _stats[entry.song.id] = entry;
      }
    } catch (_) {
      // 读盘 / 解析失败：静默降级为「无历史」，不影响播放主流程
    }
  }

  /// 记录一次播放：次数 +1、刷新 [lastPlayedAt]、当前小时（0-23）计数 +1。
  ///
  /// 同一首歌只保留一条记录（以 [SongModel.id] 为键）。写盘失败不影响内存统计。
  Future<void> record(SongModel song) async {
    final now = DateTime.now();
    final existing = _stats[song.id];
    if (existing == null) {
      final hours = List<int>.filled(hoursPerDay, 0);
      hours[now.hour] = 1;
      _stats[song.id] = _PlayStat(song: song, count: 1, lastPlayedAt: now, hourCounts: hours);
    } else {
      // 用最新的歌曲信息覆盖（封面 / 音源可能变化），只累加统计不重置
      final hours = List<int>.from(existing.hourCounts);
      if (hours.length < hoursPerDay) {
        hours.addAll(List<int>.filled(hoursPerDay - hours.length, 0));
      }
      hours[now.hour] = hours[now.hour] + 1;
      _stats[song.id] = _PlayStat(
        song: song,
        count: existing.count + 1,
        lastPlayedAt: now,
        hourCounts: hours,
      );
    }
    _evictIfNeeded();
    await _save();
  }

  /// 本地个性化推荐：按 [recommendationScore] 从高到低返回最多 [limit] 首歌。
  ///
  /// 纯内存计算、同步返回；无历史时返回空列表（UI 自行兜底展示热门榜单）。
  List<SongModel> suggest({int limit = 10}) {
    if (_stats.isEmpty || limit <= 0) return const <SongModel>[];
    final now = DateTime.now();
    final total = totalPlays;

    final scored = _stats.values.map((e) {
      final days = now.difference(e.lastPlayedAt).inDays;
      return _Scored(
        song: e.song,
        lastPlayedAt: e.lastPlayedAt,
        score: recommendationScore(
          count: e.count,
          daysSinceLastPlay: days < 0 ? 0 : days,
          hourCountAtNow: e.hourOf(now.hour),
          totalPlays: total,
        ),
      );
    }).toList();

    // 分数相同时，最近播放过的排前面（保证排序稳定、结果可预期）
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : b.lastPlayedAt.compareTo(a.lastPlayedAt);
    });
    return scored.take(limit).map((e) => e.song).toList();
  }

  /// 清空本机播放历史（设置页「清除本地推荐数据」用）。
  Future<void> clear() async {
    _stats.clear();
    await _save();
  }

  // ── 快照（供备份导出 / 导入，见 SettingsBackupService）────────

  /// 导出可序列化的快照：`{'version':1,'entries':[...]}`。
  Map<String, dynamic> snapshot() => {
        'version': snapshotVersion,
        'entries': _stats.values.map((e) => e.toJson()).toList(growable: false),
      };

  /// 从快照恢复；返回成功恢复的条目数（0 表示快照无效或为空）。
  Future<int> restore(Object? json) async {
    if (json is! Map<String, dynamic>) return 0;
    if (json['version'] is int && json['version'] != snapshotVersion) return 0;
    final entries = _decodeEntries(json['entries']);
    if (entries.isEmpty) return 0;
    _stats.clear();
    for (final entry in entries) {
      _stats[entry.song.id] = entry;
    }
    _evictIfNeeded();
    await _save();
    return _stats.length;
  }

  // ── 内部实现 ────────────────────────────────────────────────

  /// 超出 [maxEntries] 时按「最久未播放」淘汰。
  void _evictIfNeeded() {
    if (_stats.length <= maxEntries) return;
    final sorted = _stats.values.toList()
      ..sort((a, b) => a.lastPlayedAt.compareTo(b.lastPlayedAt));
    final removeCount = _stats.length - maxEntries;
    for (final e in sorted.take(removeCount)) {
      _stats.remove(e.song.id);
    }
  }

  Future<void> _save() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setString(storageKey, jsonEncode(snapshot()));
    } catch (_) {
      // 写盘失败：内存统计仍有效，下次启动前不落盘即可
    }
  }

  /// 解析条目数组，容忍单条脏数据（跳过而非整体失败）。
  static List<_PlayStat> _decodeEntries(Object? raw) {
    if (raw is! List) return const <_PlayStat>[];
    final result = <_PlayStat>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final stat = _PlayStat.fromJson(item);
      if (stat != null) result.add(stat);
    }
    return result;
  }
}

/// **确定性纯函数**：本地推荐打分（顶层导出，便于单测，不依赖时钟与 IO）。
///
/// 显式规则（三项加权，权重合计 1.0）：
/// - `recency`（新鲜度，权重 0.5）= `1 / (1 + daysSinceLastPlay)`
///   → 刚听过的最近，越久没听衰减越快；当天听过的为 1.0。
/// - `freq`（频次，权重 0.3）= `log(1 + count) / log(1 + totalPlays)`
///   → 听的次数占全部播放量的对数比例（抑制单曲刷量导致的线性膨胀）。
///   **totalPlays ≤ 0 时该项为 0**（分母 log(1)=0，避免除零/NaN）。
/// - `hourAffinity`（时段偏好，权重 0.2）= `hourCountAtNow / max(count, 1)`
///   → 这首歌在「当前这个小时」被听过的占比，体现「早上/深夜常听什么」。
/// - `score = recency * 0.5 + freq * 0.3 + hourAffinity * 0.2`，取值约 [0, 1]。
///
/// 入参为负时按 0 处理；[hourCountAtNow] 超过 [count] 时按 [count] 截断，
/// 保证 hourAffinity ∈ [0, 1]。
double recommendationScore({
  required int count,
  required int daysSinceLastPlay,
  required int hourCountAtNow,
  required int totalPlays,
}) {
  final c = count < 0 ? 0 : count;
  final days = daysSinceLastPlay < 0 ? 0 : daysSinceLastPlay;
  final total = totalPlays < 0 ? 0 : totalPlays;
  final hourHits = hourCountAtNow < 0 ? 0 : math.min(hourCountAtNow, c == 0 ? 0 : c);

  final recency = 1 / (1 + days);
  final freq = total <= 0 ? 0.0 : math.log(1 + c) / math.log(1 + total);
  final hourAffinity = hourHits / (c > 0 ? c : 1);

  return recency * 0.5 + freq * 0.3 + hourAffinity * 0.2;
}

/// 单曲统计条目（内部数据结构）。
class _PlayStat {
  const _PlayStat({
    required this.song,
    required this.count,
    required this.lastPlayedAt,
    required this.hourCounts,
  });

  final SongModel song;
  final int count;

  /// 最近一次播放时间（本机时间）。
  final DateTime lastPlayedAt;

  /// 24 个整点段的播放次数，下标 = 小时（0-23）。
  final List<int> hourCounts;

  int hourOf(int hour) {
    if (hour < 0 || hour >= hourCounts.length) return 0;
    return hourCounts[hour];
  }

  Map<String, dynamic> toJson() => {
        'song': _encodeSong(song),
        'count': count,
        'lastPlayedAt': lastPlayedAt.millisecondsSinceEpoch,
        'hourCounts': hourCounts,
      };

  static _PlayStat? fromJson(Map<String, dynamic> json) {
    final song = _decodeSong(json['song']);
    if (song == null) return null;
    final rawHours = json['hourCounts'];
    final hours = <int>[];
    if (rawHours is List) {
      for (final v in rawHours) {
        hours.add(v is int ? v : int.tryParse(v.toString()) ?? 0);
      }
    }
    while (hours.length < PlayHistoryService.hoursPerDay) {
      hours.add(0);
    }
    final count = json['count'] is int
        ? json['count'] as int
        : int.tryParse(json['count'].toString()) ?? 0;
    final millis = json['lastPlayedAt'] is int
        ? json['lastPlayedAt'] as int
        : int.tryParse(json['lastPlayedAt'].toString());
    return _PlayStat(
      song: song,
      count: count < 0 ? 0 : count,
      lastPlayedAt: millis == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(millis),
      hourCounts: hours,
    );
  }
}

/// 排序中间结果（内部使用）。
class _Scored {
  const _Scored({
    required this.song,
    required this.lastPlayedAt,
    required this.score,
  });

  final SongModel song;
  final DateTime lastPlayedAt;
  final double score;
}

// ── SongModel 编解码（本文件私有）──────────────────────────────
//
// 不直接用 `SongModel.toJson()` 是因为它**不含 localUri**：本地音乐（
// `SongSource.local`）没有 localUri 就放不了，推荐结果会失效。这里在
// toJson 基础上补一个 localUri 字段，做到「本地/在线」都能原样还原。

Map<String, dynamic> _encodeSong(SongModel song) => <String, dynamic>{
      ...song.toJson(),
      'localUri': song.localUri,
    };

SongModel? _decodeSong(Object? raw) {
  if (raw is! Map<String, dynamic>) return null;
  final id = raw['id']?.toString();
  if (id == null || id.isEmpty) return null;
  return SongModel(
    id: id,
    name: raw['name']?.toString() ?? '',
    artist: raw['artist']?.toString() ?? '',
    album: raw['album']?.toString() ?? '',
    coverUrl: raw['coverUrl']?.toString(),
    duration: raw['duration'] is int
        ? raw['duration'] as int
        : int.tryParse(raw['duration'].toString()),
    source: SongSource.fromCode(raw['source']?.toString()),
    hash: raw['hash']?.toString(),
    albumId: raw['albumId']?.toString(),
    albumAudioId: raw['albumAudioId']?.toString(),
    localUri: raw['localUri']?.toString(),
  );
}

import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import '../models/recommendation_profile.dart';
import '../models/song_model.dart';
import 'genre_metadata_service.dart';
import 'play_context_service.dart';
import 'recommendation_engine.dart';

/// **本地**播放历史与偏好统计服务（单例）。
///
/// ── 数据边界（重要）───────────────────────────────────────────
/// 本服务记录和使用的全部数据 **只保存在本机**（SharedPreferences），
/// **不会上传到任何云端服务器、不会随登录态同步、不会参与任何网络请求**。
/// 推荐结果完全由本机播放行为离线推导，卸载 App 即随本机存储一并清除。
///
/// ── 职责 ─────────────────────────────────────────────────────
/// 1. [record]：记一次播放（次数 +1、刷新最近播放时间、累加当前小时段、
///    消费播放来源上下文并派生曲风标签）。
/// 2. [recordCompletion]：切歌时结算上一首的**完成度 / 跳过**。
/// 3. [suggest]：多维度本地个性化推荐（委托 [RecommendationEngine]）。
/// 4. [snapshot] / [restore]：导出 / 恢复快照（v2，兼容导入 v1）。
///
/// ── 持久化与迁移（设计文档 §7）────────────────────────────────
/// - SharedPreferences key **沿用 `play_history_v1`**（键名不变）。
/// - 快照结构版本 `1 → 2`；读盘时按 `json['version']` 分流：1 → 迁移，2 → 直用。
/// - 迁移 **逐字段保留** v1 历史（count/lastPlayedAt/hourCounts/song），仅补默认字段。
/// - `tagIndex`/`artistIndex` 并入同一份 JSON（随备份导出）。
class PlayHistoryService {
  static final PlayHistoryService _instance = PlayHistoryService._internal();
  factory PlayHistoryService() => _instance;
  PlayHistoryService._internal();

  // ── 持久化 ────────────────────────────────────────────────

  /// SharedPreferences 中存放播放历史 JSON 字符串的 key（**键名不变**）。
  static const String storageKey = 'play_history_v1';

  /// 快照结构版本（v1 → v2）。
  static const int snapshotVersion = LocalRecommendationProfile.snapshotVersion;

  /// 最多保留的歌曲条数，超出按「最久未播放」淘汰。
  static const int maxEntries = 300;

  /// 推荐参数（可注入覆盖；默认取 [RecommendationConfig.defaults]）。
  RecommendationConfig config = RecommendationConfig.defaults;

  SharedPreferences? _prefs;
  final Map<String, PlayStatV2> _stats = <String, PlayStatV2>{};

  /// 引擎结果缓存（避免每次进首页重算）。
  List<SongModel>? _cache;
  String? _cacheSignature;

  /// 内存版本号（record / clear / restore 时 +1，参与缓存签名）。
  int _version = 0;

  /// 已记录的歌曲数（调试 / UI 展示用）。
  int get count => _stats.length;

  /// 全部条目的累计播放次数（即打分公式里的 totalPlays）。
  int get totalPlays =>
      _stats.values.fold<int>(0, (sum, e) => sum + e.count);

  /// 只读历史视图（供测试与推断使用）。
  List<PlayStatV2> get entries => List<PlayStatV2>.unmodifiable(_stats.values);

  /// 从 SharedPreferences 载入历史。重复调用安全（会重新读盘覆盖内存）。
  Future<void> init() async {
    try {
      _prefs ??= await SharedPreferences.getInstance();
      final raw = _prefs!.getString(storageKey);
      if (raw == null || raw.isEmpty) {
        _rebuildGenre();
        return;
      }
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return;
      _stats.clear();

      final version = json['version'];
      if (version == 1) {
        // v1 → v2 迁移（内存中完成；下次 record/save 时落盘为 v2）
        final profile = LocalRecommendationProfile.migrateFromV1(json);
        for (final e in profile.entries) {
          _stats[songKeyOf(e.song)] = e;
        }
        GenreMetadataService().restore(null);
      } else {
        final profile = LocalRecommendationProfile.fromJson(json);
        for (final e in profile.entries) {
          _stats[songKeyOf(e.song)] = e;
        }
        GenreMetadataService().restore(
          <String, dynamic>{
            'tagIndex': profile.tagIndex,
            'artistIndex': profile.artistIndex,
          },
          savedAt: profile.savedAt,
        );
      }
      _version++;
      _rebuildGenre();
    } catch (_) {
      // 读盘 / 解析失败：静默降级为「无历史」，不影响播放主流程
    }
  }

  /// 记录一次播放：次数 +1、刷新 [PlayStatV2.lastPlayedAt]、当前小时计数 +1，
  /// 并消费播放来源上下文（派生曲风标签）。
  ///
  /// [completionRatio] / [skipped] 为**可选**：不传时不影响调用方（旧调用零改动）。
  /// 写盘失败不影响内存统计。
  Future<void> record(
    SongModel song, {
    double? completionRatio,
    bool skipped = false,
  }) async {
    try {
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;
      final key = songKeyOf(song);

      // 播放来源上下文：一次性消费
      final ctx = PlayContextService().consume();
      final srcTags = <String>{};
      if (ctx.tags.isNotEmpty) {
        GenreMetadataService().observePlaylistTags(song, ctx.tags, nowMs: nowMs);
        for (final t in ctx.tags) {
          srcTags.addAll(extractGenres(t));
        }
      }
      final keyword = ctx.keyword;
      if (keyword != null && keyword.isNotEmpty) {
        GenreMetadataService().observeSearchKeyword(song, keyword, nowMs: nowMs);
        srcTags.addAll(extractGenres(keyword));
      }

      final existing = _stats[key];
      if (existing == null) {
        final hours = List<int>.filled(hoursPerDay, 0);
        if (now.hour >= 0 && now.hour < hoursPerDay) hours[now.hour] = 1;
        var stat = PlayStatV2(
          song: song,
          count: 1,
          lastPlayedAt: nowMs,
          hourCounts: hours,
          artistKey: normalizeArtist(song.artist),
          srcTags: srcTags.toList(),
        );
        if (completionRatio != null) {
          stat = stat.withCompletion(
              ratio: completionRatio,
              skipped: skipped || completionRatio < config.skipThreshold);
        }
        _stats[key] = stat;
      } else {
        var stat = existing.recordPlay(
          newSong: song,
          hour: now.hour,
          nowMs: nowMs,
          addSrcTags: srcTags.toList(),
        );
        if (completionRatio != null) {
          stat = stat.withCompletion(
              ratio: completionRatio,
              skipped: skipped || completionRatio < config.skipThreshold);
        }
        _stats[key] = stat;
      }
      _evictIfNeeded();
      _version++;
      _invalidateCache();
      _rebuildGenre();
      await _save();
    } catch (_) {
      // 静默降级
    }
  }

  /// 结算上一首的**完成度 / 跳过**（切歌时调用）。
  ///
  /// 与 [record] 分离：`record` 记「新歌开始」，本方法补「上一首结束」。
  Future<void> recordCompletion(
    SongModel song, {
    required double completionRatio,
    required bool skipped,
  }) async {
    try {
      final key = songKeyOf(song);
      final existing = _stats[key];
      if (existing == null) return;
      _stats[key] = existing.withCompletion(
        ratio: completionRatio,
        skipped: skipped || completionRatio < config.skipThreshold,
      );
      _version++;
      _invalidateCache();
      await _save();
    } catch (_) {}
  }

  /// 本地多维度个性化推荐（设计文档 §8.1）。
  ///
  /// 新增参数全部**可选且有默认值** → 既有调用方 `suggest(limit: 12)` 零改动。
  /// 无历史时返回空列表（首页自行隐藏区块，沿用现状）。
  List<SongModel> suggest({
    int limit = 10,
    RecommendationMode? mode,
    String? ctxTag,
  }) {
    if (_stats.isEmpty || limit <= 0) return const <SongModel>[];

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nowHour = DateTime.fromMillisecondsSinceEpoch(nowMs).hour;
    final signature = _signature(nowHour, mode, ctxTag);
    final cached = _cache;
    if (cached != null && _cacheSignature == signature) return cached;

    final result = _compute(limit: limit, nowMs: nowMs, nowHour: nowHour, mode: mode);
    _cache = result;
    _cacheSignature = signature;
    return result;
  }

  /// 清空本机推荐数据（播放历史 + 曲风档案 + 来源上下文）。
  Future<void> clear() async {
    _stats.clear();
    GenreMetadataService().clear();
    PlayContextService().clear();
    _version++;
    _invalidateCache();
    await _save();
  }

  // ── 快照（供备份导出 / 导入，见 SettingsBackupService）────────

  /// 导出可序列化的快照（v2，含曲风 / 艺人索引）。
  Map<String, dynamic> snapshot() {
    final genre = GenreMetadataService().snapshot();
    return <String, dynamic>{
      'version': snapshotVersion,
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'entries': _stats.values.map((e) => e.toJson()).toList(growable: false),
      'tagIndex': genre['tagIndex'],
      'artistIndex': genre['artistIndex'],
    };
  }

  /// 从快照恢复（**同时接受 v1 与 v2**）；返回成功恢复的条目数。
  Future<int> restore(Object? json) async {
    if (json is! Map<String, dynamic>) return 0;
    final version = json['version'];
    final LocalRecommendationProfile profile;
    if (version == 1) {
      profile = LocalRecommendationProfile.migrateFromV1(json);
    } else {
      profile = LocalRecommendationProfile.fromJson(json);
    }
    if (profile.entries.isEmpty) return 0;

    _stats.clear();
    for (final entry in profile.entries) {
      _stats[songKeyOf(entry.song)] = entry;
    }
    GenreMetadataService().restore(
      <String, dynamic>{
        'tagIndex': profile.tagIndex,
        'artistIndex': profile.artistIndex,
      },
      savedAt: profile.savedAt,
    );
    _evictIfNeeded();
    _version++;
    _invalidateCache();
    _rebuildGenre();
    await _save();
    return _stats.length;
  }

  // ── 内部实现 ────────────────────────────────────────────────

  List<SongModel> _compute({
    required int limit,
    required int nowMs,
    required int nowHour,
    RecommendationMode? mode,
  }) {
    final total = totalPlays;
    if (total <= 0) return const <SongModel>[];

    final genre = GenreMetadataService();
    final distinctArtists =
        _stats.values.map((e) => e.artistKey).toSet().length;
    final wantCold = mode == RecommendationMode.cold;
    final autoCold = mode == null &&
        (total < config.coldMinPlays || distinctArtists < 2);
    final isCold = wantCold || autoCold;
    final cfg = isCold
        ? config.copyWith(exploreRatio: 0.30) // 冷启动探索比例上调
        : config;

    // 组装画像
    final artistPlays = <String, int>{};
    final artistLastDays = <String, int>{};
    final tagPlays = <String, int>{};
    final tagLastDays = <String, int>{};
    final hourArtistPlays = <String, int>{};
    final hourTagPlays = <String, int>{};

    // 每曲标签（缓存一次，供多处使用）
    final tagsByKey = <String, Map<String, double>>{};

    for (final e in _stats.values) {
      final artist = e.artistKey.isNotEmpty
          ? e.artistKey
          : normalizeArtist(e.song.artist);
      artistPlays[artist] = (artistPlays[artist] ?? 0) + e.count;
      final days = e.hoursSinceLastPlay(nowMs) ~/ 24;
      final prevDays = artistLastDays[artist];
      if (prevDays == null || days < prevDays) artistLastDays[artist] = days;

      for (var h = 0; h < hoursPerDay; h++) {
        final c = e.hourOf(h);
        if (c == 0) continue;
        final ak = '$h|$artist';
        hourArtistPlays[ak] = (hourArtistPlays[ak] ?? 0) + c;
      }

      final tags = genre.tagsFor(e.song, cfg, nowMs: nowMs);
      tagsByKey[songKeyOf(e.song)] = tags;
      tags.forEach((tag, _) {
        tagPlays[tag] = (tagPlays[tag] ?? 0) + e.count;
        final prev = tagLastDays[tag];
        if (prev == null || days < prev) tagLastDays[tag] = days;
        for (var h = 0; h < hoursPerDay; h++) {
          final c = e.hourOf(h);
          if (c == 0) continue;
          final tk = '$h|$tag';
          hourTagPlays[tk] = (hourTagPlays[tk] ?? 0) + c;
        }
      });
    }

    final profile = ProfileInputs(
      totalPlays: total,
      artistPlays: artistPlays,
      artistLastDays: artistLastDays,
      tagPlays: tagPlays,
      tagLastDays: tagLastDays,
      hourArtistPlays: hourArtistPlays,
      hourTagPlays: hourTagPlays,
      nowHour: nowHour,
    );

    final window = hourWindowHours(nowHour, cfg.hourWindow);
    final candidates = <CandidateSong>[];
    for (final e in _stats.values) {
      var windowPlays = 0;
      for (final h in window) {
        windowPlays += e.hourOf(h);
      }
      final artist = e.artistKey.isNotEmpty
          ? e.artistKey
          : normalizeArtist(e.song.artist);
      candidates.add(CandidateSong(
        song: e.song,
        features: SongFeatures(
          songId: e.song.id,
          artistKey: artist,
          name: e.song.name,
          count: e.count,
          hourCountAtWindow: windowPlays,
          hoursSinceLastPlay: e.hoursSinceLastPlay(nowMs),
          tags: tagsByKey[songKeyOf(e.song)] ?? const <String, double>{},
          completion: e.avgCompletion,
          skipRate: e.skipRate,
        ),
      ));
    }

    final ranked = RecommendationEngine.recommend(
      RecommendationInputs(candidates: candidates, profile: profile),
      cfg,
      limit,
    );
    return ranked.map((s) => s.song).toList(growable: false);
  }

  /// 缓存签名：`totalPlays | entries | nowHour | 内存版本 | 曲风版本 | mode | ctxTag`。
  String _signature(int nowHour, RecommendationMode? mode, String? ctxTag) {
    return '$totalPlays|${_stats.length}|$nowHour|$_version|'
        '${GenreMetadataService().version}|${mode?.index ?? -1}|${ctxTag ?? ''}';
  }

  void _invalidateCache() {
    _cache = null;
    _cacheSignature = null;
  }

  /// 重算曲风推断的 S4/S5（幂等）。
  void _rebuildGenre() {
    try {
      GenreMetadataService()
          .rebuildFromHistory(_stats.values.toList(), config);
    } catch (_) {}
  }

  /// 超出 [maxEntries] 时按「最久未播放」淘汰。
  void _evictIfNeeded() {
    if (_stats.length <= maxEntries) return;
    final sorted = _stats.values.toList()
      ..sort((a, b) => a.lastPlayedAt.compareTo(b.lastPlayedAt));
    final removeCount = _stats.length - maxEntries;
    for (final e in sorted.take(removeCount)) {
      _stats.remove(songKeyOf(e.song));
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
}

/// **确定性纯函数**：旧版单曲级推荐打分（三项线性加权）。
///
/// 保留仅为**向后兼容**（既有调用/测试不回归）。新逻辑统一走
/// [RecommendationEngine.scoreSong]（多维 + 交叉 + 降级归一化）。
@Deprecated('改用 RecommendationEngine.scoreSong（多维度本地个性化推荐）')
double recommendationScore({
  required int count,
  required int daysSinceLastPlay,
  required int hourCountAtNow,
  required int totalPlays,
}) {
  final c = count < 0 ? 0 : count;
  final days = daysSinceLastPlay < 0 ? 0 : daysSinceLastPlay;
  final total = totalPlays < 0 ? 0 : totalPlays;
  final hourHits =
      hourCountAtNow < 0 ? 0 : math.min(hourCountAtNow, c == 0 ? 0 : c);
  final recency = 1 / (1 + days);
  final freq = total <= 0 ? 0.0 : math.log(1 + c) / math.log(1 + total);
  final hourAffinity = hourHits / (c > 0 ? c : 1);
  return recency * 0.5 + freq * 0.3 + hourAffinity * 0.2;
}

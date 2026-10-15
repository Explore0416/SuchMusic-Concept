/// 「猜你想听」多维度本地个性化推荐 —— 数据结构层。
///
/// 依据设计文档 `docs/ARCH-猜你想听.md` §4 落地：本文件只放**纯数据**，
/// 不含任何 IO / 网络 / 时钟依赖，便于单测与复用。
///
/// ── 数据边界（重要）─────────────────────────────────────────
/// 本文件描述的全部数据（播放历史统计、曲风标签推断结果）**只保存在本机**，
/// **不上传、不随账号同步、不参与任何网络请求**。
library;

import 'song_model.dart';

// ── 枚举 ──────────────────────────────────────────────────────

/// 曲风标签的推断来源（对应设计文档 S1–S5）。
enum TagSource {
  /// S1 歌单来源标签（用户主动进入某分类歌单）
  playlist,

  /// S2 官方分类字典匹配
  category,

  /// S3 搜索关键词标签
  search,

  /// S4 艺人聚合代理（本地聚合）
  artist,

  /// S5 共现传播（同一播放会话内互相传播）
  cooccurrence,
}

/// 推荐运行模式（设计文档 §8.4）。
enum RecommendationMode {
  /// 自动：由引擎根据历史量判定冷启动 / 常规
  auto,

  /// 冷启动：历史样本不足
  cold,

  /// 常规
  normal,
}

// ── 纯函数入参结构（§8.4）──────────────────────────────────────

/// 单曲特征（纯函数入参，字段全部预计算，保证 `scoreSong` 确定性）。
class SongFeatures {
  const SongFeatures({
    required this.songId,
    required this.artistKey,
    required this.name,
    required this.count,
    required this.hourCountAtWindow,
    required this.hoursSinceLastPlay,
    required this.tags,
    required this.completion,
    required this.skipRate,
  });

  /// 曲目 id。
  final String songId;

  /// 主艺人规范化键（多艺人取首位）。
  final String artistKey;

  /// 歌名（用于去重）。
  final String name;

  /// 累计播放次数。
  final int count;

  /// 当前时段环形窗口内的播放次数（`windowPlays(s,h)`）。
  final int hourCountAtWindow;

  /// 距最近一次播放的小时数（`now - lastPlayedAt`）。
  final int hoursSinceLastPlay;

  /// 已过滤 `conf >= tagConfMin` 的曲风标签 → 置信度。
  final Map<String, double> tags;

  /// 平均完成度 ∈[0,1]（无样本时为中性 0.5）。
  final double completion;

  /// 跳过率 ∈[0,1]。
  final double skipRate;

  /// 距最近一次播放的天数（由 [hoursSinceLastPlay] 换算）。
  double get daysSinceLastPlay => hoursSinceLastPlay / 24.0;
}

/// 全局画像（纯函数入参）。
class ProfileInputs {
  const ProfileInputs({
    required this.totalPlays,
    required this.artistPlays,
    required this.artistLastDays,
    required this.tagPlays,
    required this.tagLastDays,
    required this.hourArtistPlays,
    required this.hourTagPlays,
    required this.nowHour,
  });

  /// 全部条目的累计播放次数。
  final int totalPlays;

  /// 艺人 → 该艺人全部曲目 `count` 之和。
  final Map<String, int> artistPlays;

  /// 艺人 → 该艺人最近一次播放距今的天数。
  final Map<String, int> artistLastDays;

  /// 曲风标签 → 该标签全部曲目 `count` 之和。
  final Map<String, int> tagPlays;

  /// 曲风标签 → 该标签最近一次播放距今的天数。
  final Map<String, int> tagLastDays;

  /// 时段 × 艺人 → 播放次数，键形如 `"h|artist"`。
  final Map<String, int> hourArtistPlays;

  /// 时段 × 曲风 → 播放次数，键形如 `"h|tag"`。
  final Map<String, int> hourTagPlays;

  /// 当前小时（0–23）。
  final int nowHour;

  /// 取 `h|artist` 键的播放次数。
  int artistPlaysAtHour(String artistKey, int hour) =>
      hourArtistPlays['$hour|$artistKey'] ?? 0;

  /// 取 `h|tag` 键的播放次数。
  int tagPlaysAtHour(String tag, int hour) =>
      hourTagPlays['$hour|$tag'] ?? 0;

  /// 空画像（无历史时使用）。
  static const ProfileInputs empty = ProfileInputs(
    totalPlays: 0,
    artistPlays: {},
    artistLastDays: {},
    tagPlays: {},
    tagLastDays: {},
    hourArtistPlays: {},
    hourTagPlays: {},
    nowHour: 0,
  );
}

/// 推荐参数集中配置（设计文档 §5.4，均为经验默认值，可注入覆盖）。
class RecommendationConfig {
  const RecommendationConfig({
    this.wSong = 0.30,
    this.wArtist = 0.25,
    this.wGenre = 0.20,
    this.wTime = 0.15,
    this.wCross = 0.35,
    this.halfLifeSongDays = 14.0,
    this.halfLifeArtistDays = 30.0,
    this.halfLifeGenreDays = 60.0,
    this.hourWindow = 2,
    this.tagConfMin = 0.30,
    this.maxArtistShare = 0.33,
    this.exploreRatio = 0.15,
    this.coldMinPlays = 30,
    this.skipThreshold = 0.30,
    this.sessionGapMin = 30,
    this.maxTagsPerSong = 3,
    this.beta = 0.5,
    this.mmrLambda = 0.4,
  });

  /// 单曲权重。
  final double wSong;

  /// 艺人权重。
  final double wArtist;

  /// 曲风权重。
  final double wGenre;

  /// 时段权重。
  final double wTime;

  /// 交叉项权重。
  final double wCross;

  /// 单曲半衰期（天）。
  final double halfLifeSongDays;

  /// 艺人半衰期（天）。
  final double halfLifeArtistDays;

  /// 曲风半衰期（天）。
  final double halfLifeGenreDays;

  /// 时段环形窗口半径（小时）。
  final int hourWindow;

  /// 标签置信阈值。
  final double tagConfMin;

  /// 单艺人占比上限。
  final double maxArtistShare;

  /// 探索比例。
  final double exploreRatio;

  /// 冷启动阈值（总播放次数）。
  final int coldMinPlays;

  /// 跳过阈值（完成度低于此值记为跳过）。
  final double skipThreshold;

  /// 播放会话间隔（分钟）。
  final int sessionGapMin;

  /// 每曲最多保留标签数。
  final int maxTagsPerSong;

  /// 艺人时段偏置系数 β。
  final double beta;

  /// MMR 打散强度 λ。
  final double mmrLambda;

  /// 全维度权重和（不随降级变化，用于量纲稳定）。
  double get fullWeightSum => wSong + wArtist + wGenre + wTime;

  /// 复制并覆盖部分参数（冷启动上调探索比例等场景用）。
  RecommendationConfig copyWith({
    double? wSong,
    double? wArtist,
    double? wGenre,
    double? wTime,
    double? wCross,
    double? halfLifeSongDays,
    double? halfLifeArtistDays,
    double? halfLifeGenreDays,
    int? hourWindow,
    double? tagConfMin,
    double? maxArtistShare,
    double? exploreRatio,
    int? coldMinPlays,
    double? skipThreshold,
    int? sessionGapMin,
    int? maxTagsPerSong,
    double? beta,
    double? mmrLambda,
  }) {
    return RecommendationConfig(
      wSong: wSong ?? this.wSong,
      wArtist: wArtist ?? this.wArtist,
      wGenre: wGenre ?? this.wGenre,
      wTime: wTime ?? this.wTime,
      wCross: wCross ?? this.wCross,
      halfLifeSongDays: halfLifeSongDays ?? this.halfLifeSongDays,
      halfLifeArtistDays: halfLifeArtistDays ?? this.halfLifeArtistDays,
      halfLifeGenreDays: halfLifeGenreDays ?? this.halfLifeGenreDays,
      hourWindow: hourWindow ?? this.hourWindow,
      tagConfMin: tagConfMin ?? this.tagConfMin,
      maxArtistShare: maxArtistShare ?? this.maxArtistShare,
      exploreRatio: exploreRatio ?? this.exploreRatio,
      coldMinPlays: coldMinPlays ?? this.coldMinPlays,
      skipThreshold: skipThreshold ?? this.skipThreshold,
      sessionGapMin: sessionGapMin ?? this.sessionGapMin,
      maxTagsPerSong: maxTagsPerSong ?? this.maxTagsPerSong,
      beta: beta ?? this.beta,
      mmrLambda: mmrLambda ?? this.mmrLambda,
    );
  }

  /// 默认配置。
  static const RecommendationConfig defaults = RecommendationConfig();
}

// ── 标签与统计条目（§4.1 / §4.3）───────────────────────────────

/// 一条曲风标签观测（`GenreMetadataService` 内部产出）。
class SongTag {
  const SongTag({
    required this.songKey,
    required this.tag,
    required this.confidence,
    required this.source,
    required this.updatedAt,
  });

  /// 曲目键，形如 `"${source.code}:${song.id}"`。
  final String songKey;

  /// 标签名。
  final String tag;

  /// 置信度 ∈[0,1]。
  final double confidence;

  /// 来源信号。
  final TagSource source;

  /// 最近更新时间（ms）。
  final int updatedAt;
}

/// 单曲统计条目（v2，向后兼容扩展）。
class PlayStatV2 {
  const PlayStatV2({
    required this.song,
    required this.count,
    required this.lastPlayedAt,
    required this.hourCounts,
    this.completionSum = 0,
    this.completionCount = 0,
    this.skipCount = 0,
    this.srcTags = const <String>[],
    required this.artistKey,
  });

  /// 曲目。
  final SongModel song;

  /// 累计播放次数。
  final int count;

  /// 最近一次播放时间（毫秒时间戳）。
  final int lastPlayedAt;

  /// 24 个整点段的播放次数，下标 = 小时（0–23）。
  final List<int> hourCounts;

  /// Σ 完成度比例 ∈[0,1]。
  final double completionSum;

  /// 有完成度样本的播放次数。
  final int completionCount;

  /// 提前切走次数（completion < skipThreshold）。
  final int skipCount;

  /// 播放来源上下文带来的标签（S1/S3 派生的曲风标签）。
  final List<String> srcTags;

  /// 主艺人规范化键（多艺人取首位）。
  final String artistKey;

  /// 平均完成度（无样本时中性 0.5）。
  double get avgCompletion =>
      completionCount > 0 ? completionSum / completionCount : 0.5;

  /// 跳过率。
  double get skipRate => count > 0 ? skipCount / count : 0.0;

  /// 最近一次播放时间（DateTime）。
  DateTime get lastPlayedDateTime =>
      DateTime.fromMillisecondsSinceEpoch(lastPlayedAt);

  /// 距 [nowMs] 的小时数（负数按 0 处理）。
  int hoursSinceLastPlay(int nowMs) {
    final diff = nowMs - lastPlayedAt;
    if (diff <= 0) return 0;
    return diff ~/ (1000 * 60 * 60);
  }

  /// 取某小时的播放次数（越界返回 0）。
  int hourOf(int hour) {
    if (hour < 0 || hour >= hourCounts.length) return 0;
    return hourCounts[hour];
  }

  /// 创建副本并累加一次播放（保留既有统计）。
  PlayStatV2 recordPlay({
    required SongModel newSong,
    required int hour,
    required int nowMs,
    List<String> addSrcTags = const <String>[],
  }) {
    final hours = List<int>.from(hourCounts);
    while (hours.length < hoursPerDay) {
      hours.add(0);
    }
    if (hour >= 0 && hour < hoursPerDay) {
      hours[hour] = hours[hour] + 1;
    }
    return PlayStatV2(
      song: newSong,
      count: count + 1,
      lastPlayedAt: nowMs,
      hourCounts: hours,
      completionSum: completionSum,
      completionCount: completionCount,
      skipCount: skipCount,
      srcTags: _mergeTags(srcTags, addSrcTags),
      artistKey: artistKey,
    );
  }

  /// 累加一次完成度样本。
  PlayStatV2 withCompletion({required double ratio, required bool skipped}) {
    final clamped = ratio.isNaN ? 0.0 : ratio.clamp(0.0, 1.0);
    return PlayStatV2(
      song: song,
      count: count,
      lastPlayedAt: lastPlayedAt,
      hourCounts: hourCounts,
      completionSum: completionSum + clamped,
      completionCount: completionCount + 1,
      skipCount: skipped ? skipCount + 1 : skipCount,
      srcTags: srcTags,
      artistKey: artistKey,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'song': songToJson(song),
        'count': count,
        'lastPlayedAt': lastPlayedAt,
        'hourCounts': hourCounts,
        'completionSum': completionSum,
        'completionCount': completionCount,
        'skipCount': skipCount,
        'srcTags': srcTags,
        'artistKey': artistKey,
      };

  /// 从 JSON 解析；脏数据返回 null（由调用方跳过）。
  static PlayStatV2? fromJson(Map<String, dynamic> json) {
    final song = songFromJson(json['song']);
    if (song == null) return null;
    final hours = <int>[];
    final rawHours = json['hourCounts'];
    if (rawHours is List) {
      for (final v in rawHours) {
        hours.add(_asInt(v));
      }
    }
    while (hours.length < hoursPerDay) {
      hours.add(0);
    }
    final millis = json.containsKey('lastPlayedAt')
        ? _asInt(json['lastPlayedAt'])
        : 0;
    return PlayStatV2(
      song: song,
      count: _asInt(json['count']),
      lastPlayedAt: millis,
      hourCounts: hours,
      completionSum: _asDouble(json['completionSum']),
      completionCount: _asInt(json['completionCount']),
      skipCount: _asInt(json['skipCount']),
      srcTags: _asStringList(json['srcTags']),
      artistKey: json['artistKey']?.toString() ?? normalizeArtist(song.artist),
    );
  }
}

/// 24 小时常量（跨文件共用，避免循环依赖）。
const int hoursPerDay = 24;

// ── 推荐档案（§4.2 / §4.3）─────────────────────────────────────

/// 本地推荐档案：播放条目 + 曲风标签索引 + 艺人曲风索引。
class LocalRecommendationProfile {
  LocalRecommendationProfile({
    this.version = snapshotVersion,
    this.savedAt = 0,
    List<PlayStatV2>? entries,
    Map<String, Map<String, double>>? tagIndex,
    Map<String, Map<String, double>>? artistIndex,
  })  : entries = entries ?? <PlayStatV2>[],
        tagIndex = tagIndex ?? <String, Map<String, double>>{},
        artistIndex = artistIndex ?? <String, Map<String, double>>{};

  /// 快照结构版本（v1 → v2）。
  static const int snapshotVersion = 2;

  /// 档案版本。
  int version;

  /// 保存时间（ms）。
  int savedAt;

  /// 播放条目。
  final List<PlayStatV2> entries;

  /// 曲目键 → {标签 → 置信度}。
  final Map<String, Map<String, double>> tagIndex;

  /// 艺人 → {标签 → 占比}。
  final Map<String, Map<String, double>> artistIndex;

  /// 导出为可序列化结构。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'savedAt': savedAt,
        'entries': entries.map((e) => e.toJson()).toList(growable: false),
        'tagIndex': tagIndex,
        'artistIndex': artistIndex,
      };

  /// 从 JSON 解析（容错：缺字段按默认值）。
  static LocalRecommendationProfile fromJson(Map<String, dynamic> json) {
    final entries = <PlayStatV2>[];
    final rawEntries = json['entries'];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is! Map<String, dynamic>) continue;
        final stat = PlayStatV2.fromJson(item);
        if (stat != null) entries.add(stat);
      }
    }
    return LocalRecommendationProfile(
      version: snapshotVersion,
      savedAt: _asInt(json['savedAt']),
      entries: entries,
      tagIndex: _decodeIndex(json['tagIndex']),
      artistIndex: _decodeIndex(json['artistIndex']),
    );
  }

  /// v1 → v2 迁移：**逐字段保留**旧历史（count/lastPlayedAt/hourCounts/song），
  /// 仅补默认值；tagIndex/artistIndex 首启为空，靠后续推断填充。幂等。
  static LocalRecommendationProfile migrateFromV1(Map<String, dynamic> v1Json) {
    final entries = <PlayStatV2>[];
    final rawEntries = v1Json['entries'];
    if (rawEntries is List) {
      for (final item in rawEntries) {
        if (item is! Map<String, dynamic>) continue;
        final song = songFromJson(item['song']);
        if (song == null) continue;
        // 原样保留 count / lastPlayedAt / hourCounts
        final hours = <int>[];
        final rawHours = item['hourCounts'];
        if (rawHours is List) {
          for (final v in rawHours) {
            hours.add(_asInt(v));
          }
        }
        while (hours.length < hoursPerDay) {
          hours.add(0);
        }
        entries.add(PlayStatV2(
          song: song,
          count: _asInt(item['count']),
          lastPlayedAt: _asInt(item['lastPlayedAt']),
          hourCounts: hours,
          completionSum: 0, // 缺省
          completionCount: 0, // 缺省
          skipCount: 0, // 缺省
          srcTags: const <String>[], // 缺省
          artistKey: normalizeArtist(song.artist), // 派生
        ));
      }
    }
    return LocalRecommendationProfile(
      version: snapshotVersion,
      savedAt: _asInt(v1Json['savedAt']),
      entries: entries,
      tagIndex: <String, Map<String, double>>{},
      artistIndex: <String, Map<String, double>>{},
    );
  }
}

// ── 打分中间结果 ───────────────────────────────────────────────

/// 打分中间结果（供排序 / 多样性打散使用）。
class Scored {
  const Scored({
    required this.song,
    required this.artistKey,
    required this.score,
    required this.count,
    required this.tags,
  });

  /// 曲目。
  final SongModel song;

  /// 主艺人键。
  final String artistKey;

  /// 最终得分。
  final double score;

  /// 累计播放次数（探索槽低频谱用）。
  final int count;

  /// 已过滤的标签集合。
  final Map<String, double> tags;
}

// ── 通用工具 ──────────────────────────────────────────────────

/// 规范化艺人键：多艺人（`/`、`、`、`&`、`;` 分隔）取首位并 trim。
String normalizeArtist(String artist) {
  var first = artist.trim();
  for (final sep in const <String>['/', '、', '&', ';', ',']) {
    final idx = first.indexOf(sep);
    if (idx > 0) first = first.substring(0, idx);
  }
  return first.trim();
}

/// 曲目键：`"${source.code}:${song.id}"`；本地曲目 `local:${uri}`。
String songKeyOf(SongModel song) {
  if (song.source == SongSource.local && song.localUri != null) {
    return 'local:${song.localUri}';
  }
  return '${song.source.code}:${song.id}';
}

/// 序列化曲目（在 [SongModel.toJson] 之上补 `localUri`，保证本地音乐可还原）。
Map<String, dynamic> songToJson(SongModel song) => <String, dynamic>{
      ...song.toJson(),
      'localUri': song.localUri,
    };

/// 反序列化曲目；非法数据返回 null。
SongModel? songFromJson(Object? raw) {
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

// ── 私有工具 ──────────────────────────────────────────────────

List<String> _mergeTags(List<String> base, List<String> extra) {
  if (extra.isEmpty) return base;
  final merged = List<String>.from(base);
  for (final t in extra) {
    if (t.isNotEmpty && !merged.contains(t)) merged.add(t);
  }
  return merged;
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse(v?.toString() ?? '') ?? 0;
}

double _asDouble(Object? v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

List<String> _asStringList(Object? v) {
  if (v is! List) return const <String>[];
  return v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
}

Map<String, Map<String, double>> _decodeIndex(Object? raw) {
  final result = <String, Map<String, double>>{};
  if (raw is! Map) return result;
  raw.forEach((k, v) {
    if (v is! Map) return;
    final inner = <String, double>{};
    v.forEach((ik, iv) {
      inner[ik.toString()] = _asDouble(iv);
    });
    result[k.toString()] = inner;
  });
  return result;
}

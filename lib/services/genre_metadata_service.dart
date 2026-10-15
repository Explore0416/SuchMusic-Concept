import '../models/recommendation_profile.dart';
import '../models/song_model.dart';
import 'recommendation_engine.dart';

/// 曲风标签推断服务（单例）—— 设计文档 §3 核心。
///
/// ── 为什么需要推断 ───────────────────────────────────────────
/// 已封装的在线接口（网易云 / 酷狗 / 本地）**均不提供单曲曲风字段**，
/// 因此曲风只能靠**本地行为信号**推断，并必须允许完全缺省（优雅降级）。
///
/// ── 五条信号（S1–S5）────────────────────────────────────────
/// | 编号 | 信号 | 基础置信度 | 采集点 |
/// |---|---|---|---|
/// | S1 | 歌单来源标签 | 1.0 | 各入口 `setSource` → `observePlaylistTags` |
/// | S2 | 官方分类字典匹配 | 0.8 | `refreshCategoryDictionary`（本地匹配） |
/// | S3 | 搜索关键词标签 | 0.4 | 搜索页 `setSource(keyword)` → `observeSearchKeyword` |
/// | S4 | 艺人聚合代理 | 0.5 | `rebuildFromHistory` 本地聚合 |
/// | S5 | 共现传播 | 0.3 | `rebuildFromHistory` 会话切分 |
///
/// 置信度合成：`conf(s,t) = 1 - Π(1 - cᵢ(s,t))`，`cᵢ = baseᵢ · 0.5^(Δtᵢ/Hᵢ)`。
/// 每曲最多保留 3 个标签；`conf < tagConfMin` 视为不可信、不参与打分。
///
/// ── 数据边界（重要）──────────────────────────────────────────
/// 全部推断数据**只保存在本机**（随播放历史快照），**不上传、不参与网络请求**。
class GenreMetadataService {
  static final GenreMetadataService _instance = GenreMetadataService._internal();
  factory GenreMetadataService() => _instance;
  GenreMetadataService._internal();

  /// 逐信号的持久化累计索引：`songKey → {tag → conf}`（S1/S2/S3 叠加）。
  final Map<String, Map<String, double>> _obsIndex =
      <String, Map<String, double>>{};

  /// S5 共现覆盖层（每次 `rebuildFromHistory` **从历史重算**，幂等，不累计）。
  final Map<String, Map<String, double>> _cooccurIndex =
      <String, Map<String, double>>{};

  /// 艺人 → {tag → 占比}（S4，本地聚合）。
  final Map<String, Map<String, double>> _artistIndex =
      <String, Map<String, double>>{};

  /// 每个 `songKey#tag` 的最近更新时间（ms，不持久化；恢复时以 savedAt 兜底）。
  final Map<String, int> _tagUpdatedAt = <String, int>{};

  /// 版本号（缓存签名用；每次变更 +1）。
  int _version = 0;

  /// 累计索引规模上限（设计文档 §7.4）。
  static const int maxSongs = 1000;
  static const int maxArtists = 500;

  /// 每曲最多保留标签数（= RecommendationConfig.maxTagsPerSong 默认值）。
  static const int maxTagsPerSong = 3;

  /// S4 代理置信度弱化系数（艺人聚合不是该曲的直接证据）。
  static const double s4ProxyWeight = 0.6;

  /// 各信号基础置信度（设计文档 §3.2）。
  static const double confPlaylist = 1.0;
  static const double confCategory = 0.8;
  static const double confSearch = 0.4;
  static const double confCooccurrence = 0.3;

  /// 标签衰减半衰期（天，= RecommendationConfig.halfLifeGenreDays 默认值）。
  static const double _genreHalfLife = 60.0;

  /// 当前版本（供 `PlayHistoryService` 计算缓存签名）。
  int get version => _version;

  /// 曲目键 → {标签 → 置信度}（S1/S2/S3 累计部分）。
  Map<String, Map<String, double>> get tagIndex =>
      Map<String, Map<String, double>>.unmodifiable(_obsIndex);

  /// 艺人 → {标签 → 占比}。
  Map<String, Map<String, double>> get artistIndex =>
      Map<String, Map<String, double>>.unmodifiable(_artistIndex);

  // ── 读取 ─────────────────────────────────────────────────────

  /// 解析某曲目的有效标签（已过滤 `conf >= tagConfMin` 并施加衰减）。
  ///
  /// 直接标签缺失时回退到 **S4 艺人聚合代理**（按 [s4ProxyWeight] 弱化），
  /// 仍无则返回空 Map（触发降级归一化）。
  Map<String, double> tagsFor(
    SongModel song,
    RecommendationConfig cfg, {
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final key = songKeyOf(song);
    final out = <String, double>{};

    void merge(Map<String, double>? map, double Function(String tag) decayOf) {
      if (map == null) return;
      map.forEach((tag, conf) {
        final d = (conf * decayOf(tag)).clamp(0.0, 1.0);
        final prev = out[tag] ?? 0.0;
        out[tag] = (1 - (1 - prev) * (1 - d)).clamp(0.0, 1.0);
      });
    }

    // S1/S2/S3：逐标签施加时间衰减后合并
    merge(_obsIndex[key], (tag) {
      final upd = _tagUpdatedAt['$key#$tag'];
      final days = upd == null ? 0.0 : (now - upd) / (24 * 60 * 60 * 1000.0);
      return decay(days, cfg.halfLifeGenreDays);
    });
    // S5：共现覆盖层已按会话重算，直接合并
    merge(_cooccurIndex[key], (_) => 1.0);

    out.removeWhere((_, conf) => conf < cfg.tagConfMin);

    // S4 回退（仅当无直接标签时）
    if (out.isEmpty) {
      final artistTags = _artistIndex[normalizeArtist(song.artist)];
      if (artistTags != null) {
        artistTags.forEach((tag, ratio) {
          final proxy = ratio * s4ProxyWeight;
          if (proxy >= cfg.tagConfMin) out[tag] = proxy;
        });
      }
    }
    return out;
  }

  // ── 采集入口（S1/S3）────────────────────────────────────────

  /// S1：记录「用户从某歌单 / 分类播放」带来的标签。
  ///
  /// [rawTags] 为可用于曲风关键词匹配的文本（歌单名 / 分类名）。
  void observePlaylistTags(
    SongModel song,
    List<String> rawTags, {
    int? nowMs,
  }) {
    try {
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      final genres = <String>{};
      for (final t in rawTags) {
        genres.addAll(extractGenres(t));
      }
      for (final g in genres) {
        _blend(songKeyOf(song), g, confPlaylist, now);
      }
    } catch (_) {
      // 静默降级
    }
  }

  /// S3：记录「搜索某关键词后播放」带来的弱标签。
  void observeSearchKeyword(
    SongModel song,
    String keyword, {
    int? nowMs,
  }) {
    try {
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      for (final g in extractGenres(keyword)) {
        _blend(songKeyOf(song), g, confSearch, now);
      }
    } catch (_) {}
  }

  /// S2：官方分类字典匹配（本地匹配部分）。
  ///
  /// [categorySongs] 为 `分类标签 → 该分类下的曲目`（由调用方在线拉取后传入）。
  /// 本方法仅做 **本地匹配落库**：把历史中已听过的曲目按 `(artist, name)`
  /// 命中分类，赋予该分类标签（基础置信度 0.8）。
  ///
  /// 说明（偏差）：在线拉取未接线（避免风控 / 非确定网络依赖），仅保留本地
  /// 匹配入口；调用方可周期调用（建议 ≥7 天一次）。
  void refreshCategoryDictionary({
    required Map<String, List<SongModel>> categorySongs,
    required List<PlayStatV2> history,
    int? nowMs,
  }) {
    try {
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      final lookup = <String, String>{};
      for (final e in history) {
        lookup[_matchKey(e.song.artist, e.song.name)] = songKeyOf(e.song);
      }
      categorySongs.forEach((category, songs) {
        for (final g in extractGenres(category)) {
          for (final s in songs) {
            final songKey = lookup[_matchKey(s.artist, s.name)];
            if (songKey == null) continue;
            _blend(songKey, g, confCategory, now);
          }
        }
      });
    } catch (_) {}
  }

  /// 从播放历史重算 S5（共现传播）与 S4（艺人聚合）。
  ///
  /// 幂等：`_cooccurIndex` / `_artistIndex` 每次整体重建，不随调用次数累积。
  void rebuildFromHistory(
    List<PlayStatV2> entries,
    RecommendationConfig cfg, {
    int? nowMs,
  }) {
    try {
      _rebuildCooccurrence(entries, cfg);
      _rebuildArtistIndex(entries, cfg);
      _version++;
    } catch (_) {}
  }

  // ── 快照 ─────────────────────────────────────────────────────

  /// 导出：`{'tagIndex':..., 'artistIndex':...}`（随播放历史一起仅存本机 / 备份）。
  ///
  /// 返回**深拷贝**，避免调用方（如 `clear()`）改动内部索引时影响已导出的快照。
  Map<String, dynamic> snapshot() => <String, dynamic>{
        'tagIndex': <String, Map<String, double>>{
          for (final e in _obsIndex.entries)
            e.key: Map<String, double>.from(e.value),
        },
        'artistIndex': <String, Map<String, double>>{
          for (final e in _artistIndex.entries)
            e.key: Map<String, double>.from(e.value),
        },
      };

  /// 从快照恢复；返回恢复的曲目数（0 表示无效）。
  int restore(Object? json, {int? savedAt}) {
    try {
      if (json is! Map) return 0;
      _obsIndex.clear();
      _artistIndex.clear();
      _tagUpdatedAt.clear();
      _cooccurIndex.clear();

      final tagIndex = json['tagIndex'];
      if (tagIndex is Map) {
        tagIndex.forEach((k, v) {
          if (v is! Map) return;
          final inner = <String, double>{};
          v.forEach((ik, iv) {
            inner[ik.toString()] = _asDouble(iv);
          });
          if (inner.isNotEmpty) _obsIndex[k.toString()] = inner;
        });
      }
      final artistIndex = json['artistIndex'];
      if (artistIndex is Map) {
        artistIndex.forEach((k, v) {
          if (v is! Map) return;
          final inner = <String, double>{};
          v.forEach((ik, iv) {
            inner[ik.toString()] = _asDouble(iv);
          });
          if (inner.isNotEmpty) _artistIndex[k.toString()] = inner;
        });
      }

      final stamp = savedAt ?? DateTime.now().millisecondsSinceEpoch;
      _obsIndex.forEach((songKey, tags) {
        tags.forEach((tag, _) {
          _tagUpdatedAt['$songKey#$tag'] = stamp;
        });
      });
      _version++;
      return _obsIndex.length;
    } catch (_) {
      return 0;
    }
  }

  /// 清空全部推断数据（设置页「清除本地推荐数据」用）。
  void clear() {
    _obsIndex.clear();
    _cooccurIndex.clear();
    _artistIndex.clear();
    _tagUpdatedAt.clear();
    _version++;
  }

  // ── 内部实现 ─────────────────────────────────────────────────

  /// 置信度叠加 + 衰减：`conf_new = 1 - (1 - conf_old·decay)(1 - baseConf)`。
  void _blend(String songKey, String tag, double baseConf, int nowMs) {
    if (tag.isEmpty || baseConf <= 0) return;
    final key = '$songKey#$tag';
    final prev = _obsIndex[songKey]?[tag];
    final prevAt = _tagUpdatedAt[key];
    double newConf;
    if (prev == null || prevAt == null) {
      newConf = baseConf;
    } else {
      final days = (nowMs - prevAt) / (24 * 60 * 60 * 1000.0);
      final decayed = prev * decay(days, _genreHalfLife);
      newConf = 1 - (1 - decayed) * (1 - baseConf);
    }
    _obsIndex.putIfAbsent(songKey, () => <String, double>{})[tag] =
        newConf.clamp(0.0, 1.0);
    _tagUpdatedAt[key] = nowMs;
    _enforceSongLimit(songKey);
    _enforceGlobalLimit();
    _version++;
  }

  /// 每曲最多保留 [maxTagsPerSong] 个标签（高置信优先）。
  void _enforceSongLimit(String songKey) {
    final tags = _obsIndex[songKey];
    if (tags == null || tags.length <= maxTagsPerSong) return;
    final sorted = tags.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    _obsIndex[songKey] = <String, double>{
      for (final e in sorted.take(maxTagsPerSong)) e.key: e.value,
    };
    for (final e in sorted.skip(maxTagsPerSong)) {
      _tagUpdatedAt.remove('$songKey#${e.key}');
    }
  }

  /// 曲目规模上限（最久未更新淘汰）。
  void _enforceGlobalLimit() {
    if (_obsIndex.length <= maxSongs) return;
    final keys = _obsIndex.keys.toList()
      ..sort((a, b) => _songUpdatedAt(a).compareTo(_songUpdatedAt(b)));
    for (final k in keys.take(_obsIndex.length - maxSongs)) {
      _obsIndex.remove(k);
      _tagUpdatedAt.removeWhere((tk, _) => tk.startsWith('$k#'));
    }
  }

  int _songUpdatedAt(String songKey) {
    var latest = 0;
    _tagUpdatedAt.forEach((k, v) {
      if (k.startsWith('$songKey#') && v > latest) latest = v;
    });
    return latest;
  }

  /// S5 共现传播：相邻两曲间隔 ≤ `sessionGapMin` 视为同一会话，互相传播强标签。
  void _rebuildCooccurrence(
      List<PlayStatV2> entries, RecommendationConfig cfg) {
    _cooccurIndex.clear();
    if (entries.length < 2) return;
    final sorted = List<PlayStatV2>.from(entries)
      ..sort((a, b) => a.lastPlayedAt.compareTo(b.lastPlayedAt));
    final gapMs = cfg.sessionGapMin * 60 * 1000;

    var session = <PlayStatV2>[sorted.first];
    for (var i = 1; i < sorted.length; i++) {
      if (sorted[i].lastPlayedAt - sorted[i - 1].lastPlayedAt <= gapMs) {
        session.add(sorted[i]);
      } else {
        _propagateSession(session, cfg);
        session = <PlayStatV2>[sorted[i]];
      }
    }
    _propagateSession(session, cfg);
  }

  static const int _maxSessionSize = 50;

  /// 在一个会话内，把「其他曲目已有的强标签」以 S5 弱置信度传播给本曲。
  void _propagateSession(List<PlayStatV2> session, RecommendationConfig cfg) {
    if (session.length < 2) return;
    final limited = session.length > _maxSessionSize
        ? session.sublist(0, _maxSessionSize)
        : session;

    final tagsOf = <String, Set<String>>{};
    for (final e in limited) {
      final key = songKeyOf(e.song);
      final set = <String>{};
      _obsIndex[key]?.forEach((tag, conf) {
        if (conf >= cfg.tagConfMin) set.add(tag);
      });
      tagsOf[key] = set;
    }

    for (final e in limited) {
      final key = songKeyOf(e.song);
      final others = <String>{};
      for (final o in limited) {
        if (identical(o, e)) continue;
        others.addAll(tagsOf[songKeyOf(o.song)] ?? const <String>{});
      }
      for (final tag in others) {
        if (tagsOf[key]!.contains(tag)) continue; // 已有更强来源，跳过
        final prev = _cooccurIndex.putIfAbsent(key, () => <String, double>{})[tag];
        final next = prev == null
            ? confCooccurrence
            : 1 - (1 - prev) * (1 - confCooccurrence);
        _cooccurIndex[key]![tag] = next.clamp(0.0, 1.0);
      }
    }
  }

  /// S4 艺人聚合：`艺人 → {tag → 占比}`（基于 S1/S2/S3 已标曲目的标签分布）。
  void _rebuildArtistIndex(
      List<PlayStatV2> entries, RecommendationConfig cfg) {
    _artistIndex.clear();
    final sums = <String, Map<String, double>>{};
    final totals = <String, double>{};

    for (final e in entries) {
      final artist =
          e.artistKey.isNotEmpty ? e.artistKey : normalizeArtist(e.song.artist);
      if (artist.isEmpty) continue;
      final tags = _obsIndex[songKeyOf(e.song)];
      if (tags == null) continue;
      tags.forEach((tag, conf) {
        if (conf < cfg.tagConfMin) return;
        sums.putIfAbsent(artist, () => <String, double>{})[tag] =
            (sums[artist]![tag] ?? 0) + conf;
        totals[artist] = (totals[artist] ?? 0) + conf;
      });
    }

    sums.forEach((artist, tagSums) {
      final total = totals[artist] ?? 0;
      if (total <= 0) return;
      _artistIndex[artist] = <String, double>{
        for (final e in tagSums.entries) e.key: e.value / total,
      };
    });

    if (_artistIndex.length > maxArtists) {
      final keys = _artistIndex.keys.toList()..sort();
      for (final k in keys.take(_artistIndex.length - maxArtists)) {
        _artistIndex.remove(k);
      }
    }
  }

  static String _matchKey(String artist, String name) =>
      '${normalizeArtist(artist)}\u0000${name.trim()}';
}

/// 曲风关键词字典（本地、可离线；不含任何外部依赖）。
///
/// 键 = 规范化曲风标签；值 = 命中该标签的关键词（大小写不敏感子串匹配）。
const Map<String, List<String>> kGenreDictionary = <String, List<String>>{
  '中国风': <String>['中国风', '古风', '国风', 'chinese style'],
  '流行': <String>['流行', 'pop', 'hit'],
  '摇滚': <String>['摇滚', 'rock'],
  '民谣': <String>['民谣', 'folk'],
  '电子': <String>['电子', '电音', 'edm', 'house', 'techno', 'trance', 'dubstep'],
  '说唱': <String>['说唱', '嘻哈', 'rap', 'hip-hop', 'hiphop'],
  '爵士': <String>['爵士', 'jazz'],
  '古典': <String>['古典', 'classical', '交响'],
  '纯音乐': <String>['纯音乐', '器乐', 'instrumental', 'new age', '新世纪'],
  '二次元': <String>['二次元', '动漫', 'anime', 'acg'],
  '粤语': <String>['粤语', 'cantopop'],
  '日语': <String>['日语', '日系', 'j-pop', 'jpop'],
  '韩语': <String>['韩语', '韩系', 'k-pop', 'kpop'],
  '欧美': <String>['欧美', '英文', 'western'],
  '轻音乐': <String>['轻音乐', '放松', 'light music'],
  'R&B': <String>['r&b', 'rnb', '节奏布鲁斯'],
  '金属': <String>['金属', 'metal'],
  '朋克': <String>['朋克', 'punk'],
  '乡村': <String>['乡村', 'country'],
  '蓝调': <String>['蓝调', 'blues'],
  '伤感': <String>['伤感', 'emo', '忧伤', '失恋'],
  '怀旧': <String>['怀旧', '老歌', '经典', '回忆'],
};

/// 从任意文本中提取曲风标签（纯函数，大小写不敏感）。
///
/// 无命中返回空列表（优雅降级的关键：允许「推断不出」）。
List<String> extractGenres(String text) {
  final t = text.trim().toLowerCase();
  if (t.isEmpty) return const <String>[];
  final result = <String>[];
  kGenreDictionary.forEach((genre, keywords) {
    for (final kw in keywords) {
      if (kw.isNotEmpty && t.contains(kw)) {
        result.add(genre);
        break;
      }
    }
  });
  return result;
}

double _asDouble(Object? v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  return double.tryParse(v?.toString() ?? '') ?? 0.0;
}

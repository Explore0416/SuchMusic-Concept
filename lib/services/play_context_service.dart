/// 播放来源上下文服务（单例）。
///
/// 依据设计文档 §3.3 / §4.3：记录「当前播放的曲目来自哪个歌单 / 榜单 / 分类 /
/// 搜索」，供 [GenreMetadataService] 推断曲风标签（S1/S3）使用。
///
/// ── 数据边界 ─────────────────────────────────────────────────
/// 本服务仅在内存中**暂存**来源上下文（歌单名 / 搜索词），随下一次
/// [consume] 被清空；不落盘、不上传、不参与任何网络请求。派生出的曲风标签
/// 随播放历史一起**仅存本机**。
///
/// ── 优雅降级 ─────────────────────────────────────────────────
/// 任意入口漏调 [setSource] 只会「少一个标签」，不会报错、不影响主流程。
library;

/// 播放来源类型（用于统计与调试；不影响打分，标签来自 [PlayContextService.lastSourceTags]）。
enum PlaySourceKind {
  unknown,
  home,
  search,
  playlist,
  rank,
  fm,
  daily,
  local,
  recommendation,
}

/// 一次性消费的上下文快照。
class PlayContextSnapshot {
  const PlayContextSnapshot({
    required this.kind,
    required this.tags,
    required this.keyword,
  });

  /// 来源类型。
  final PlaySourceKind kind;

  /// 来源标签文本（如歌单名，用于 S1 曲风关键词匹配）。
  final List<String> tags;

  /// 搜索关键词（用于 S3）。
  final String? keyword;

  /// 空快照。
  static const PlayContextSnapshot empty = PlayContextSnapshot(
    kind: PlaySourceKind.unknown,
    tags: <String>[],
    keyword: null,
  );
}

/// 播放来源上下文（单例，纯内存）。
class PlayContextService {
  static final PlayContextService _instance = PlayContextService._internal();
  factory PlayContextService() => _instance;
  PlayContextService._internal();

  PlaySourceKind _kind = PlaySourceKind.unknown;
  final List<String> _tags = <String>[];
  String? _keyword;

  /// 最近一次来源类型。
  PlaySourceKind get lastSourceKind => _kind;

  /// 最近一次来源标签。
  List<String> get lastSourceTags => List<String>.unmodifiable(_tags);

  /// 最近一次搜索关键词。
  String? get lastSearchKeyword => _keyword;

  /// 设置来源上下文（在 `playAndAdd` / `playSongs` **之前**调用）。
  ///
  /// [tags] 传歌单名 / 分类名等可用于曲风关键词匹配的文本；
  /// [keyword] 传搜索词。任一为空表示该信号缺失（优雅降级）。
  void setSource({
    PlaySourceKind kind = PlaySourceKind.unknown,
    List<String>? tags,
    String? keyword,
  }) {
    _kind = kind;
    _tags
      ..clear()
      ..addAll((tags ?? const <String>[])
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty));
    final k = keyword?.trim();
    _keyword = (k == null || k.isEmpty) ? null : k;
  }

  /// 消费并重置上下文（每播一首消费一次）。
  PlayContextSnapshot consume() {
    final snapshot = PlayContextSnapshot(
      kind: _kind,
      tags: List<String>.unmodifiable(_tags),
      keyword: _keyword,
    );
    _kind = PlaySourceKind.unknown;
    _tags.clear();
    _keyword = null;
    return snapshot;
  }

  /// 仅读取，不重置。
  PlayContextSnapshot peek() => PlayContextSnapshot(
        kind: _kind,
        tags: List<String>.unmodifiable(_tags),
        keyword: _keyword,
      );

  /// 清空上下文（清除本地推荐数据时调用）。
  void clear() {
    _kind = PlaySourceKind.unknown;
    _tags.clear();
    _keyword = null;
  }
}

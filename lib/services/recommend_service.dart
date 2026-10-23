import '../models/song_model.dart';
import 'play_history_service.dart';
import 'sources/source_manager.dart';

/// 「猜你想听」的候选构建。
///
/// 历史缺陷：候选**全部来自本机播放历史**，等于在听过的歌里重排，
/// 听久了必然「翻来覆去就那几首」。这里在本地偏好的基础上，
/// 从当前音源取个性化新歌（每日推荐 / 私人 FM），与本地结果交错混排：
///
/// - 本地占 2/3：保证「推的确实是你会听的」；
/// - 新歌占 1/3：保证「能发现没听过的」，其中熟悉艺人优先、陌生艺人最多 2 首；
/// - 已在本地的歌不会重复出现在新歌位。
///
/// 取不到在线候选（未登录 / 接口失败 / 本地音乐模式）时**原样返回本地结果**，
/// 不降级成空列表，也不抛异常。
class RecommendService {
  RecommendService._();

  static final RecommendService instance = RecommendService._();

  /// 本地 : 新歌 的比例（2:1）。
  static const int _localRatio = 2;

  /// 陌生艺人最多占几首，避免整屏都是没听过的。
  static const int _maxExplore = 2;

  /// 在线候选缓存（5 分钟），避免每次进首页都打接口。
  static const Duration _cacheTtl = Duration(minutes: 5);
  List<SongModel>? _cache;
  DateTime? _cachedAt;

  /// 构建推荐列表。
  Future<List<SongModel>> smartPicks({int limit = 12}) async {
    if (limit <= 0) return const <SongModel>[];
    final local = PlayHistoryService().suggest(limit: limit);

    final cached = _cache;
    final at = _cachedAt;
    if (cached == null || at == null || DateTime.now().difference(at) > _cacheTtl) {
      _cache = await _fetchFresh();
      _cachedAt = DateTime.now();
    }
    final fresh = _cache ?? const <SongModel>[];

    return mixPicks(
      local: local,
      fresh: fresh,
      limit: limit,
      localRatio: _localRatio,
      maxExplore: _maxExplore,
    );
  }

  /// 纯函数：把本地偏好与在线新歌按 2:1 混排（便于单测，不触网、不读 IO）。
  ///
  /// - 已在本地的歌不会重复出现在新歌位（按 id 与「歌名|歌手」双重去重）；
  /// - 熟悉艺人优先，陌生艺人最多 [maxExplore] 首；
  /// - 每 [localRatio] 首本地插 1 首新歌，避免新歌全堆在末尾。
  static List<SongModel> mixPicks({
    required List<SongModel> local,
    required List<SongModel> fresh,
    int limit = 12,
    int localRatio = 2,
    int maxExplore = 2,
  }) {
    if (limit <= 0) return const <SongModel>[];
    if (fresh.isEmpty) return local.take(limit).toList(growable: false);
    if (local.isEmpty) return fresh.take(limit).toList(growable: false);

    final seenIds = local.map((s) => s.id).toSet();
    final seenNames = local.map((s) => _nameKey(s)).toSet();
    final knownArtists = local.map((s) => s.artist).toSet();

    final unique = <SongModel>[];
    for (final s in fresh) {
      if (seenIds.contains(s.id)) continue;
      if (seenNames.contains(_nameKey(s))) continue;
      unique.add(s);
    }
    if (unique.isEmpty) return local.take(limit).toList(growable: false);

    final familiar =
        unique.where((s) => knownArtists.contains(s.artist)).toList();
    final explore =
        unique.where((s) => !knownArtists.contains(s.artist)).toList();

    final localQuota = (limit * localRatio / (localRatio + 1)).ceil();
    final pickedLocal = local.take(localQuota).toList();
    final remain = limit - pickedLocal.length;

    final pickedFresh = <SongModel>[];
    final familiarQuota = remain - maxExplore > 0 ? remain - maxExplore : 0;
    pickedFresh.addAll(familiar.take(familiarQuota));
    pickedFresh.addAll(explore.take(maxExplore));
    // 名额未满时只用**熟悉艺人**补齐：陌生艺人永远不超过 maxExplore，
    // 宁可少推几首，也不把整屏换成没听过的歌手。
    final pickedIds = pickedFresh.map((s) => s.id).toSet();
    for (final s in familiar) {
      if (pickedFresh.length >= remain) break;
      if (pickedIds.add(s.id)) pickedFresh.add(s);
    }

    final out = <SongModel>[];
    var i = 0, j = 0;
    while (out.length < limit &&
        (i < pickedLocal.length || j < pickedFresh.length)) {
      for (var k = 0; k < localRatio && i < pickedLocal.length; k++) {
        out.add(pickedLocal[i++]);
      }
      if (j < pickedFresh.length) out.add(pickedFresh[j++]);
    }
    // 仍不满（新歌不够）时用本地剩余补齐
    if (out.length < limit) {
      final used = out.map((s) => s.id).toSet();
      for (final s in local) {
        if (out.length >= limit) break;
        if (used.add(s.id)) out.add(s);
      }
    }
    return out;
  }

  /// 清空缓存（切换音源 / 登录状态变化后调用）。
  void invalidate() {
    _cache = null;
    _cachedAt = null;
  }

  static String _nameKey(SongModel s) => '${s.name}|${s.artist}';

  Future<List<SongModel>> _fetchFresh() async {
    try {
      final src = SourceManager().source;
      var list = await src.dailyRecommend();
      if (list.isEmpty) list = await src.personalFm();
      return list;
    } catch (_) {
      return const <SongModel>[];
    }
  }
}

import '../../models/song_model.dart';

/// 音源抽象（ARCH §4.4）。
///
/// - `NeteaseSource`：包装现有 `MusicApiService`，行为与改造前逐字节等价。
/// - `KugouSource`：新增酷狗概念版实现。
abstract class MusicSource {
  /// 'netease' / 'kugou'
  String get id;

  /// '网易云' / '酷狗概念版'
  String get displayName;

  SongSource get kind;

  /// 是否需要凭证（网易云 false，酷狗 true）
  bool get needsCredentials;

  /// 是否已配置（酷狗需 token + userid）
  bool get isConfigured;

  Future<List<SongModel>> search(String keyword, {int limit = 30});

  Future<List<String>> hotSearch();

  /// 取播放地址。
  ///
  /// [strict] 为 true 时启用**严格模式**：仅在 API 真正返回有效 url 时才返回，
  /// 拿不到有效地址一律返回 `null`（不使用兜底外链）。用于回退分支判定真实成功与否。
  /// 默认 `false`：保留既有「兜底外链」行为，不破坏主音源的可播放能力。
  Future<String?> getSongUrl(SongModel song, {bool strict = false});

  Future<String?> getLyrics(SongModel song);

  Future<SongModel?> getSongDetail(SongModel song);

  Future<List<PlaylistModel>> topList();

  /// 可选能力：按「歌名 + 歌手」在本音源搜索出**对端歌曲**（跨源回退用）。
  ///
  /// 默认不实现（返回 `null`），由支持搜索匹配的音源覆写。用于 [SourceManager.withFallback]
  /// 在回退前把源歌解析为本音源可用的对应歌曲，避免用对端 id 请求本音源。
  Future<SongModel?> resolveCounterpart(SongModel song) async => null;

  /// 仅网易云实现；其它音源返回空
  Future<List<SongModel>> dailyRecommend() => Future.value(const []);
}

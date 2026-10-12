import 'package:flutter/foundation.dart';

import '../../models/song_model.dart';
import '../music_api_service.dart';
import 'music_source.dart';
import 'song_matcher.dart';

/// 网易云音源：包装现有 [MusicApiService]。
///
/// 行为与改造前**逐字节等价**，只是补上「不外抛、失败返回空」的统一约定。
class NeteaseSource implements MusicSource {
  NeteaseSource._internal();

  static final NeteaseSource _instance = NeteaseSource._internal();

  factory NeteaseSource() => _instance;

  final MusicApiService _api = MusicApiService();

  @override
  String get id => 'netease';

  @override
  String get displayName => '网易云';

  @override
  SongSource get kind => SongSource.netease;

  @override
  bool get needsCredentials => false;

  @override
  bool get isConfigured => true;

  @override
  Future<List<SongModel>> search(String keyword, {int limit = 30}) async {
    try {
      return await _api.search(keyword, limit: limit);
    } catch (e) {
      debugPrint('❌ 网易云搜索失败: $e');
      return [];
    }
  }

  @override
  Future<List<String>> hotSearch() => _api.getHotSearchKeys();

  @override
  Future<List<String>> searchSuggest(String keyword) async {
    try {
      return await _api.searchSuggest(keyword);
    } catch (e) {
      debugPrint('❌ 网易云联想失败: $e');
      return const [];
    }
  }

  @override
  Future<String?> getSongUrl(SongModel song, {bool strict = false}) =>
      _api.getSongUrl(song.id, strict: strict);

  @override
  Future<String?> getLyrics(SongModel song) => _api.getLyrics(song.id);

  @override
  Future<SongModel?> getSongDetail(SongModel song) =>
      _api.getSongDetail(song.id);

  @override
  Future<List<PlaylistModel>> topList() => _api.topList();

  /// 网易云歌单/榜单歌曲（榜单与歌单同一接口）。
  @override
  Future<List<SongModel>> rankSongs(String playlistId, {int limit = 50}) async {
    try {
      return await _api.playlistDetail(playlistId);
    } catch (e) {
      debugPrint('⚠️ 网易云歌单歌曲失败: $e');
      return const [];
    }
  }

  /// 按「歌名 + 歌手」在网易云搜索匹配出对端歌曲（跨源回退用）。
  ///
  /// 搜索关键字为「歌名 歌手」；取最匹配结果（优先歌名完全一致且歌手有交集）。
  /// 匹配不到返回 `null`。任何异常静默返回 `null`（服务层不外抛）。
  @override
  Future<SongModel?> resolveCounterpart(SongModel song) async {
    final name = song.name.trim();
    if (name.isEmpty) return null;
    final artist = song.artist.trim();
    final keyword = artist.isEmpty ? name : '$name $artist';
    try {
      final candidates = await _api.search(keyword, limit: 30);
      if (candidates.isEmpty) return null;
      final best = pickBestMatch(song, candidates);
      if (best == null) {
        debugPrint('⚠️ 网易云未匹配到对端歌曲: $keyword');
        return null;
      }
      debugPrint('🔎 网易云匹配到对端歌曲: 《${best.name}》- ${best.artist}');
      return best.copyWith(source: SongSource.netease);
    } catch (e) {
      debugPrint('⚠️ 网易云匹配对端歌曲失败: $e');
      return null;
    }
  }

  @override
  Future<List<SongModel>> dailyRecommend() async {
    try {
      return await _api.getDailyRecommendSongs();
    } catch (e) {
      debugPrint('❌ 网易云每日推荐失败: $e');
      return [];
    }
  }

  @override
  Future<List<SongModel>> personalFm() async {
    try {
      return await _api.userRadio();
    } catch (e) {
      debugPrint('❌ 网易云私人FM失败: $e');
      return [];
    }
  }

  @override
  Future<List<PlaylistModel>> topPlaylist({int limit = 30}) async {
    try {
      return await _api.topList();
    } catch (e) {
      debugPrint('❌ 网易云推荐歌单失败: $e');
      return [];
    }
  }
}

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/song_model.dart';
import '../kugou_credential_service.dart';
import 'kugou_config.dart';
import 'kugou_sign.dart';
import 'music_source.dart';
import 'song_matcher.dart';

/// 酷狗概念版音源实现（ARCH §4.6）。
///
/// - 搜索：优先免签名 `mobilecdn` 兜底，失败再走需签名的 `complexsearch`。
/// - 播放：`gateway/v3/url`，请求头 `x-router: tracker.kugou.com`。
/// - 歌词：`krcs` 取 id/accesskey → `lyrics/download` 取 base64 LRC（不解 KRC）。
/// - 任何失败一律返回空 / null + 日志，交由 [SourceManager] 回退网易云。
class KugouSource implements MusicSource {
  KugouSource._internal();

  static final KugouSource _instance = KugouSource._internal();

  factory KugouSource() => _instance;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  /// 搜索 / 歌词请求的取消令牌（竞态保护：新请求先取消旧请求）
  CancelToken? _searchCancel;

  // 设备标识（进程内固定，避免风控）
  static final String _mid = _randomHex(32);
  static final String _dfid = _randomHex(24);
  static final String _uuid = _randomHex(32).toUpperCase();

  static String _randomHex(int len) {
    final r = Random();
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }

  @override
  String get id => 'kugou';

  @override
  String get displayName => '酷狗概念版';

  @override
  SongSource get kind => SongSource.kugou;

  @override
  bool get needsCredentials => true;

  @override
  bool get isConfigured => KugouCredentialService.instance.hasCredentials;

  // ── 搜索 ──────────────────────────────────────────────────

  @override
  Future<List<SongModel>> search(String keyword, {int limit = 30}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];

    // 取消上一次搜索，避免旧结果覆盖新搜索
    _searchCancel?.cancel('new-search');
    final token = CancelToken();
    _searchCancel = token;

    // 1) 免签名 mobilecdn（优先，稳定）
    final primary = await _searchMobileCdn(kw, limit, token);
    if (primary.isNotEmpty) return primary;

    // 2) 需签名 complexsearch（兜底）
    return _searchComplex(kw, limit, token);
  }

  Future<List<SongModel>> _searchMobileCdn(
      String kw, int limit, CancelToken token) async {
    try {
      final res = await _dio.get(
        '${KugouConfig.mobileCdnHost}/api/v3/search/song',
        queryParameters: {
          'format': 'json',
          'keyword': kw,
          'page': 1,
          'pagesize': limit,
          'showtype': 1,
        },
        cancelToken: token,
        options: Options(headers: {'User-Agent': KugouConfig.userAgent}),
      );
      final info = _extractList(res.data, ['data', 'info']);
      return _mapSongs(info);
    } catch (e) {
      debugPrint('⚠️ 酷狗搜索(mobilecdn)失败: $e');
      return [];
    }
  }

  Future<List<SongModel>> _searchComplex(
      String kw, int limit, CancelToken token) async {
    try {
      // 按概念版 Web 端签名所需静态参数集合补全（缺失会导致签名校验 100% 被拒）
      final params = <String, dynamic>{
        'appid': KugouConfig.appid, // 概念版 1005（Web 端亦可用 1014）
        'srcappid': KugouConfig.srcappid, // 2919
        'clientver': KugouConfig.clientver,
        'clienttime': DateTime.now().millisecondsSinceEpoch,
        'dfid': _dfid,
        'mid': _mid,
        'uuid': _uuid,
        'keyword': kw,
        'page': 1,
        'pagesize': limit,
        'bitrate': 0,
        'isfuzzy': 0,
        'inputtype': 0,
        'platform': 'WebFilter',
        'userid': 0,
        'iscorrection': 1,
        'privilege_filter': 0,
        'filter': 10,
        'token': '',
      };
      final signature = KugouSign.signature(params);
      final res = await _dio.get(
        '${KugouConfig.complexSearchHost}/v2/search/song',
        queryParameters: {...params, 'signature': signature},
        cancelToken: token,
        options: Options(headers: {
          'User-Agent': KugouConfig.userAgent,
          'x-router': 'complexsearch.kugou.com',
        }),
      );
      final list = _extractList(res.data, ['data', 'lists']);
      return _mapSongs(list);
    } catch (e) {
      debugPrint('⚠️ 酷狗搜索(complexsearch)失败: $e');
      return [];
    }
  }

  @override
  Future<List<String>> hotSearch() async {
    try {
      final res = await _dio.get(
        '${KugouConfig.mobileCdnHost}/api/v3/search/hot',
        queryParameters: {'format': 'json', 'plat': 0, 'count': 30},
        options: Options(headers: {'User-Agent': KugouConfig.userAgent}),
      );
      final list = _extractList(res.data, ['data', 'info']);
      return list
          .map((e) => e['keyword']?.toString() ?? '')
          .where((k) => k.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('⚠️ 酷狗热搜获取失败: $e');
      return [];
    }
  }

  // ── 播放地址 ──────────────────────────────────────────────

  @override
  Future<String?> getSongUrl(SongModel song, {bool strict = false}) async {
    final hash = song.hash;
    if (hash == null || hash.isEmpty) {
      debugPrint('❌ 酷狗歌曲缺少 hash，无法取播放地址');
      return null;
    }
    final cred = KugouCredentialService.instance;
    final userId = cred.userId ?? '0';
    final userToken = cred.token ?? '';
    final hashLower = hash.toLowerCase();

    try {
      final params = <String, dynamic>{
        'album_id': (song.albumId?.isEmpty ?? true) ? '0' : song.albumId,
        'album_audio_id':
            (song.albumAudioId?.isEmpty ?? true) ? '0' : song.albumAudioId,
        'appid': KugouConfig.appid,
        'area_code': 1,
        'behavior': 'play',
        'clientver': KugouConfig.clientver,
        'cmd': 26,
        'dfid': _dfid,
        'hash': hashLower,
        'mid': _mid,
        'mtype': 2,
        'userid': userId,
        'uuid': _uuid,
        'vipType': KugouConfig.vipType,
      };
      if (userToken.isNotEmpty) params['token'] = userToken;
      params['key'] =
          KugouSign.playKey(hash: hashLower, mid: _mid, userId: userId);
      final signature = KugouSign.signature(params);

      final res = await _dio.get(
        '${KugouConfig.gatewayHost}/v3/url',
        queryParameters: {...params, 'signature': signature},
        options: Options(headers: {
          'User-Agent': KugouConfig.userAgent,
          'x-router': 'tracker.kugou.com',
        }),
      );
      final url = _extractPlayUrl(res.data);
      if (url == null || url.isEmpty) {
        debugPrint('⚠️ 酷狗取播放地址为空（可能需 VIP 或凭证失效）');
        return null;
      }
      debugPrint('🎵 酷狗 songUrl 返回: $url');
      return url;
    } catch (e) {
      debugPrint('❌ 酷狗取播放地址异常: $e');
      return null;
    }
  }

  // ── 歌词 ──────────────────────────────────────────────────

  @override
  Future<String?> getLyrics(SongModel song) async {
    final hash = song.hash;
    if (hash == null || hash.isEmpty) return null;
    try {
      final searchRes = await _dio.get(
        '${KugouConfig.krcsHost}/search',
        queryParameters: {
          'ver': 1,
          'man': 'yes',
          'client': 'mobi',
          'hash': hash.toLowerCase(),
        },
        options: Options(headers: {'User-Agent': KugouConfig.userAgent}),
      );

      final candidates = _extractList(searchRes.data, ['candidates']);
      if (candidates.isEmpty) return null;
      final first = candidates.first;
      final lyricId = first['id']?.toString();
      final accessKey = first['accesskey']?.toString();
      if (lyricId == null || accessKey == null) return null;

      final dlRes = await _dio.get(
        '${KugouConfig.lyricsHost}/download',
        queryParameters: {
          'ver': 1,
          'client': 'pc',
          'id': lyricId,
          'accesskey': accessKey,
          'fmt': 'lrc',
          'charset': 'utf8',
        },
        options: Options(headers: {'User-Agent': KugouConfig.userAgent}),
      );

      final data = dlRes.data;
      if (data is! Map) return null;
      final status = data['status'];
      final content = data['content'];
      if (content is! String || content.isEmpty) return null;
      if (status != null && status.toString() != '200') {
        debugPrint('⚠️ 酷狗歌词接口 status=$status');
        return null;
      }

      // 明文 LRC 为 base64 编码；解码失败降级为无歌词（不阻断播放）
      try {
        return utf8.decode(base64.decode(content));
      } catch (e) {
        debugPrint('⚠️ 酷狗歌词解码失败（降级为无歌词）: $e');
        return null;
      }
    } catch (e) {
      debugPrint('❌ 酷狗歌词获取失败: $e');
      return null;
    }
  }

  @override
  Future<SongModel?> getSongDetail(SongModel song) async => song;

  /// 按「歌名 + 歌手」在酷狗搜索匹配出对端歌曲（供网易云 → 酷狗方向回退复用）。
  ///
  /// 取最匹配结果（优先歌名完全一致且歌手有交集）；匹配不到返回 `null`。
  @override
  Future<SongModel?> resolveCounterpart(SongModel song) async {
    final name = song.name.trim();
    if (name.isEmpty) return null;
    final artist = song.artist.trim();
    final keyword = artist.isEmpty ? name : '$name $artist';
    try {
      final candidates = await search(keyword, limit: 30);
      if (candidates.isEmpty) return null;
      final best = pickBestMatch(song, candidates);
      if (best == null) {
        debugPrint('⚠️ 酷狗未匹配到对端歌曲: $keyword');
        return null;
      }
      debugPrint('🔎 酷狗匹配到对端歌曲: 《${best.name}》- ${best.artist}');
      return best.copyWith(source: SongSource.kugou);
    } catch (e) {
      debugPrint('⚠️ 酷狗匹配对端歌曲失败: $e');
      return null;
    }
  }

  @override
  Future<List<PlaylistModel>> topList() async => const [];

  @override
  Future<List<SongModel>> dailyRecommend() async => const [];

  // ── 解析工具 ──────────────────────────────────────────────

  /// 从嵌套响应中取列表（防御性：任一层缺失返回空）
  List<Map<String, dynamic>> _extractList(dynamic data, List<String> path) {
    dynamic cur = data;
    for (final key in path) {
      if (cur is Map && cur[key] != null) {
        cur = cur[key];
      } else {
        return const [];
      }
    }
    if (cur is! List) return const [];
    return cur.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  List<SongModel> _mapSongs(List<Map<String, dynamic>> raw) {
    return raw
        .map(SongModel.fromKugouJson)
        .where((s) => s.name.isNotEmpty)
        .toList();
  }

  String? _extractPlayUrl(dynamic data) {
    if (data is! Map) return null;
    final d = data['data'];
    if (d is List && d.isNotEmpty) {
      final first = d.first;
      if (first is Map) {
        final url = first['url'];
        if (url is String && url.isNotEmpty) return url;
        if (url is List && url.isNotEmpty) return url.first?.toString();
        final playUrl = first['play_url'];
        if (playUrl is String && playUrl.isNotEmpty) return playUrl;
        final backup = first['backup_url'];
        if (backup is List && backup.isNotEmpty) return backup.first?.toString();
      }
    }
    return null;
  }
}

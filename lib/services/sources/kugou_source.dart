import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/song_model.dart';
import '../kugou_credential_service.dart';
import 'kugou_config.dart';
import 'kugou_device.dart';
import 'kugou_device_service.dart';
import 'kugou_sign.dart';
import 'music_source.dart';
import 'song_matcher.dart';

/// 日志安全化：把播放直链裁剪为 `协议://主机/路径前缀`，**丢弃 query 与
/// fragment**。酷狗取源直链的 query 里可能内嵌 `token=` 等凭证参数，
/// 完整打印会泄漏到日志；此处仅保留「拿到了 URL」这一可观测性。
///
/// - 合法 URL：输出 `scheme://host` + 最长 40 字符的路径前缀；
/// - 非法/相对 URL：退化为前 24 字符 + 省略号，避免整串泄漏。
@visibleForTesting
String sanitizePlayUrlForLog(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    return url.length <= 24 ? url : '${url.substring(0, 24)}…';
  }
  final path = uri.path.length > 40 ? '${uri.path.substring(0, 40)}…' : uri.path;
  return '${uri.scheme}://${uri.host}$path';
}

/// 解析酷狗搜索联想响应（`searchtip.kugou.com/getSearchTip`）。
///
/// 结构：`{ "data": [ { "RecordDatas": [ { "HintInfo": "东风破 周杰伦" }, ... ] } ] }`。
/// 兼容 `data` 为多段、`HintInfo` 缺失 / 非字符串、整体非 Map 等异常形态，
/// 一律**返回已解析出的合法提示词**（去重、保序、最多 [limit] 条），不抛异常。
@visibleForTesting
List<String> parseKugouSuggest(dynamic data, {int limit = 10}) {
  try {
    final root = data is String ? jsonDecode(data) : data;
    if (root is! Map) return const [];
    final blocks = root['data'];
    if (blocks is! List) return const [];
    final out = <String>[];
    for (final block in blocks) {
      if (block is! Map) continue;
      final records = block['RecordDatas'];
      if (records is! List) continue;
      for (final record in records) {
        if (record is! Map) continue;
        final hint = record['HintInfo'];
        if (hint is String) {
          final trimmed = hint.trim();
          if (trimmed.isNotEmpty && !out.contains(trimmed)) {
            out.add(trimmed);
            if (out.length >= limit) return out;
          }
        }
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// 酷狗音源实现（支持概念版 lite / 原版 standard，ARCH §4.6）。
///
/// - 搜索：**主路径** `complexsearch`（需签名，Web 盐两平台共用）；
/// - 播放：`gateway/v5/url`，请求头 `x-router: trackercdn.kugou.com`；
///   `key` / 签名盐值按 [platform] 取。
/// - 歌词：`krcs` 取 id/accesskey → `lyrics/download` 取 base64 LRC（不解 KRC）。
/// - 任何失败一律返回空 / null + 日志，交由 [SourceManager] 回退网易云。
class KugouSource implements MusicSource {
  KugouSource._internal(this._dio, this.platform);

  static final KugouSource _instanceLite =
      KugouSource._internal(_createDio(), KugouPlatform.lite);
  static final KugouSource _instanceStandard =
      KugouSource._internal(_createDio(), KugouPlatform.standard);

  /// 按平台取共享实例（缺省 = 概念版，兼容既有调用）。
  factory KugouSource({KugouPlatform platform = KugouPlatform.lite}) =>
      platform == KugouPlatform.lite ? _instanceLite : _instanceStandard;

  /// 测试专用：注入自定义 [Dio]（记录请求 / 假应答）。
  @visibleForTesting
  factory KugouSource.withDio(Dio dio,
          {KugouPlatform platform = KugouPlatform.lite}) =>
      KugouSource._internal(dio, platform);

  static Dio _createDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

  final Dio _dio;

  /// 平台变体（概念版 / 原版）。
  final KugouPlatform platform;

  /// 搜索 / 歌词请求的取消令牌（竞态保护：新请求先取消旧请求）。
  CancelToken? _searchCancel;

  @override
  String get id => kind.code;

  @override
  String get displayName => platform.label;

  @override
  SongSource get kind => SongSource.fromKugouPlatform(platform);

  @override
  bool get needsCredentials => true;

  @override
  bool get isConfigured =>
      KugouCredentialService.instance.hasCredentialsFor(platform);

  // ── 搜索 ──────────────────────────────────────────────────

  @override
  Future<List<SongModel>> search(String keyword, {int limit = 30}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return [];

    // 取消上一次搜索，避免旧结果覆盖新搜索
    _searchCancel?.cancel('new-search');
    final token = CancelToken();
    _searchCancel = token;

    // 1) 主路径：需签名 complexsearch（唯一主路径）
    final primary = await _searchComplex(kw, limit, token);
    if (primary.isNotEmpty) return primary;

    // 2) 兜底：免签名 mobilecdn（仅主路径为空时；容忍其失败）
    return _searchMobileCdn(kw, limit, token);
  }

  Future<List<SongModel>> _searchComplex(
      String kw, int limit, CancelToken token) async {
    try {
      // 概念版 Web 端签名所需**完整**参数集（漏参数 → error_code=20006）
      final params = <String, dynamic>{
        'appid': KugouConfig.appidOf(platform), // 按平台取（概念版 3116 / 原版 1005）
        'srcappid': KugouConfig.srcappid, // 2919
        'clientver': KugouConfig.clientverOf(platform),
        'clienttime': DateTime.now().millisecondsSinceEpoch,
        'dfid': KugouDevice.dfidOf(platform),
        'mid': KugouDevice.mid,
        'uuid': KugouDevice.uuid,
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
      // complexsearch 是 **Web 端接口**，必须用 Web 盐值签名（实测：误用
      // Android 盐值会被拒 → error_code=20006 → 搜索恒为空）。
      final signature = KugouSign.webSignature(params);
      final res = await _dio.get(
        '${KugouConfig.complexSearchHost}/v2/search/song',
        queryParameters: {...params, 'signature': signature},
        cancelToken: token,
        options: Options(headers: {
          'User-Agent': KugouConfig.userAgent,
          'x-router': 'complexsearch.kugou.com',
        }),
      );
      final data = res.data;
      if (data is Map) {
        final status = data['status'];
        final errCode = data['error_code'];
        if ((status != null && status.toString() != '1') ||
            (errCode != null && errCode.toString() != '0')) {
          debugPrint('⚠️ 酷狗搜索(complexsearch)异常 status=$status err=$errCode');
        }
      }
      final list = _extractList(data, ['data', 'lists']);
      return _mapSongs(list);
    } catch (e) {
      debugPrint('⚠️ 酷狗搜索(complexsearch)失败: $e');
      return [];
    }
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
      debugPrint('⚠️ 酷狗搜索(mobilecdn)兜底失败: $e');
      return [];
    }
  }

  @override
  Future<List<String>> hotSearch() async {
    // ⚠️ 旧接口 `mobilecdn.kugou.com/api/v3/search/hot` 已失效（实测域名
    // 证书不匹配 / 不可达）。此处**主动返回空列表**，由上层 UI
    // （search_page）回退到本地默认热词 / 空态提示，避免界面卡在无结果且无提示。
    debugPrint('ℹ️ 酷狗热搜接口已失效，返回空列表由上层回退');
    return const [];
  }

  /// 搜索联想：酷狗公开提示接口（免签名、GET），概念版 / 原版共用。
  @override
  Future<List<String>> searchSuggest(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const [];
    try {
      final res = await _dio.get(
        '${KugouConfig.searchTipHost}/getSearchTip',
        queryParameters: {
          'MusicTipCount': 10,
          'keyword': kw,
          'KugouTipCount': 3,
          'fmt': 'json',
        },
      );
      final list = parseKugouSuggest(res.data);
      return list;
    } catch (e) {
      debugPrint('⚠️ 酷狗联想失败: $e');
      return const [];
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

    // 关键：必须先完成设备注册（否则服务端风控 → 20028 → 取不到直链）
    final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
    if (dfid == null || dfid.isEmpty) {
      debugPrint('⚠️ 酷狗设备未注册成功，无法取播放直链');
      return null;
    }

    try {
      final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final albumId = int.tryParse(song.albumId ?? '') ?? 0;
      final albumAudioId = int.tryParse(song.albumAudioId ?? '') ?? 0;

      // 对齐 KuGouMusicApi module/song_url.js（概念版 lite 取值）
      final params = <String, dynamic>{
        'album_id': albumId,
        'area_code': 1,
        'hash': hashLower,
        'ssa_flag': 'is_fromtrack',
        'version': KugouConfig.playVersion,
        'page_id': KugouConfig.playPageIdOf(platform),
        'quality': 128,
        'album_audio_id': albumAudioId,
        'behavior': 'play',
        'pid': KugouConfig.playPidOf(platform),
        'cmd': KugouConfig.playCmd,
        'pidversion': KugouConfig.playPidVersion,
        'IsFreePart': 0,
        'ppage_id': KugouConfig.playPpageIdOf(platform),
        'cdnBackup': 1,
        'module': '',
        'clientver': KugouConfig.playVersion,
        // 默认参数
        'dfid': dfid,
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clienttime': clienttime,
      };
      if (userToken.isNotEmpty) params['token'] = userToken;
      if (userId != '0') params['userid'] = userId;
      // encryptKey：key = md5(hash + 平台key盐 + appid + mid + userid)
      params['key'] = KugouSign.playKey(
        hash: hashLower,
        mid: KugouDevice.mid,
        userId: userId,
        platform: platform,
      );
      // Android 端签名（按平台盐值）
      final signature = KugouSign.androidSignature(params, platform: platform);

      final res = await _dio.get(
        '${KugouConfig.gatewayHost}${KugouConfig.playUrlPath}',
        queryParameters: {...params, 'signature': signature},
        options: Options(headers: {
          'User-Agent': KugouConfig.androidUserAgent,
          'x-router': KugouConfig.playUrlRouter,
          ...KugouConfig.androidCommonHeaders,
        }),
      );
      final url = _extractPlayUrl(res.data);
      if (url == null || url.isEmpty) {
        final body = res.data;
        final err = body is Map ? (body['error_code'] ?? body['errcode']) : null;
        debugPrint('⚠️ 酷狗取播放地址为空（error_code=$err）');
        debugPrint('🔎 酷狗取链原始响应: ${_truncate(res.data)}');
        return null;
      }
      // 安全：直链 query 可能内嵌 `token=` 等凭证，日志只保留
      // `协议://主机/路径前缀`，绝不输出完整 query（见 sanitizePlayUrlForLog）。
      debugPrint('🎵 酷狗 songUrl 返回: ${sanitizePlayUrlForLog(url)}');
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
      return best.copyWith(source: kind);
    } catch (e) {
      debugPrint('⚠️ 酷狗匹配对端歌曲失败: $e');
      return null;
    }
  }

  // ── 榜单 ──────────────────────────────────────────────────

  @override
  Future<List<PlaylistModel>> topList() async {
    try {
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clientver': KugouConfig.clientverOf(platform),
        'clienttime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'plat': 2,
        'withsong': 1,
        'parentid': 0,
      };
      params['signature'] = KugouSign.androidSignature(params, platform: platform);
      final res = await _dio.get(
        '${KugouConfig.gatewayHost}${KugouConfig.rankListPath}',
        queryParameters: params,
        options: Options(headers: {
          'User-Agent': KugouConfig.androidUserAgent,
          ...KugouConfig.androidCommonHeaders,
        }),
      );
      final list = _extractList(res.data, ['data', 'info']);
      return list
          .map(_mapRank)
          .where((p) => p.name.isNotEmpty && p.id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('⚠️ 酷狗榜单列表失败: $e');
      return const [];
    }
  }

  /// 榜单歌曲（`/openapi/kmr/v2/rank/audio`）。
  @override
  Future<List<SongModel>> rankSongs(String playlistId, {int limit = 50}) async {
    // 歌单（`collection_...` 形式）→ 走歌单歌曲接口；否则按榜单 rankid 处理。
    if (playlistId.startsWith('collection_')) {
      return playlistSongs(playlistId, limit: limit);
    }
    final rankId = int.tryParse(playlistId);
    if (rankId == null) return const [];
    try {
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clientver': KugouConfig.clientverOf(platform),
        'clienttime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
      final body = <String, dynamic>{
        'show_portrait_mv': 1,
        'show_type_total': 1,
        'filter_original_remarks': 1,
        'area_code': 1,
        'pagesize': limit,
        'rank_cid': 0,
        'type': 1,
        'page': 1,
        'rank_id': rankId,
      };
      final bodyStr = jsonEncode(body);
      params['signature'] = KugouSign.androidSignatureWithBody(params, bodyStr, platform: platform);
      final res = await _dio.post(
        '${KugouConfig.gatewayHost}${KugouConfig.rankAudioPath}',
        data: bodyStr,
        queryParameters: params,
        options: Options(
          contentType: 'application/json;charset=utf-8',
          headers: {
            'User-Agent': KugouConfig.androidUserAgent,
            ...KugouConfig.androidCommonHeaders,
            ...KugouConfig.rankAudioHeaders,
          },
        ),
      );
      final list = _extractList(res.data, ['data', 'songlist']);
      return list
          .map(_mapRankSong)
          .where((s) => s.name.isNotEmpty && (s.hash?.isNotEmpty ?? false))
          .toList();
    } catch (e) {
      debugPrint('⚠️ 酷狗榜单歌曲失败: $e');
      return const [];
    }
  }

  // ── 用户歌单 / 歌单导入 ────────────────────────────────────

  /// 从用户输入（歌单链接 / `listid` 查询串 / 直接 `collection_...`）
  /// 解析酷狗 `global_collection_id`；解析不到返回 `null`。
  static String? parsePlaylistId(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    const pattern = r'collection_\d+_\d+_\d+_\d+';
    var m = RegExp(pattern).firstMatch(s);
    if (m != null) return m.group(0);
    // `listid=` / `list_id=` 查询参数
    final li = RegExp(r'[?&]list_?id=([^&#\s]+)').firstMatch(s);
    if (li != null) {
      final v = Uri.decodeComponent(li.group(1)!);
      m = RegExp(pattern).firstMatch(v);
      if (m != null) return m.group(0);
    }
    return null;
  }

  static String? _firstUrl(String input) {
    final m = RegExp(r'https?://[^\s]+').firstMatch(input.trim());
    return m?.group(0);
  }

  /// 解析歌单 ID：优先直接解析；若是分享短链 / 分享页，则请求页面再提取。
  Future<String?> resolvePlaylistId(String input) async {
    final direct = parsePlaylistId(input);
    if (direct != null) return direct;
    final url = _firstUrl(input);
    if (url == null) return null;
    try {
      final res = await _dio.get<String>(
        url,
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          headers: {'User-Agent': KugouConfig.mobileUserAgent},
        ),
      );
      final text = res.data ?? '';
      return parsePlaylistId(text) ??
          parsePlaylistId(res.realUri.toString());
    } catch (e) {
      debugPrint('⚠️ 解析歌单链接失败: $e');
      return null;
    }
  }

  /// 推荐歌单（`/v2/special_recommend`，无需登录）。
  @override
  Future<List<PlaylistModel>> topPlaylist({int limit = 30}) async {
    try {
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final clienttime = DateTime.now().millisecondsSinceEpoch;
      final clienttimeSec = clienttime ~/ 1000;
      final appid = KugouConfig.appidOf(platform);
      final clientver = KugouConfig.clientverOf(platform);
      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': appid,
        'clientver': clientver,
        'clienttime': clienttimeSec,
      };
      // 字段顺序对齐上游（签名含 body，顺序敏感）
      final body = <String, dynamic>{
        'appid': appid,
        'mid': KugouDevice.mid,
        'clientver': clientver,
        'platform': 'android',
        'clienttime': clienttimeSec.toString(),
        'userid': 0,
        'module_id': 1,
        'page': 1,
        'pagesize': limit,
        'key': KugouSign.paramsKey(clienttimeSec, platform: platform),
        'special_recommend': {
          'withtag': 1,
          'withsong': 1,
          'sort': 1,
          'ugc': 1,
          'is_selected': 0,
          'withrecommend': 1,
          'area_code': 1,
          'categoryid': 0,
        },
        'req_multi': 1,
        'retrun_min': 5,
        'return_special_falg': 1,
      };
      final bodyStr = jsonEncode(body);
      params['signature'] = KugouSign.androidSignatureWithBody(params, bodyStr,
          platform: platform);
      final res = await _dio.post(
        '${KugouConfig.gatewayHost}${KugouConfig.topPlaylistPath}',
        data: bodyStr,
        queryParameters: params,
        options: Options(
          contentType: 'application/json;charset=utf-8',
          headers: {
            'User-Agent': KugouConfig.androidUserAgent,
            'x-router': KugouConfig.topPlaylistRouter,
            ...KugouConfig.androidCommonHeaders,
          },
        ),
      );
      final list = _extractList(res.data, ['data', 'special_list']);
      return list
          .map(_mapTopPlaylist)
          .where((p) => p.id.startsWith('collection_') && p.name.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('⚠️ 酷狗推荐歌单失败: $e');
      return const [];
    }
  }

  PlaylistModel _mapTopPlaylist(Map<String, dynamic> j) {
    final gcid = (j['global_collection_id'] ?? '').toString();
    final name = (j['specialname'] ?? j['name'] ?? '').toString();
    var cover = (j['flexible_cover'] ?? j['imgurl'] ?? '').toString();
    cover = cover.replaceAll('{size}', '480');
    final count = int.tryParse((j['songcount'] ?? j['percount'] ?? '').toString());
    return PlaylistModel(
      id: gcid,
      name: name,
      coverUrl: cover.isEmpty ? null : cover,
      trackCount: count,
      creatorName: (j['nickname'] ?? '')?.toString(),
      source: kind,
    );
  }

  /// 歌单歌曲（`/pubsongs/v2/get_other_list_file_nofilt`，**无 x-router**）。
  Future<List<SongModel>> playlistSongs(String globalCollectionId,
      {int limit = 100}) async {
    if (!globalCollectionId.startsWith('collection_')) return const [];
    try {
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clientver': KugouConfig.clientverOf(platform),
        'clienttime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'area_code': 1,
        'begin_idx': 0,
        'plat': 1,
        'type': 1,
        'mode': 1,
        'personal_switch': 1,
        'extend_fields': 'abtags,hot_cmt,popularization',
        'pagesize': limit,
        'global_collection_id': globalCollectionId,
      };
      params['signature'] =
          KugouSign.androidSignature(params, platform: platform);
      final res = await _dio.get(
        '${KugouConfig.gatewayHost}${KugouConfig.playlistSongsPath}',
        queryParameters: params,
        options: Options(headers: {
          'User-Agent': KugouConfig.androidUserAgent,
          ...KugouConfig.androidCommonHeaders,
        }),
      );
      final list = _extractList(res.data, ['data', 'songs']);
      return list
          .map(_mapPlaylistSong)
          .where((s) => s.name.isNotEmpty && (s.hash?.isNotEmpty ?? false))
          .toList();
    } catch (e) {
      debugPrint('⚠️ 酷狗歌单歌曲失败: $e');
      return const [];
    }
  }

  /// 歌单元信息（`/v3/get_list_info`，x-router: pubsongs）。
  Future<PlaylistModel?> playlistInfo(String globalCollectionId) async {
    if (!globalCollectionId.startsWith('collection_')) return null;
    try {
      final cred = KugouCredentialService.instance;
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clientver': KugouConfig.clientverOf(platform),
        'clienttime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
      final body = <String, dynamic>{
        'data': [
          {'global_collection_id': globalCollectionId}
        ],
        'userid': cred.userIdOf(platform) ?? '0',
        'token': cred.tokenOf(platform) ?? '',
      };
      final bodyStr = jsonEncode(body);
      params['signature'] = KugouSign.androidSignatureWithBody(params, bodyStr,
          platform: platform);
      final res = await _dio.post(
        '${KugouConfig.gatewayHost}${KugouConfig.playlistDetailPath}',
        data: bodyStr,
        queryParameters: params,
        options: Options(
          contentType: 'application/json;charset=utf-8',
          headers: {
            'User-Agent': KugouConfig.androidUserAgent,
            'x-router': KugouConfig.playlistDetailRouter,
            ...KugouConfig.androidCommonHeaders,
          },
        ),
      );
      final data = _asMap(res.data)?['data'];
      Map<String, dynamic>? item;
      if (data is Map) {
        // data 形如 {"0": {...}} 或直接为对象
        final first = data.values.firstWhere((v) => v is Map, orElse: () => null);
        item = first is Map ? Map<String, dynamic>.from(first) : null;
      }
      if (item == null) return null;
      return _mapPlaylistInfo(item, globalCollectionId);
    } catch (e) {
      debugPrint('⚠️ 酷狗歌单详情失败: $e');
      return null;
    }
  }

  /// 用户自己的歌单（`/v7/get_all_list`，**需登录态** userid + token）。
  Future<List<PlaylistModel>> userPlaylists({int limit = 100}) async {
    final cred = KugouCredentialService.instance;
    final userId = cred.userIdOf(platform);
    final token = cred.tokenOf(platform);
    if (userId == null || userId.isEmpty || token == null || token.isEmpty) {
      return const [];
    }
    try {
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clientver': KugouConfig.clientverOf(platform),
        'clienttime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'token': token,
        'userid': userId,
        'plat': 1,
      };
      final body = <String, dynamic>{
        'userid': userId,
        'token': token,
        'total_ver': 979,
        'type': 2,
        'page': 1,
        'pagesize': limit,
      };
      final bodyStr = jsonEncode(body);
      params['signature'] = KugouSign.androidSignatureWithBody(params, bodyStr,
          platform: platform);
      final res = await _dio.post(
        '${KugouConfig.gatewayHost}${KugouConfig.userPlaylistPath}',
        data: bodyStr,
        queryParameters: params,
        options: Options(
          contentType: 'application/json;charset=utf-8',
          headers: {
            'User-Agent': KugouConfig.androidUserAgent,
            'x-router': KugouConfig.userPlaylistRouter,
            ...KugouConfig.androidCommonHeaders,
          },
        ),
      );
      final list = _extractUserPlaylists(res.data);
      return list.map(_mapUserPlaylist).toList();
    } catch (e) {
      debugPrint('⚠️ 酷狗用户歌单失败: $e');
      return const [];
    }
  }

  /// 从用户歌单响应中提取列表（结构随版本变化，做多重兜底）。
  List<Map<String, dynamic>> _extractUserPlaylists(dynamic data) {
    final root = _asMap(data);
    if (root == null) return const [];
    final d = _asMap(root['data']);
    for (final key in ['info', 'list', 'lists', 'data']) {
      final v = d?[key] ?? root[key];
      if (v is List) {
        return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      }
    }
    if (d != null) {
      final first = d.values.firstWhere((v) => v is List, orElse: () => null);
      if (first is List) {
        return first
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    }
    return const [];
  }

  PlaylistModel _mapUserPlaylist(Map<String, dynamic> j) {
    final gcid = (j['global_collection_id'] ??
            j['listid'] ??
            j['specialid'] ??
            j['id'] ??
            '')
        .toString();
    final name = (j['name'] ?? j['specialname'] ?? j['listname'] ?? '').toString();
    var cover = (j['pic'] ?? j['cover'] ?? j['imgurl'] ?? j['flexible_cover'] ?? '')
        .toString();
    cover = cover.replaceAll('{size}', '480');
    final count = int.tryParse((j['songcount'] ?? j['count'] ?? '').toString());
    return PlaylistModel(
      id: gcid.startsWith('collection_') ? gcid : 'collection_3_${gcid}_1_0',
      name: name,
      coverUrl: cover.isEmpty ? null : cover,
      trackCount: count,
      source: kind,
    );
  }

  PlaylistModel _mapPlaylistInfo(
      Map<String, dynamic> j, String globalCollectionId) {
    final name = (j['specialname'] ?? j['name'] ?? j['listname'] ?? '').toString();
    var cover =
        (j['flexible_cover'] ?? j['imgurl'] ?? j['pic'] ?? j['cover'] ?? '')
            .toString();
    cover = cover.replaceAll('{size}', '480');
    final count = int.tryParse((j['songcount'] ?? j['count'] ?? '').toString());
    final intro = (j['intro'] ?? '').toString();
    return PlaylistModel(
      id: globalCollectionId,
      name: name.isEmpty ? '酷狗歌单' : name,
      coverUrl: cover.isEmpty ? null : cover,
      description: intro.isEmpty ? null : intro,
      trackCount: count,
      creatorName: (j['nickname'] ?? j['username'] ?? '')?.toString(),
      source: kind,
    );
  }

  /// 歌单歌曲条目 → [SongModel]。
  ///
  /// 该接口 `name` 形如「歌手 - 歌名」，且无独立歌手字段，故按**最后一个**
  /// ` - ` 拆分（歌名可能自带 ` - `）。
  SongModel _mapPlaylistSong(Map<String, dynamic> j) {
    final raw = (j['name'] ?? '').toString();
    var songName = raw;
    var artist = '';
    final idx = raw.lastIndexOf(' - ');
    if (idx > 0) {
      artist = raw.substring(0, idx).trim();
      songName = raw.substring(idx + 3).trim();
    }
    final trans = _asMap(j['trans_param']);
    var cover = (j['cover'] ?? trans?['union_cover'] ?? '').toString();
    cover = cover.replaceAll('{size}', '480');
    final durationMs =
        int.tryParse((j['timelen'] ?? j['time_length'] ?? '').toString()) ?? 0;
    return SongModel(
      id: (j['audio_id'] ?? j['mixsongid'] ?? '').toString(),
      name: songName,
      artist: artist,
      album: (j['album_name'] ?? '').toString(),
      source: kind,
      coverUrl: cover.isEmpty ? null : cover,
      duration: durationMs > 0 ? durationMs : null,
      hash: (j['hash'] ?? '').toString().toLowerCase(),
      albumId: (j['album_id'] ?? '').toString(),
      albumAudioId:
          (j['mixsongid'] ?? j['add_mixsongid'] ?? '').toString(),
    );
  }

  Map<String, dynamic>? _asMap(dynamic v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String && v.isNotEmpty) {
      try {
        final d = jsonDecode(v);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return null;
  }

  /// 榜单条目 → [PlaylistModel]。
  PlaylistModel _mapRank(Map<String, dynamic> j) {
    final id = (j['rankid'] ?? j['rank_id'] ?? j['id'] ?? '').toString();
    final name = (j['rankname'] ?? j['name'] ?? '').toString();
    var cover = (j['imgurl'] ?? j['img_9'] ?? j['bannerurl'] ?? '').toString();
    cover = cover.replaceAll('{size}', '480');
    final playTimes = int.tryParse((j['play_times'] ?? '').toString());
    return PlaylistModel(
      id: id,
      name: name,
      coverUrl: cover.isEmpty ? null : cover,
      description: j['intro']?.toString(),
      playCount: playTimes,
      source: kind,
    );
  }

  /// 榜单歌曲条目 → [SongModel]（hash 取 `audio_info.hash_128`）。
  SongModel _mapRankSong(Map<String, dynamic> j) {
    final audioInfo = j['audio_info'];
    var hash = '';
    var durationMs = 0;
    if (audioInfo is Map) {
      hash = (audioInfo['hash_128'] ?? audioInfo['hash_320'] ?? '').toString();
      durationMs =
          int.tryParse((audioInfo['duration_128'] ?? '').toString()) ?? 0;
    }
    if (hash.isEmpty) {
      final dep = j['deprecated'];
      if (dep is Map) hash = (dep['hash'] ?? '').toString();
    }
    final tp = j['trans_param'];
    var cover = '';
    if (tp is Map) cover = (tp['union_cover'] ?? '').toString();
    cover = cover.replaceAll('{size}', '480');
    final albumInfo = j['album_info'];
    final album =
        albumInfo is Map ? (albumInfo['album_name'] ?? '').toString() : '';
    return SongModel(
      id: (j['audio_id'] ?? '').toString(),
      name: (j['songname'] ?? '').toString(),
      artist: (j['author_name'] ?? '').toString(),
      album: album,
      source: kind,
      coverUrl: cover.isEmpty ? null : cover,
      duration: durationMs > 0 ? durationMs : null,
      hash: hash.isEmpty ? null : hash.toLowerCase(),
      albumId: (j['album_id'] ?? '').toString(),
      albumAudioId: (j['album_audio_id'] ?? '').toString(),
    );
  }

  /// 每日推荐（`/everyday_song_recommend`，无需登录）。
  @override
  Future<List<SongModel>> dailyRecommend() async {
    try {
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clientver': KugouConfig.clientverOf(platform),
        'clienttime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'platform': 'ios',
      };
      params['signature'] = KugouSign.androidSignature(params, platform: platform);
      final res = await _dio.post(
        '${KugouConfig.gatewayHost}${KugouConfig.dailyRecommendPath}',
        queryParameters: params,
        options: Options(headers: {
          'User-Agent': KugouConfig.androidUserAgent,
          'x-router': KugouConfig.dailyRecommendRouter,
          ...KugouConfig.androidCommonHeaders,
        }),
      );
      final list = _extractList(res.data, ['data', 'song_list']);
      return list
          .map(_mapDailySong)
          .where((s) => s.name.isNotEmpty && (s.hash?.isNotEmpty ?? false))
          .toList();
    } catch (e) {
      debugPrint('⚠️ 酷狗每日推荐失败: $e');
      return const [];
    }
  }

  /// 私人 FM（登录态个性化推荐，`/v2/personal_recommend`）。
  ///
  /// ⚠️ 需 token + userid（**按平台**）：未登录或请求失败返回空列表，
  /// 由 `AudioPlayerService` 以「每日推荐随机取曲」兜底。
  @override
  Future<List<SongModel>> personalFm() async {
    final cred = KugouCredentialService.instance;
    final userId = cred.userIdOf(platform);
    final token = cred.tokenOf(platform);
    if (userId == null ||
        userId.isEmpty ||
        token == null ||
        token.isEmpty) {
      debugPrint('ℹ️ 酷狗(${platform.label})未登录，私人FM 交给兜底源');
      return const [];
    }
    try {
      final dfid = await KugouDeviceService.instance.ensureDfid(platform: platform);
      final clienttimeMs = DateTime.now().millisecondsSinceEpoch;
      final appid = KugouConfig.appidOf(platform);
      final clientver = KugouConfig.clientverOf(platform);

      final params = <String, dynamic>{
        'dfid': dfid ?? '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': appid,
        'clientver': clientver,
        'clienttime': clienttimeMs ~/ 1000,
      };

      // 请求体（对齐 KuGouMusicApi module/personal_fm.js）
      final body = <String, dynamic>{
        'appid': appid,
        'clienttime': clienttimeMs,
        'mid': KugouDevice.mid,
        'action': 'play',
        'recommend_source_locked': 0,
        'song_pool_id': 0,
        'callerid': 0,
        'm_type': 1,
        'platform': 'ios',
        'area_code': 1,
        'remain_songcnt': 0,
        'clientver': clientver,
        'is_overplay': 0,
        'mode': 'normal',
        'fakem': 'ca981cfc583a4c37f28d2d49000013c16a0a',
        'key': KugouSign.paramsKey(clienttimeMs, platform: platform),
        'userid': userId,
        'kguid': userId,
        'token': token,
      };
      final bodyStr = jsonEncode(body);
      final signature = KugouSign.androidSignatureWithBody(params, bodyStr,
          platform: platform);

      final res = await _dio.post(
        '${KugouConfig.gatewayHost}${KugouConfig.personalFmPath}',
        data: bodyStr,
        queryParameters: {...params, 'signature': signature},
        options: Options(
          contentType: 'application/json;charset=utf-8',
          headers: {
            'User-Agent': KugouConfig.androidUserAgent,
            'x-router': KugouConfig.personalFmRouter,
            'dfid': dfid ?? '-',
            'mid': KugouDevice.mid,
            ...KugouConfig.androidCommonHeaders,
          },
        ),
      );
      final list = _extractList(res.data, ['data']);
      final songs = list
          .map(_mapDailySong)
          .where((s) => s.name.isNotEmpty && (s.hash?.isNotEmpty ?? false))
          .toList();
      debugPrint('🎧 酷狗(${platform.label})私人FM 取到 ${songs.length} 首');
      return songs;
    } catch (e) {
      debugPrint('⚠️ 酷狗私人FM失败: $e');
      return const [];
    }
  }

  /// 每日推荐条目 → [SongModel]（hash 取顶层 `hash`）。
  SongModel _mapDailySong(Map<String, dynamic> j) {
    final hash = (j['hash'] ?? j['hash_128'] ?? '').toString();
    var cover = (j['sizable_cover'] ?? j['cover'] ?? '').toString();
    cover = cover.replaceAll('{size}', '480');
    final durationMs = int.tryParse(
            (j['time_length'] ?? j['timelength'] ?? '').toString()) ??
        0;
    return SongModel(
      id: (j['audio_id'] ?? j['songid'] ?? '').toString(),
      name: (j['songname'] ?? j['ori_audio_name'] ?? '').toString(),
      artist: (j['author_name'] ?? '').toString(),
      album: (j['album_name'] ?? '').toString(),
      source: kind,
      coverUrl: cover.isEmpty ? null : cover,
      duration: durationMs > 0 ? durationMs : null,
      hash: hash.isEmpty ? null : hash.toLowerCase(),
      albumId: (j['album_id'] ?? '').toString(),
      albumAudioId: (j['album_audio_id'] ?? '').toString(),
    );
  }

  // ── 解析工具 ──────────────────────────────────────────────

  /// 从嵌套响应中取列表（防御性：任一层缺失返回空）。
  ///
  /// ⚠️ 酷狗 complexsearch 部分 CDN 节点返回 `text/html` 而非 `application/json`，
  /// 此时 Dio 不会自动 JSON 解码 → `res.data` 为原始 **String**；此处手动解码兜底，
  /// 否则即使签名正确也会因解析失败得到空结果。
  List<Map<String, dynamic>> _extractList(dynamic data, List<String> path) {
    dynamic cur = data;
    if (cur is String) {
      try {
        cur = jsonDecode(cur);
      } catch (_) {
        return const [];
      }
    }
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
        .map((j) => SongModel.fromKugouJson(j, source: kind))
        .where((s) => s.name.isNotEmpty)
        .toList();
  }

  /// 截断过长响应用于日志（避免刷屏；不含敏感 query 的字段是服务端返回体）。
  String _truncate(dynamic v) {
    final s = v?.toString() ?? '';
    return s.length > 400 ? '${s.substring(0, 400)}…' : s;
  }

  /// 解析直链。兼容多种结构：
  /// - `/v5/url`（现行）：字段在**响应顶层**，`url` / `backupUrl` 为数组或字符串；
  /// - 包裹式：`data` 为对象或数组，其内含 `url` / `play_url` / `backup_url`。
  ///
  /// ⚠️ 部分 CDN 节点返回 `text/plain`，Dio 不解码 → `data` 为原始 String，
  /// 需手动 `jsonDecode`（与搜索主路径同款容错）。
  String? _extractPlayUrl(dynamic data) {
    dynamic cur = data;
    if (cur is String) {
      try {
        cur = jsonDecode(cur);
      } catch (_) {
        return null;
      }
    }
    if (cur is! Map) return null;
    // 1) 顶层（/v5/url 现行）
    final top = _pickUrl(cur['url']) ??
        _pickUrl(cur['play_url']) ??
        _pickUrl(cur['backupUrl']) ??
        _pickUrl(cur['backup_url']);
    if (top != null) return top;
    // 2) data 包裹
    final d = cur['data'];
    if (d is Map) {
      return _pickUrl(d['url']) ??
          _pickUrl(d['play_url']) ??
          _pickUrl(d['backupUrl']) ??
          _pickUrl(d['backup_url']);
    }
    if (d is List && d.isNotEmpty) {
      final first = d.first;
      if (first is Map) {
        return _pickUrl(first['url']) ??
            _pickUrl(first['play_url']) ??
            _pickUrl(first['backup_url']);
      }
    }
    return null;
  }

  /// 从「字符串或字符串数组」中取首个非空 URL。
  String? _pickUrl(dynamic v) {
    if (v is String && v.isNotEmpty) return v;
    if (v is List && v.isNotEmpty) {
      final first = v.first;
      if (first is String && first.isNotEmpty) return first;
    }
    return null;
  }
}

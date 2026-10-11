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

/// 酷狗概念版音源实现（ARCH §4.6）。
///
/// - 搜索：**主路径** `complexsearch`（需签名）；仅在主路径返回空时
///   才走免签名 `mobilecdn` 兜底（该域名实测常不可达，需容忍其失败）。
/// - 播放：`gateway/v3/url`，请求头 `x-router: tracker.kugou.com`；
///   `key` 使用**概念版 lite 盐值**。
/// - 歌词：`krcs` 取 id/accesskey → `lyrics/download` 取 base64 LRC（不解 KRC）。
/// - 任何失败一律返回空 / null + 日志，交由 [SourceManager] 回退网易云。
class KugouSource implements MusicSource {
  KugouSource._internal(this._dio);

  static final KugouSource _instance = KugouSource._internal(_createDio());

  factory KugouSource() => _instance;

  /// 测试专用：注入自定义 [Dio]（记录请求 / 假应答）。
  @visibleForTesting
  factory KugouSource.withDio(Dio dio) => KugouSource._internal(dio);

  static Dio _createDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

  final Dio _dio;

  /// 搜索 / 歌词请求的取消令牌（竞态保护：新请求先取消旧请求）。
  CancelToken? _searchCancel;

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
        'appid': KugouConfig.appid, // 概念版 1005
        'srcappid': KugouConfig.srcappid, // 2919
        'clientver': KugouConfig.clientver,
        'clienttime': DateTime.now().millisecondsSinceEpoch,
        'dfid': KugouDevice.dfid,
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
    final dfid = await KugouDeviceService.instance.ensureDfid();
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
        'page_id': KugouConfig.playPageId,
        'quality': 128,
        'album_audio_id': albumAudioId,
        'behavior': 'play',
        'pid': KugouConfig.playPid,
        'cmd': KugouConfig.playCmd,
        'pidversion': KugouConfig.playPidVersion,
        'IsFreePart': 0,
        'ppage_id': KugouConfig.playPpageId,
        'cdnBackup': 1,
        'module': '',
        'clientver': KugouConfig.playVersion,
        // 默认参数
        'dfid': dfid,
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appid,
        'clienttime': clienttime,
      };
      if (userToken.isNotEmpty) params['token'] = userToken;
      if (userId != '0') params['userid'] = userId;
      // encryptKey：key = md5(hash + lite盐 + appid + mid + userid)
      params['key'] = KugouSign.playKey(
        hash: hashLower,
        mid: KugouDevice.mid,
        userId: userId,
        salt: KugouConfig.keySaltLite,
      );
      // Android 端签名（lite 盐）
      final signature = KugouSign.androidSignature(params);

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
        .map(SongModel.fromKugouJson)
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

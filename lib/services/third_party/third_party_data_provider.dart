import 'package:flutter/foundation.dart';

import '../../models/kugou_platform.dart';
import '../../models/song_model.dart';
import '../audio_player_service.dart';
import '../genre_metadata_service.dart';
import '../kugou_credential_service.dart';
import '../music_api_service.dart';
import '../../models/third_party_auth.dart';

/// 取数阶段的业务异常。
///
/// [code] 直接用协议错误码（`not_logged_in` / `resolve_failed` / `bad_request`），
/// [message] 为中文说明。**异常信息里不得出现令牌明文**（ARCH T8）。
class ThirdPartyException implements Exception {
  const ThirdPartyException(this.code, [this.message = '']);

  final String code;
  final String message;

  @override
  String toString() => 'ThirdPartyException($code: $message)';
}

/// 酷狗凭证快照（避免把 `KugouCredentialService` 直接暴露成依赖，方便单测注入）。
typedef KugouCredentialSnapshot = ({String? token, String? userId, String? nickname});

/// 按平台读取凭证的函数签名。
typedef KugouCredentialSource = KugouCredentialSnapshot Function(
  KugouPlatform platform,
);

/// 曲风索引读取函数签名（`歌曲匹配键 → {tag → 权重}`）。
typedef GenreTagIndexSource = Map<String, Map<String, double>> Function();

/// 直链解析函数签名。
typedef SongUrlResolver = Future<String?> Function(SongModel song);

/// 播放动作端口（把 `AudioPlayerService` 的具体方法收敛成可注入接口）。
abstract class PlaybackPort {
  Future<void> playSongs(List<SongModel> songs);

  Future<void> pause();

  Future<void> resume();

  Future<void> next();

  Future<void> previous();
}

/// 真实播放端口：转调现有 `AudioPlayerService`，**不新建任何播放状态**。
class AudioServicePlaybackPort implements PlaybackPort {
  @override
  Future<void> playSongs(List<SongModel> songs) =>
      AudioPlayerService().playSongs(songs);

  @override
  Future<void> pause() => AudioPlayerService().pause();

  @override
  Future<void> resume() => AudioPlayerService().resume();

  @override
  Future<void> next() => AudioPlayerService().playNext();

  @override
  Future<void> previous() => AudioPlayerService().playPrevious();
}

/// 四类 scope 的取数实现（ARCHITECTURE §6.2）。
///
/// **只负责取数，不做任何授权判断** —— 是否允许返回某项数据由
/// `ThirdPartyAuthService` 与 `LoopbackServer` 判定（ARCH §5 单一决策点原则）。
class ThirdPartyDataProvider {
  ThirdPartyDataProvider({
    GenreTagIndexSource? tagIndexSource,
    KugouCredentialSource? credentialSource,
    SongUrlResolver? urlResolver,
    PlaybackPort? playback,
    int Function()? now,
  })  : _tagIndexSource = tagIndexSource ?? _defaultTagIndexSource,
        _credentialSource = credentialSource ?? _defaultCredentialSource,
        _urlResolver = urlResolver ?? _defaultUrlResolver,
        _playbackOverride = playback,
        _now = now ?? _defaultNow;

  /// 曲风画像最多返回多少个标签（ARCH §6.2）。
  static const int topGenreLimit = 10;

  /// 默认曲风来源：`GenreMetadataService.tagIndex`（本机推断数据）。
  static Map<String, Map<String, double>> _defaultTagIndexSource() =>
      GenreMetadataService().tagIndex;

  /// 默认凭证来源：`KugouCredentialService`（按平台分区）。
  static KugouCredentialSnapshot _defaultCredentialSource(
    KugouPlatform platform,
  ) {
    final service = KugouCredentialService.instance;
    return (
      token: service.tokenOf(platform),
      userId: service.userIdOf(platform),
      nickname: service.nicknameOf(platform),
    );
  }

  /// 默认直链解析：`MusicApiService().getSongUrlForSong`（按音源分流）。
  static Future<String?> _defaultUrlResolver(SongModel song) =>
      MusicApiService().getSongUrlForSong(song);

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final GenreTagIndexSource _tagIndexSource;
  final KugouCredentialSource _credentialSource;
  final SongUrlResolver _urlResolver;
  final PlaybackPort? _playbackOverride;
  final int Function() _now;

  late final PlaybackPort _playback = _playbackOverride ?? AudioServicePlaybackPort();

  /// 按 scope 取数。
  ///
  /// [params] 为交换请求里该 scope 的参数对象（可为 null）。
  /// 失败时抛 [ThirdPartyException]，由调用方翻译成协议错误码。
  Future<Map<String, dynamic>> fetch(
    ThirdPartyScope scope,
    Map<String, dynamic>? params,
  ) async {
    switch (scope) {
      case ThirdPartyScope.genreRead:
        return _fetchGenres();
      case ThirdPartyScope.accountToken:
        return _fetchAccountToken(params);
      case ThirdPartyScope.urlResolve:
        return _resolveUrl(params);
      case ThirdPartyScope.playbackControl:
        return _controlPlayback(params);
    }
  }

  // ── genre.read ───────────────────────────────────────────────

  /// 聚合 `tagIndex`：把所有歌曲的 tag 权重累加 → 归一化 → 取前 10。
  Map<String, dynamic> _fetchGenres() {
    final index = _tagIndexSource();
    final totals = <String, double>{};
    var sampleSize = 0;

    index.forEach((_, tags) {
      var contributed = false;
      tags.forEach((tag, weight) {
        final name = tag.trim();
        if (name.isEmpty || weight <= 0) return;
        totals[name] = (totals[name] ?? 0) + weight;
        contributed = true;
      });
      if (contributed) sampleSize++;
    });

    final sum = totals.values.fold<double>(0, (a, b) => a + b);
    if (sum <= 0) {
      return <String, dynamic>{
        'topGenres': <Map<String, Object?>>[],
        'sampleSize': 0,
        'updatedAt': _now(),
      };
    }

    final entries = totals.entries.toList()
      ..sort((a, b) {
        final byWeight = b.value.compareTo(a.value);
        // 权重相同按 tag 名升序，保证输出稳定（便于测试与客户端缓存比对）
        return byWeight != 0 ? byWeight : a.key.compareTo(b.key);
      });

    final top = <Map<String, Object?>>[
      for (final entry in entries.take(topGenreLimit))
        <String, Object?>{
          'tag': entry.key,
          // 保留 4 位小数：避免浮点噪声导致同一份数据每次序列化都不同
          'weight': double.parse((entry.value / sum).toStringAsFixed(4)),
        },
    ];

    return <String, dynamic>{
      'topGenres': top,
      'sampleSize': sampleSize,
      'updatedAt': _now(),
    };
  }

  // ── account.token ────────────────────────────────────────────

  /// 取酷狗令牌；未登录抛 `not_logged_in`。
  ///
  /// 平台参数支持 `lite`（酷狗概念版，默认）/ `standard`（酷狗音乐）。
  Map<String, dynamic> _fetchAccountToken(Map<String, dynamic>? params) {
    final platform =
        KugouPlatform.fromCode(params?['platform']?.toString() ?? 'lite');
    final snapshot = _credentialSource(platform);
    final token = snapshot.token?.trim() ?? '';
    final userId = snapshot.userId?.trim() ?? '';
    if (token.isEmpty || userId.isEmpty) {
      // 注意：异常信息里不带任何令牌片段（ARCH T8）
      throw const ThirdPartyException(
        AuthErrors.notLoggedIn,
        'SuchMusic 尚未登录酷狗账号，请先在 App 内完成登录',
      );
    }
    return <String, dynamic>{
      'platform': platform.code,
      'token': token,
      'userId': userId,
      'nickname': snapshot.nickname ?? '',
    };
  }

  // ── url.resolve ──────────────────────────────────────────────

  /// 解析直链；入参必须带 `song` 对象。
  Future<Map<String, dynamic>> _resolveUrl(Map<String, dynamic>? params) async {
    final song = songFromParams(params);
    String? url;
    try {
      url = await _urlResolver(song);
    } catch (e) {
      // 只记错误类型，不记任何响应体（可能含带签名的直链）
      debugPrint('第三方 url.resolve 解析异常: ${e.runtimeType}');
      throw const ThirdPartyException(
        AuthErrors.resolveFailed,
        '无法解析该歌曲的播放地址',
      );
    }
    if (url == null || url.trim().isEmpty) {
      throw const ThirdPartyException(
        AuthErrors.resolveFailed,
        '无法解析该歌曲的播放地址',
      );
    }
    return <String, dynamic>{
      'url': url,
      'source': song.source.code,
      'songId': song.id,
      'resolvedAt': _now(),
    };
  }

  // ── playback.control ─────────────────────────────────────────

  /// 代播控制；只支持 play/pause/resume/next/previous。
  Future<Map<String, dynamic>> _controlPlayback(
    Map<String, dynamic>? params,
  ) async {
    final action = (params?['action']?.toString() ?? '').trim().toLowerCase();
    switch (action) {
      case 'play':
        final song = songFromParams(params);
        await _playback.playSongs(<SongModel>[song]);
        break;
      case 'pause':
        await _playback.pause();
        break;
      case 'resume':
        await _playback.resume();
        break;
      case 'next':
        await _playback.next();
        break;
      case 'previous':
        await _playback.previous();
        break;
      default:
        throw ThirdPartyException(
          AuthErrors.badRequest,
          '不支持的播放动作：${action.isEmpty ? '(空)' : action}',
        );
    }
    return <String, dynamic>{'ok': true, 'action': action};
  }
}

/// 把交换请求里的 `song` 对象还原成 [SongModel]。
///
/// 只接受 `id`（必需）、`source`、`name`、`artist`、`album`、`duration`、
/// `hash` / `albumId` / `albumAudioId`（酷狗直链必需）等白名单字段，
/// 其余字段忽略 —— 避免第三方塞入本地路径等敏感字段。
SongModel songFromParams(Map<String, dynamic>? params) {
  final raw = params?['song'];
  if (raw is! Map) {
    throw const ThirdPartyException(
      AuthErrors.badRequest,
      '缺少 song 对象',
    );
  }
  return songFromJson(raw);
}

/// 由 JSON 构造 [SongModel]（字段白名单，缺失必需字段抛 `bad_request`）。
SongModel songFromJson(Map<Object?, Object?> raw) {
  final id = (raw['id'] ?? raw['songId'] ?? '').toString().trim();
  if (id.isEmpty) {
    throw const ThirdPartyException(
      AuthErrors.badRequest,
      'song.id 不能为空',
    );
  }
  final durationRaw = raw['duration'];
  final duration = durationRaw is num
      ? durationRaw.toInt()
      : int.tryParse(durationRaw?.toString() ?? '');

  String? optionalText(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  return SongModel(
    id: id,
    name: (raw['name'] ?? '').toString(),
    artist: (raw['artist'] ?? '').toString(),
    album: (raw['album'] ?? '').toString(),
    coverUrl: optionalText(raw['coverUrl']),
    duration: duration,
    source: SongSource.fromCode(optionalText(raw['source'])),
    hash: optionalText(raw['hash']),
    albumId: optionalText(raw['albumId']),
    albumAudioId: optionalText(raw['albumAudioId']),
  );
}

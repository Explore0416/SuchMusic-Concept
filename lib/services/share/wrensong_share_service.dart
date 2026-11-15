import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../models/song_model.dart';
import '../sources/source_manager.dart';

/// 「歌曲分享到 Wrensong」的结果。
///
/// 用 sealed class 而非 enum + message：每个分支携带的信息不同
/// （只有 [WrensongShareFailed] 需要说明原因），switch 时也不容易漏分支。
sealed class WrensongShareResult {
  const WrensongShareResult();

  /// 已交给 Wrensong（面板由对方拉起，本 App 不再提示任何东西）
  const factory WrensongShareResult.ok() = WrensongShareOk;

  /// 设备未安装 Wrensong —— 调用方应降级为「复制歌曲信息」
  const factory WrensongShareResult.notInstalled() = WrensongShareNotInstalled;

  /// 本地曲目没有可分享的在线地址（`music_url` / `url` 都给不出来）
  const factory WrensongShareResult.notSupportedLocal() =
      WrensongShareNotSupportedLocal;

  /// 其它失败（桥接抛异常、原生返回未知 reason 等）
  const factory WrensongShareResult.failed(String message) = WrensongShareFailed;
}

/// 分享成功。
final class WrensongShareOk extends WrensongShareResult {
  const WrensongShareOk();
}

/// Wrensong 未安装。
final class WrensongShareNotInstalled extends WrensongShareResult {
  const WrensongShareNotInstalled();
}

/// 本地曲目不支持走 Wrensong 分享。
final class WrensongShareNotSupportedLocal extends WrensongShareResult {
  const WrensongShareNotSupportedLocal();
}

/// 分享失败。
final class WrensongShareFailed extends WrensongShareResult {
  const WrensongShareFailed(this.message);

  /// 失败原因（仅用于日志 / 调试；面向用户的文案由调用方决定）
  final String message;
}

/// 原生桥抽象（测试可替换成假实现，避免依赖 MethodChannel）。
abstract class WrensongShareBridge {
  /// Wrensong 是否已安装（Android 11+ 需 Manifest `<queries>` 声明才查得到）
  Future<bool> isInstalled();

  /// 唤起 Wrensong 的分享面板。
  Future<WrensongShareResult> share({
    required String appId,
    required Map<String, Object?> payload,
    Uint8List? thumbBytes,
  });
}

/// 默认实现：走 `com.lightningteam.suchmusic/wrensong_share` 方法通道。
class MethodChannelWrensongShareBridge implements WrensongShareBridge {
  /// 与 Kotlin 侧 `WrensongShareBridge.CHANNEL` 保持一致。
  static const MethodChannel channel = MethodChannel(
    'com.lightningteam.suchmusic/wrensong_share',
  );

  @override
  Future<bool> isInstalled() async {
    try {
      return await channel.invokeMethod<bool>('isInstalled') ?? false;
    } on PlatformException {
      // 查询失败一律按「未安装」处理：宁可降级复制，也不要抛异常打断播放页
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<WrensongShareResult> share({
    required String appId,
    required Map<String, Object?> payload,
    Uint8List? thumbBytes,
  }) async {
    try {
      final raw = await channel.invokeMethod<Map<Object?, Object?>>('share', {
        'appId': appId,
        'payload': payload,
        'thumbBytes': thumbBytes,
      });
      if (raw == null) {
        return const WrensongShareResult.failed('原生未返回结果');
      }
      if (raw['ok'] == true) {
        return const WrensongShareResult.ok();
      }
      final reason = raw['reason']?.toString();
      if (reason == 'not_installed') {
        return const WrensongShareResult.notInstalled();
      }
      return WrensongShareResult.failed(reason ?? 'unknown');
    } on PlatformException catch (e) {
      return WrensongShareResult.failed(e.message ?? e.code);
    } on MissingPluginException catch (e) {
      return WrensongShareResult.failed(e.message ?? 'native_unavailable');
    }
  }
}

/// 取直链（可注入假实现，测试不触网）。
typedef DirectUrlResolver = Future<String?> Function(SongModel song);

/// 取封面字节（可注入假实现，测试不触网）。
typedef CoverBytesFetcher = Future<Uint8List?> Function(String url);

/// 歌曲分享到 Wrensong（协议见 `docs/wrensong-share.md`）。
///
/// 分享链路：取直链（4s 超时，失败不阻塞）→ 取封面（≤2MB）→ 组 payload
/// → 原生桥 `ACTION_SHARE` + `setPackage` 显式唤起 Wrensong。
///
/// **任何异常都不向 UI 抛**：调用方拿到的是结果对象，按分支决定 toast / 降级。
class WrensongShareService {
  WrensongShareService({
    WrensongShareBridge? bridge,
    DirectUrlResolver? resolveDirectUrl,
    CoverBytesFetcher? fetchCover,
  })  : _bridge = bridge ?? MethodChannelWrensongShareBridge(),
        _resolveDirectUrl = resolveDirectUrl ?? _defaultResolveDirectUrl,
        _fetchCover = fetchCover ?? _defaultFetchCover;

  /// App 内单例（原生桥无状态，不需要多实例）。
  static final WrensongShareService instance = WrensongShareService();

  /// 开放平台分配的 app_id（换 app_id 只需改这一处，见 docs §6）。
  static const String appId = 'wr_app_ccd99a251a27';

  /// 取直链超时：4 秒拿不到就按「无直链」降级成 link 类型，不拖着分享入口转圈。
  static const Duration urlTimeout = Duration(seconds: 4);

  /// 取封面超时（封面只影响缩略图，失败就不带 thumb）。
  static const Duration coverTimeout = Duration(seconds: 4);

  /// 封面上限 2MB：超过直接丢弃（原生还会再压到 ≤64KB）。
  static const int maxCoverBytes = 2 * 1024 * 1024;

  /// payload JSON 上限 8KB（原生侧序列化后再校验一次）。
  static const int payloadMaxBytes = 8192;

  /// 标题上限 64 字（Wrensong 协议要求）。
  static const int titleMaxRunes = 64;

  /// 描述上限 120 字。
  static const int descMaxRunes = 120;

  static final Dio _dio = Dio();

  final WrensongShareBridge _bridge;
  final DirectUrlResolver _resolveDirectUrl;
  final CoverBytesFetcher _fetchCover;

  /// 分享当前歌曲。
  ///
  /// 顺序：本地曲目 → 未安装 → 取直链 → 取封面 → 调原生桥。
  Future<WrensongShareResult> shareSong(SongModel song) async {
    // 本地曲目：`music_url`（music 类型必填）与 `url`（link 类型必填）都给不出，
    // 直接交给调用方降级为「复制歌曲信息」，不去查安装状态白跑一趟。
    if (song.isLocal) {
      return const WrensongShareResult.notSupportedLocal();
    }

    if (!await _isInstalledSafely()) {
      return const WrensongShareResult.notInstalled();
    }

    final directUrl = await _directUrlOf(song);
    final thumb = await _coverBytesOf(song);
    final payload = _buildPayload(song, directUrl: directUrl);

    try {
      return await _bridge.share(
        appId: appId,
        payload: payload,
        thumbBytes: thumb,
      );
    } catch (e) {
      // 桥接层任何异常（含 channel 未注册）都收敛成 failed，由调用方降级
      return WrensongShareResult.failed('$e');
    }
  }

  /// 降级文案：`歌名 - 歌手\n链接`；本地曲目链接位写「本地文件」。
  static String shareTextOf(SongModel song) {
    final link = webLinkOf(song);
    return '${song.name} - ${song.artist}\n${link.isEmpty ? '本地文件' : link}';
  }

  /// 网页版链接（沿用改造前 `player_page._shareLinkOf` 的规则）。
  static String webLinkOf(SongModel song) {
    if (song.source.isLocal) return '';
    if (song.source.isKugou) {
      return 'https://www.kugou.com/song/#hash=${song.id}';
    }
    return 'https://music.163.com/song?id=${song.id}';
  }

  Future<bool> _isInstalledSafely() async {
    try {
      return await _bridge.isInstalled();
    } catch (_) {
      return false;
    }
  }

  /// 取播放直链；超时 / 异常 / 空串一律视为「没有直链」。
  Future<String?> _directUrlOf(SongModel song) async {
    try {
      final url = await _resolveDirectUrl(song).timeout(urlTimeout);
      if (url == null || url.isEmpty) return null;
      return url;
    } catch (_) {
      return null;
    }
  }

  /// 取封面字节；无封面 / 超时 / 超 2MB / 异常一律返回 null。
  Future<Uint8List?> _coverBytesOf(SongModel song) async {
    final url = song.coverUrl;
    if (url == null || url.isEmpty) return null;
    try {
      return await _fetchCover(url).timeout(coverTimeout);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _defaultResolveDirectUrl(SongModel song) =>
      SourceManager().withFallback<String>(
        song,
        (src, s, strict) => src.getSongUrl(s, strict: strict),
      );

  static Future<Uint8List?> _defaultFetchCover(String url) async {
    final res = await _dio.get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: coverTimeout,
        sendTimeout: coverTimeout,
      ),
    );
    final data = res.data;
    if (data == null || data.isEmpty) return null;
    if (data.length > maxCoverBytes) return null;
    return Uint8List.fromList(data);
  }

  /// 组 payload（字段映射见 docs §3）：
  /// 有直链 → `music`（含 `music_url` + 网页 `url`）；无直链 → `link`。
  Map<String, Object?> _buildPayload(SongModel song, {String? directUrl}) {
    final title = _truncateRunes(song.name, titleMaxRunes);
    final desc = _truncateRunes(_descOf(song), descMaxRunes);
    final link = webLinkOf(song);

    final base = <String, Object?>{'title': title};
    if (desc.isNotEmpty) base['desc'] = desc;

    if (directUrl != null && directUrl.isNotEmpty) {
      return <String, Object?>{
        'type': 'music',
        ...base,
        'music_url': directUrl,
        if (link.isNotEmpty) 'url': link,
      };
    }
    return <String, Object?>{'type': 'link', ...base, 'url': link};
  }

  /// `歌手 · 专辑`；专辑为空只写歌手。
  String _descOf(SongModel song) {
    final artist = song.artist.isEmpty ? '未知歌手' : song.artist;
    return song.album.isEmpty ? artist : '$artist · ${song.album}';
  }

  /// 按 **runes** 截断：按 code unit 截会把 emoji 等代理对切成半个字符，
  /// 传到 Wrensong 侧就是乱码。
  static String _truncateRunes(String value, int maxRunes) {
    final runes = value.runes;
    if (runes.length <= maxRunes) return value;
    return String.fromCharCodes(runes.take(maxRunes));
  }
}

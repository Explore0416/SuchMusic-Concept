import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 远端版本信息（对应分发仓库里的 update.json）
class AppUpdateInfo {
  final String versionName; // 版本名，如 1.0.1（仅展示用）
  final int versionCode; // 版本号，比本地大才算有更新
  final String cfUrl; // APK 下载直链（Cloudflare Pages，国内快，主链路）
  final String giteeUrl; // APK 下载直链（Gitee，历史兼容）
  final String githubUrl; // APK 下载直链（GitHub，备用链路）
  final String changelog; // 更新日志
  final bool force; // 是否强制更新（true 时弹窗不可关闭，必须完成更新）

  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    this.cfUrl = '',
    this.giteeUrl = '',
    this.githubUrl = '',
    required this.changelog,
    this.force = false,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      versionName: json['versionName']?.toString() ?? '',
      versionCode: int.tryParse(json['versionCode']?.toString() ?? '') ?? 0,
      cfUrl: json['cf']?.toString() ?? '',
      giteeUrl: json['gitee']?.toString() ?? '',
      githubUrl: json['github']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
      force: json['force'] == true,
    );
  }

  /// 下载地址列表（过滤空项）：Cloudflare 优先（国内快），GitHub 兜底
  List<String> get downloadUrls =>
      [cfUrl, githubUrl, giteeUrl].where((u) => u.isNotEmpty).toList();
}

/// App 更新服务：请求版本信息 / 下载 APK / 调起系统安装器
/// 多链路策略：Cloudflare Pages 为主（国内访问快），GitHub 兜底
class UpdateService {
  UpdateService._();

  /// Cloudflare Pages 自定义域名 —— 主链路（国内快）
  static const String _cfJsonUrl =
      'https://dl.lightning-team.de5.net/update.json';

  /// Cloudflare Pages 默认域名 —— 备用（自定义域名未就绪时可用）
  static const String _cfPagesJsonUrl =
      'https://suchmusic-updates.pages.dev/update.json';

  /// 分发仓库 raw —— 兜底
  static const String _githubJsonUrl =
      'https://raw.githubusercontent.com/Lightning-technology-team/SuchMusic-Updates/main/public/update.json';

  /// 版本信息源，按顺序尝试（Cloudflare 优先，GitHub 兜底）
  static const List<String> _updateJsonUrls = [
    _cfJsonUrl,
    _cfPagesJsonUrl,
    _githubJsonUrl,
  ];

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  /// 拉取远端版本信息：依次尝试所有源，任一成功即返回，全部失败抛最后错误
  static Future<AppUpdateInfo> fetchRemoteInfo() async {
    Object? lastError;
    for (final url in _updateJsonUrls) {
      try {
        final resp = await _dio.get(url);
        final data = resp.data;
        final Map<String, dynamic> json;
        if (data is Map<String, dynamic>) {
          json = data;
        } else {
          json = jsonDecode(data as String) as Map<String, dynamic>;
        }
        return AppUpdateInfo.fromJson(json);
      } catch (e) {
        lastError = e;
        debugPrint('⚠️ 更新源不可用: $url | $e');
      }
    }
    throw lastError ?? Exception('所有更新源均不可用');
  }

  /// 本地版本号（pubspec 的 build number，Android 上即 versionCode）
  static Future<int> localVersionCode() async {
    final info = await PackageInfo.fromPlatform();
    return int.tryParse(info.buildNumber) ?? 1;
  }

  /// 下载 APK：先在**全部候选源**中并发测速，按实测吞吐排序后逐个尝试。
  ///
  /// 「优选」的两层含义：
  /// 1. **多源**：Cloudflare / GitHub 直连 / GitHub 公共加速镜像同时纳入候选；
  /// 2. **多连接**：选定线路后若支持 `Range`（206），切成 4 路并行下载；
  ///    不支持（如 CF Worker 忽略 Range）则立即回退单连接，不浪费流量。
  ///
  /// 用户主动取消时直接抛出，不再尝试下一个链接。
  static Future<String> downloadApk(
    List<String> urls, {
    void Function(int received, int total)? onProgress,
    void Function(String route)? onRouteChanged,
    CancelToken? cancelToken,
  }) async {
    Object? lastError;
    final candidates = _expandMirrors(urls.where((u) => u.isNotEmpty).toList());
    // 下载前并发探测各线路速率，优先走最快线路；探测异常时回退为原始顺序
    final ordered = await rankBySpeed(candidates);
    for (final url in ordered) {
      try {
        onRouteChanged?.call(_routeNameOf(url));
        return await _downloadOne(
          url,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
      } catch (e) {
        if (e is DioException && e.type == DioExceptionType.cancel) rethrow;
        lastError = e;
        debugPrint('⚠️ APK下载失败: $url | $e');
      }
    }
    throw lastError ?? Exception('无可用的下载地址');
  }

  /// GitHub 公共加速镜像前缀（国内多数网络下比 github.com 直连快，且普遍支持 Range）。
  /// 失效镜像在测速阶段会被判为最慢并排到最后，不会拖慢正常下载。
  static const List<String> _ghMirrors = [
    'https://ghfast.top/',
    'https://gh-proxy.com/',
    'https://ghproxy.net/',
  ];

  /// 展开候选源：原始 URL + GitHub 直链对应的镜像变体（去重、保持原始顺序优先）。
  static List<String> _expandMirrors(List<String> urls) {
    final out = <String>[];
    void add(String u) {
      if (u.isNotEmpty && !out.contains(u)) out.add(u);
    }

    for (final u in urls) {
      add(u);
      final isGitHub = u.contains('github.com/') ||
          u.contains('githubusercontent.com/') ||
          u.contains('objects.githubusercontent.com/');
      if (isGitHub) {
        for (final m in _ghMirrors) {
          add('$m$u');
        }
      }
    }
    return out;
  }

  /// 下载线路显示名（供下载对话框提示用）。
  static String _routeNameOf(String url) {
    if (url.contains('de5.net') || url.contains('pages.dev')) {
      return 'Cloudflare 主线路';
    }
    if (url.contains('gitee.com')) return 'Gitee 线路';
    if (url.contains('ghfast.top') ||
        url.contains('gh-proxy.com') ||
        url.contains('ghproxy.net')) {
      return '加速镜像线路';
    }
    return 'GitHub 备用线路';
  }

  /// 下载前对候选线路并发测速，按实测速率降序返回。
  /// 任一步骤失败均不抛异常：探测失败视为 0，全部为 0 时回退为原顺序，
  /// 保证「测速」环节本身永不阻断更新流程。
  static Future<List<String>> rankBySpeed(List<String> urls) async {
    if (urls.length <= 1) return urls;
    try {
      final speeds = await Future.wait(urls.map(_probeSpeed));
      if (speeds.every((v) => v == 0)) return urls; // 全部探测失败 → 原顺序
      final order = List<int>.generate(urls.length, (i) => i)
        ..sort((a, b) => speeds[b].compareTo(speeds[a]));
      return order.map((i) => urls[i]).toList();
    } catch (_) {
      return urls;
    }
  }

  /// 探测单条线路速率：Range 取前 128KB（≤3s），返回字节/秒；失败返回 0。
  static Future<int> _probeSpeed(String url) async {
    final sw = Stopwatch()..start();
    int bytes = 0;
    try {
      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Range': 'bytes=0-131071'},
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      final stream = resp.data?.stream;
      if (stream != null) {
        await for (final chunk in stream) {
          bytes += chunk.length;
          if (bytes >= 131072 || sw.elapsedMilliseconds >= 3000) break;
        }
      }
    } catch (e) {
      debugPrint('⚠️ 线路测速失败（按最慢处理）: $url | $e');
    }
    sw.stop();
    final ms = sw.elapsedMilliseconds <= 0 ? 1 : sw.elapsedMilliseconds;
    return (bytes * 1000 / ms).round();
  }

  /// 从单个直链下载 APK 到缓存目录。
  /// 优先用 **4 路分块并行下载**（Range 请求，显著提升单连接被限速时的吞吐）；
  /// 服务器不支持 Range / 任一分块失败时，回退为单连接下载。
  static Future<String> _downloadOne(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getTemporaryDirectory();
    final savePath = '${dir.path}/such_music_update.apk';
    final old = File(savePath);
    if (await old.exists()) await old.delete();

    try {
      final ok = await _downloadParallel(
        url,
        savePath,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      if (ok) return savePath;
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) rethrow;
      debugPrint('⚠️ 多连接下载失败，回退单连接: $e');
      try {
        if (await old.exists()) await old.delete();
      } catch (_) {}
    }

    // 大文件下载：放宽接收超时
    await _dio.download(
      url,
      savePath,
      cancelToken: cancelToken,
      options: Options(receiveTimeout: const Duration(minutes: 30)),
      onReceiveProgress: onProgress,
    );
    return savePath;
  }

  /// 4 路分块并行下载；成功返回 true，条件不满足（小文件 / 不支持 Range）返回 false。
  ///
  /// 实现要点：
  /// - 每路写独立 `.partN` 文件（避免多 future 交错 `setPosition` 造成写串），
  ///   全部完成后顺序拼接为主文件；
  /// - 任一路响应非 206（服务器忽略 Range）即判定不支持，清理分片后回退；
  /// - 进度为各路已收字节之和，取消令牌透传给每一路。
  static Future<bool> _downloadParallel(
    String url,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
    int connections = 4,
  }) async {
    const minSize = 8 * 1024 * 1024; // < 8MB 不值得并行
    int total = -1;
    bool rangeOk = false;

    try {
      final head = await _dio.head(
        url,
        options: Options(
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      total = int.tryParse(head.headers.value(HttpHeaders.contentLengthHeader) ?? '') ?? -1;
      final accept = (head.headers.value('accept-ranges') ?? '').toLowerCase();
      rangeOk = accept.contains('bytes');
    } catch (e) {
      debugPrint('HEAD 失败（继续尝试 Range 探测）: $e');
    }

    // HEAD 不可用：用一次 Range 探测确认 206 与总长（Content-Range: bytes 0-0/12345）
    if (total <= 0 || !rangeOk) {
      try {
        final probe = await _dio.get<ResponseBody>(
          url,
          options: Options(
            responseType: ResponseType.stream,
            headers: {'Range': 'bytes=0-0'},
            sendTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 15),
          ),
        );
        rangeOk = probe.statusCode == 206;
        final cr = probe.headers.value('content-range') ?? '';
        final slash = cr.lastIndexOf('/');
        if (slash > 0) total = int.tryParse(cr.substring(slash + 1)) ?? total;
        // 立即丢弃探测流
        await probe.data?.stream.drain<void>();
      } catch (e) {
        debugPrint('Range 探测失败: $e');
      }
    }

    if (!rangeOk || total < minSize) return false;

    final parts = <File>[];
    final received = List<int>.filled(connections, 0);
    int reported = 0;
    void report() {
      final sum = received.fold<int>(0, (a, b) => a + b);
      if (sum - reported >= 64 * 1024 || sum == total) {
        reported = sum;
        onProgress?.call(sum, total);
      }
    }

    final chunk = (total / connections).ceil();
    try {
      final futures = <Future<void>>[];
      for (var i = 0; i < connections; i++) {
        final start = i * chunk;
        if (start >= total) break;
        final end = math.min(total - 1, start + chunk - 1);
        final partPath = '$savePath.part$i';
        parts.add(File(partPath));
        futures.add(() async {
          final resp = await _dio.get<ResponseBody>(
            url,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              headers: {'Range': 'bytes=$start-$end'},
              sendTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(minutes: 30),
            ),
          );
          if (resp.statusCode != 206) {
            throw StateError('服务器未按 Range 返回（${resp.statusCode}）');
          }
          final sink = File(partPath).openWrite();
          try {
            await for (final data in resp.data!.stream) {
              if (cancelToken?.isCancelled ?? false) {
                throw DioException.requestCancelled(
                  requestOptions: RequestOptions(path: url),
                  reason: '用户取消下载',
                );
              }
              sink.add(data);
              received[i] += data.length;
              report();
            }
          } finally {
            await sink.flush();
            await sink.close();
          }
        }());
      }
      await Future.wait(futures);

      // 顺序拼接
      final out = File(savePath).openWrite();
      try {
        for (final p in parts) {
          await out.addStream(p.openRead());
        }
      } finally {
        await out.flush();
        await out.close();
      }
      final size = await File(savePath).length();
      if (size != total) {
        throw StateError('合并后大小不符：$size != $total');
      }
      for (final p in parts) {
        try {
          await p.delete();
        } catch (_) {}
      }
      return true;
    } catch (e) {
      // 清理分片与半成品，交给单连接重试
      for (final p in parts) {
        try {
          if (await p.exists()) await p.delete();
        } catch (_) {}
      }
      try {
        final f = File(savePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// 调起系统安装器安装 APK，成功返回 null，失败返回错误信息
  static Future<String?> installApk(String path) async {
    final result = await OpenFilex.open(
      path,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type == ResultType.done) return null;
    debugPrint('调起安装失败: ${result.message}');
    return result.message;
  }
}

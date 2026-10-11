import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 远端版本信息（对应 Gitee/GitHub 仓库里的 update.json）
class AppUpdateInfo {
  final String versionName; // 版本名，如 1.0.1（仅展示用）
  final int versionCode; // 版本号，比本地大才算有更新
  final String giteeUrl; // APK 下载直链（Gitee，主链路）
  final String githubUrl; // APK 下载直链（GitHub，备用链路）
  final String changelog; // 更新日志
  final bool force; // 是否强制更新（true 时弹窗不可关闭，必须完成更新）

  const AppUpdateInfo({
    required this.versionName,
    required this.versionCode,
    required this.giteeUrl,
    required this.githubUrl,
    required this.changelog,
    this.force = false,
  });

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    return AppUpdateInfo(
      versionName: json['versionName']?.toString() ?? '',
      versionCode: int.tryParse(json['versionCode']?.toString() ?? '') ?? 0,
      giteeUrl: json['gitee']?.toString() ?? '',
      githubUrl: json['github']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
      force: json['force'] == true,
    );
  }

  /// 双链路下载地址列表（过滤空项）
  List<String> get downloadUrls =>
      [giteeUrl, githubUrl].where((u) => u.isNotEmpty).toList();
}

/// App 更新服务：请求版本信息 / 下载 APK / 调起系统安装器
/// 双链路策略：Gitee 为主（国内快），GitHub 兜底，按顺序尝试直到成功
class UpdateService {
  UpdateService._();

  /// Gitee 仓库 update.json raw 地址（主链路，国内快，默认分支 master）
  static const String _giteeJsonUrl =
      'https://gitee.com/Sunset_5277/such-music-update/raw/master/update.json';

  /// GitHub 仓库 update.json raw 地址（主链路，分支 main）
  static const String _githubJsonUrl =
      'https://raw.githubusercontent.com/sunset5277/such-music-update/main/update.json';

  /// 版本信息源，按顺序尝试（Gitee 为主国内快，GitHub 兜底）
  static const List<String> _updateJsonUrls = [_giteeJsonUrl, _githubJsonUrl];

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

  /// 下载 APK：依次尝试多个直链，任一成功即返回保存路径
  /// 用户主动取消时直接抛出，不再尝试下一个链接
  /// [onRouteChanged] 在每次切换下载源时回调线路名称（Gitee 主线路 / GitHub 备用线路）
  static Future<String> downloadApk(
    List<String> urls, {
    void Function(int received, int total)? onProgress,
    void Function(String route)? onRouteChanged,
    CancelToken? cancelToken,
  }) async {
    Object? lastError;
    for (final url in urls.where((u) => u.isNotEmpty)) {
      try {
        onRouteChanged?.call(
          url.contains('gitee.com') ? 'Gitee 主线路' : 'GitHub 备用线路',
        );
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

  /// 从单个直链下载 APK 到缓存目录
  static Future<String> _downloadOne(
    String url, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final dir = await getTemporaryDirectory();
    final savePath = '${dir.path}/such_music_update.apk';
    final old = File(savePath);
    if (await old.exists()) await old.delete();
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

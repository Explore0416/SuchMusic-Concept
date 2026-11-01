import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../models/song_model.dart';
import 'sources/source_manager.dart';

/// 下载结果。
class DownloadResult {
  const DownloadResult({required this.ok, required this.message, this.path});

  final bool ok;
  final String message;
  final String? path;
}

/// 歌曲离线下载。
///
/// 只做「把当前能播的音频落盘」：地址沿用播放同一条取址链路
/// （[SourceManager] + 严格模式），因此能播的歌就能下，不会出现
/// 「能听不能下」的两套判定。
///
/// 落盘位置优先公共 `Music/SuchMusic/`（用户用文件管理器能直接看到），
/// 没有存储写权限时回退到 App 自己的外部目录，并在提示里说明。
class SongDownloadService {
  SongDownloadService._();

  static final SongDownloadService instance = SongDownloadService._();

  static const _publicDir = '/storage/emulated/0/Music/SuchMusic';
  static const _subDirName = 'SuchMusic';

  final _dio = Dio();

  /// 正在下载的歌曲 id：同一首重复点不重复下载。
  final _running = <String>{};

  bool isDownloading(String songId) => _running.contains(songId);

  Future<DownloadResult> download(
    SongModel song, {
    void Function(double progress)? onProgress,
  }) async {
    if (song.source.isLocal) {
      return const DownloadResult(ok: false, message: '本地文件已经在手机里了');
    }
    if (_running.contains(song.id)) {
      return const DownloadResult(ok: false, message: '这首歌正在下载');
    }

    _running.add(song.id);
    try {
      final url = await SourceManager().withFallback<String>(
        song,
        (src, s, strict) => src.getSongUrl(s, strict: strict),
      );
      if (url == null || url.isEmpty) {
        return const DownloadResult(ok: false, message: '拿不到下载地址，可能版权受限或需要登录');
      }

      final dir = await _resolveDir();
      if (dir == null) {
        return const DownloadResult(ok: false, message: '没有可写入的目录');
      }

      final file = File('${dir.path}/${_fileNameOf(song, url)}');
      if (await file.exists() && await file.length() > 64 * 1024) {
        return DownloadResult(
          ok: true,
          message: '这首歌之前已经下过了：${_displayPath(file)}',
          path: file.path,
        );
      }

      await _dio.download(
        url,
        file.path,
        options: Options(
          headers: const {
            // 网易 CDN 不带 Referer 会返回错误页而不是音频
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
          },
          receiveTimeout: const Duration(minutes: 3),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0) onProgress?.call(received / total);
        },
      );

      if (!await file.exists() || await file.length() < 32 * 1024) {
        await _safeDelete(file);
        return const DownloadResult(ok: false, message: '下载到的内容不是音频，已删除');
      }

      return DownloadResult(
        ok: true,
        message: '已保存到 ${_displayPath(file)}',
        path: file.path,
      );
    } catch (e) {
      return DownloadResult(ok: false, message: '下载失败：$e');
    } finally {
      _running.remove(song.id);
    }
  }

  /// 优先公共音乐目录，失败回退 App 外部目录。
  Future<Directory?> _resolveDir() async {
    try {
      final pub = Directory(_publicDir);
      if (!await pub.exists()) await pub.create(recursive: true);
      // 真写一次探针，避免「能建目录但写不进文件」的 ROM 差异
      final probe = File('${pub.path}/.probe');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return pub;
    } catch (_) {
      // 没有「所有文件访问」权限时会走到这里
    }
    try {
      final base =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/$_subDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  String _displayPath(File f) {
    final p = f.path;
    if (p.startsWith('/storage/emulated/0/')) {
      return p.substring('/storage/emulated/0/'.length);
    }
    return p;
  }

  /// `歌手 - 歌名.ext`：文件名只保留一层，避免路径穿越与非法字符。
  String _fileNameOf(SongModel song, String url) {
    final raw = song.artist.isEmpty
        ? song.name
        : '${song.artist} - ${song.name}';
    final safe = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final ext = _extOf(url);
    final base = safe.isEmpty ? '未命名' : safe;
    return '$base.$ext';
  }

  String _extOf(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in const ['flac', 'mp3', 'm4a', 'aac', 'wav', 'ogg']) {
      if (path.endsWith('.$ext')) return ext;
    }
    return 'mp3';
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉就留着，不影响主流程
    }
  }
}

import 'package:flutter/services.dart';

import '../models/song_model.dart';

/// 本地音乐扫描结果。
class LocalScanResult {
  const LocalScanResult({
    required this.tracks,
    required this.audioPermission,
    required this.allFilesAccess,
  });

  final List<LocalTrack> tracks;

  /// 是否已授予音频读取权限（未授予时列表为空）。
  final bool audioPermission;

  /// 是否已授予「所有文件访问权限」——决定能否扫描 `.kgm/.kgma/.vpr`。
  final bool allFilesAccess;

  static const empty = LocalScanResult(
    tracks: <LocalTrack>[],
    audioPermission: false,
    allFilesAccess: false,
  );

  int get kgmCount => tracks.where((t) => t.isKgm).length;
}

/// 一条本地曲目（普通音频或加密格式）。
class LocalTrack {
  const LocalTrack({
    required this.uri,
    this.path,
    required this.name,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.size,
    required this.ext,
    required this.kind,
  });

  /// 播放用 Uri（`content://` 或 `file://`）。
  final String uri;

  /// 真实文件路径（仅文件系统扫描到的条目有；KGM 解码必需）。
  final String? path;

  final String name;
  final String artist;
  final String album;
  final int durationMs;
  final int size;

  /// 扩展名（小写，不含点）。
  final String ext;

  /// `media`（系统音频库）/ `file`（目录中的普通音频）/ `kgm`（加密格式）。
  final String kind;

  bool get isKgm => kind == 'kgm';

  /// 稳定标识（同一文件在列表里的唯一键）。
  String get id => uri;

  /// 展示用格式标签：KGM 单独标注，其余显示大写扩展名。
  String get formatLabel => ext.isEmpty ? '音频' : ext.toUpperCase();

  String get durationLabel {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    final m = (total ~/ 60).toString().padLeft(2, '0');
    final s = (total % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 转成播放器可用的歌曲模型；[playUri] 允许用解码后的路径覆盖原始 Uri。
  SongModel toSongModel({String? playUri}) {
    return SongModel(
      id: 'local:${playUri ?? uri}',
      name: name.isEmpty ? '未命名' : name,
      artist: artist.isEmpty ? '未知艺人' : artist,
      album: album.isEmpty ? '本地文件' : album,
      duration: durationMs > 0 ? durationMs : null,
      source: SongSource.local,
      localUri: playUri ?? uri,
    );
  }

  factory LocalTrack.fromMap(Map<dynamic, dynamic> m) {
    return LocalTrack(
      uri: m['uri']?.toString() ?? '',
      path: m['path']?.toString(),
      name: m['name']?.toString() ?? '未命名',
      artist: m['artist']?.toString() ?? '未知艺人',
      album: m['album']?.toString() ?? '',
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      size: (m['size'] as num?)?.toInt() ?? 0,
      ext: (m['ext']?.toString() ?? '').toLowerCase(),
      kind: m['kind']?.toString() ?? 'file',
    );
  }
}

/// 本地音乐扫描（调用 Android 侧 MediaStore + 目录遍历）。
///
/// 全流程本地进行：不联网、不上传任何文件信息。
class LocalMusicService {
  LocalMusicService._();

  static final LocalMusicService instance = LocalMusicService._();

  static const MethodChannel _channel =
      MethodChannel('com.lightningteam.suchmusic/local_music');

  /// 扫描本地音乐。无音频权限时会先由原生侧发起授权请求，授权后自动继续。
  Future<LocalScanResult> scan() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('scan');
      if (raw == null) return LocalScanResult.empty;
      final list = (raw['tracks'] as List?)
              ?.whereType<Map<dynamic, dynamic>>()
              .map(LocalTrack.fromMap)
              .where((t) => t.uri.isNotEmpty)
              .toList() ??
          <LocalTrack>[];
      return LocalScanResult(
        tracks: list,
        audioPermission: raw['audioPermission'] == true,
        allFilesAccess: raw['allFilesAccess'] == true,
      );
    } on PlatformException {
      return LocalScanResult.empty;
    } on MissingPluginException {
      return LocalScanResult.empty;
    }
  }

  Future<bool> hasAudioPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasAudioPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 跳系统「所有文件访问权限」页；用户返回后由页面重新扫描。
  Future<bool> openAllFilesSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAllFilesSettings') ?? false;
    } catch (_) {
      return false;
    }
  }
}

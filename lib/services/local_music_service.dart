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

/// 元数据占位值判定。
///
/// 原生 MediaStore 对无标签文件返回 `<unknown>`；部分设备返回 `unknown` / `null`。
/// 这些都不应直接展示给用户。
bool isUnknownMeta(String? v) {
  if (v == null) return true;
  final t = v.trim();
  if (t.isEmpty) return true;
  final low = t.toLowerCase();
  return low == '<unknown>' ||
      low == 'unknown' ||
      low == 'null' ||
      low == 'n/a' ||
      t == '本地文件' ||
      t == '未知艺人' ||
      t == '未知歌手';
}

/// 去掉文件名末尾扩展名（`.kgm` / `.mp3` 等）。
String stripAudioExtension(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0) return name;
  final ext = name.substring(i + 1).toLowerCase();
  const known = {
    'mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'wma',
    'kgm', 'kgma', 'vpr', 'ape', 'dsf',
  };
  return known.contains(ext) ? name.substring(0, i) : name;
}

/// 从「歌手 - 歌名」形式的文件名拆出歌手与歌名。
///
/// 只认两侧带空格的连接符（` - ` / ` – ` / ` — `），避免误拆 `Jay-Z`、`AC-DC` 之类的名字。
({String artist, String title}) splitArtistTitle(String raw) {
  final name = stripAudioExtension(raw).trim();
  for (final sep in const [' - ', ' – ', ' — ', ' － ']) {
    final i = name.indexOf(sep);
    if (i > 0 && i + sep.length < name.length) {
      return (
        artist: name.substring(0, i).trim(),
        title: name.substring(i + sep.length).trim(),
      );
    }
  }
  return (artist: '', title: name);
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

  /// 展示用格式标签：加密格式固定标 KGM（以**源文件**为准，不随解密结果变化）。
  String get formatLabel {
    // 加密格式显示**源文件后缀**（KGM / KGMA / VPR / KGG），
    // 不要显示解密产物的格式，否则用户会以为文件类型被改了。
    if (isKgm) return ext.isEmpty ? '加密' : ext.toUpperCase();
    return ext.isEmpty ? '音频' : ext.toUpperCase();
  }

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
      artist: artist.isEmpty ? '未知歌手' : artist,
      album: album.isEmpty ? '本地文件' : album,
      duration: durationMs > 0 ? durationMs : null,
      source: SongSource.local,
      localUri: playUri ?? uri,
    );
  }

  factory LocalTrack.fromMap(Map<dynamic, dynamic> m) {
    final rawName = stripAudioExtension(m['name']?.toString() ?? '');
    final rawArtist = isUnknownMeta(m['artist']?.toString())
        ? ''
        : m['artist']!.toString().trim();
    final parsed = splitArtistTitle(rawName);
    final displayName = parsed.title.isEmpty ? rawName : parsed.title;
    return LocalTrack(
      uri: m['uri']?.toString() ?? '',
      path: m['path']?.toString(),
      name: displayName.isEmpty ? '未命名' : displayName,
      artist: rawArtist.isNotEmpty ? rawArtist : parsed.artist,
      album: isUnknownMeta(m['album']?.toString())
          ? ''
          : m['album']!.toString().trim(),
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

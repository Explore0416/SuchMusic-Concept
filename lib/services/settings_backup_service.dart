import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/song_model.dart';
import '../utils/app_constants.dart';
import 'audio_player_service.dart';
import 'local_lyric_service.dart';
import 'play_history_service.dart';

/// 设置一键导出 / 导入（单例）：把「设置项 + 播放队列 + 本地偏好数据」
/// 打包成一个 JSON 文件，便于换机、重装后恢复。
///
/// ── 导出内容 ─────────────────────────────────────────────────
/// - `settings`：5 个设置开关 / 音源选择（`allowMixWithOthers`、
///   `notify_lyric_enabled`、`miui_island_enabled`、`music_source`、
///   `kugou_fallback_enabled`）。
/// - `playlist`：当前播放队列（SongModel 列表 JSON）。
/// - `playHistory`：[PlayHistoryService] 快照（本机播放偏好统计）。
/// - `localLyrics`：[LocalLyricService] 快照（用户手动指定的歌词）。
///
/// ── **绝不导出登录凭证** ────────────────────────────────────
/// 备份文件是**明文 JSON**，用户会保存到网盘、微信、相册等不受控位置。
/// 一旦混入 token / userid（`kugou_token`、`kugou_userid`、`kugou_mid`、
/// `kugou_guid`、`kugou_dfid` 等），就等同于把账号凭据交给任何拿到该文件的
/// 人，且无法撤回（酷狗凭证不会因改密码失效）。因此本服务**只枚举白名单
/// 里的 5 个设置 key**，不遍历 SharedPreferences 全量导出，从源头上杜绝
/// 凭证外泄；导入同理只写回这 5 个 key。
///
/// ── 错误处理（约定，二选一已定）───────────────────────────────
/// [importFromJson] 在 **format / version 校验失败**时抛 [FormatException]
/// （让 UI 明确提示「不是有效的备份文件」）；文件内部单段数据损坏则跳过
/// 该段、不计入恢复数，不中断整体导入。其它 IO 异常一律 try/catch 兜底。
class SettingsBackupService {
  static final SettingsBackupService _instance =
      SettingsBackupService._internal();
  factory SettingsBackupService() => _instance;
  SettingsBackupService._internal();

  /// 备份格式标识（导入时校验）。
  static const String formatTag = 'suchmusic-settings-backup';

  /// 备份结构版本（导入时校验，版本不符拒绝）。
  static const int formatVersion = 1;

  /// 允许导出 / 导入的设置 key 白名单（**不含任何登录凭证**）。
  static const List<String> _boolSettingKeys = <String>[
    AppConstants.allowMixWithOthers,
    AppConstants.notifyLyricEnabled,
    AppConstants.miuiIslandEnabled,
    AppConstants.kugouFallbackEnabled,
  ];

  static const List<String> _stringSettingKeys = <String>[
    AppConstants.musicSource,
  ];

  /// 导出为 JSON 文本（缩进 2 空格，便于人肉查看与分享）。
  Future<String> exportToJson() async {
    final prefs = await _prefs();
    final settings = <String, dynamic>{};
    for (final key in _boolSettingKeys) {
      final v = prefs?.getBool(key);
      if (v != null) settings[key] = v;
    }
    for (final key in _stringSettingKeys) {
      final v = prefs?.getString(key);
      if (v != null) settings[key] = v;
    }

    final data = <String, dynamic>{
      'format': formatTag,
      'version': formatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': settings,
      'playlist': AudioPlayerService()
          .playlist
          .map(_encodeSong)
          .toList(growable: false),
      'playHistory': PlayHistoryService().snapshot(),
      'localLyrics': LocalLyricService().snapshot(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// 从 JSON 文本恢复；返回成功恢复的**项目数**（最多 4：设置 / 队列 /
  /// 播放历史 / 手动歌词，每有一项实际生效计 1）。
  ///
  /// 抛出：
  /// - [FormatException] —— 非 JSON、或 format / version 不符。
  /// - 其它 IO 异常内部兜底，不抛给 UI。
  Future<int> importFromJson(String json) async {
    Object? decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      throw const FormatException('不是有效的 JSON 文件');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件结构不正确（应为 JSON 对象）');
    }
    if (decoded['format'] != formatTag) {
      throw FormatException('不是 SuchMusic 设置备份文件：${decoded['format']}');
    }
    final version = decoded['version'];
    if (version is! int || version != formatVersion) {
      throw FormatException('备份文件版本不受支持：$version');
    }

    var restored = 0;

    // 1) 设置项（仅白名单 5 个 key，绝不写任何凭证字段）
    final prefs = await _prefs();
    if (prefs != null) {
      final settings = decoded['settings'];
      var settingsRestored = false;
      if (settings is Map) {
        for (final entry in settings.entries) {
          final key = entry.key.toString();
          final value = entry.value;
          if (_boolSettingKeys.contains(key) && value is bool) {
            await prefs.setBool(key, value);
            settingsRestored = true;
            if (key == AppConstants.allowMixWithOthers) {
              // 「与其他应用同时播放」立即生效，无需重启
              await AudioPlayerService.applyMixWithOthers(value);
            }
          } else if (_stringSettingKeys.contains(key) && value is String) {
            await prefs.setString(key, value);
            settingsRestored = true;
          }
        }
      }
      if (settingsRestored) restored += 1;
    }

    // 2) 播放队列：经公开 API 重建（clearPlaylist 会停止当前播放，
    //    再按原顺序 addToPlaylist，**不自动开始播放**）
    final songs = _decodeSongs(decoded['playlist']);
    if (songs.isNotEmpty) {
      try {
        await AudioPlayerService().clearPlaylist();
        for (final song in songs.reversed) {
          AudioPlayerService().addToPlaylist(song);
        }
        restored += 1;
      } catch (_) {}
    }

    // 3) 播放历史 + 4) 手动歌词
    if (await PlayHistoryService().restore(decoded['playHistory']) > 0) {
      restored += 1;
    }
    if (await LocalLyricService().restore(decoded['localLyrics']) > 0) {
      restored += 1;
    }

    return restored;
  }

  /// 默认导出文件名，形如 `SuchMusic设置备份-20261014-2130.json`。
  Future<String> defaultExportFileName() async =>
      'SuchMusic设置备份-${_stamp(DateTime.now())}.json';

  /// yyyyMMdd-HHmm
  static String _stamp(DateTime t) {
    String p(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${p(t.month)}${p(t.day)}-${p(t.hour)}${p(t.minute)}';
  }

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }
}

// ── SongModel 编解码（本文件私有）──────────────────────────────
//
// 同 play_history_service：在 `SongModel.toJson()` 之上补 `localUri`，
// 保证本地音乐（`SongSource.local`）导入后仍能播放。

Map<String, dynamic> _encodeSong(SongModel song) => <String, dynamic>{
      ...song.toJson(),
      'localUri': song.localUri,
    };

List<SongModel> _decodeSongs(Object? raw) {
  if (raw is! List) return const <SongModel>[];
  final result = <SongModel>[];
  for (final item in raw) {
    if (item is! Map<String, dynamic>) continue;
    final id = item['id']?.toString();
    if (id == null || id.isEmpty) continue;
    result.add(
      SongModel(
        id: id,
        name: item['name']?.toString() ?? '',
        artist: item['artist']?.toString() ?? '',
        album: item['album']?.toString() ?? '',
        coverUrl: item['coverUrl']?.toString(),
        duration: item['duration'] is int
            ? item['duration'] as int
            : int.tryParse(item['duration'].toString()),
        source: SongSource.fromCode(item['source']?.toString()),
        hash: item['hash']?.toString(),
        albumId: item['albumId']?.toString(),
        albumAudioId: item['albumAudioId']?.toString(),
        localUri: item['localUri']?.toString(),
      ),
    );
  }
  return result;
}

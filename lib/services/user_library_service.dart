import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/song_model.dart';

/// 用户自建歌单。
class UserPlaylist {
  const UserPlaylist({
    required this.id,
    required this.name,
    required this.createdAtMs,
    required this.songs,
  });

  final String id;
  final String name;
  final int createdAtMs;
  final List<SongModel> songs;

  UserPlaylist copyWith({String? name, List<SongModel>? songs}) => UserPlaylist(
        id: id,
        name: name ?? this.name,
        createdAtMs: createdAtMs,
        songs: songs ?? this.songs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAtMs': createdAtMs,
        'songs': songs.map((s) => s.toJson()).toList(),
      };

  static UserPlaylist fromJson(Map<String, dynamic> json) => UserPlaylist(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '未命名歌单',
        createdAtMs: (json['createdAtMs'] as num?)?.toInt() ?? 0,
        songs: ((json['songs'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => SongModel.fromStorage(Map<String, dynamic>.from(m)))
            .toList(),
      );
}

/// 本机「我的音乐库」：点赞歌曲 + 自建歌单。
///
/// **全部数据仅存本机**（SharedPreferences JSON），不上传、不参与云同步。
/// 点赞与自建歌单放在同一个服务里，避免两套几乎相同的持久化逻辑。
class UserLibraryService {
  UserLibraryService._();
  static final UserLibraryService instance = UserLibraryService._();

  static const String _kLiked = 'user_liked_songs';
  static const String _kPlaylists = 'user_playlists';

  /// 内容版本号：UI 监听它刷新（点赞 / 建单 / 增删歌都会 +1）。
  final ValueNotifier<int> version = ValueNotifier<int>(0);

  List<SongModel> _liked = <SongModel>[];
  List<UserPlaylist> _playlists = <UserPlaylist>[];
  bool _ready = false;

  List<SongModel> get likedSongs => List<SongModel>.unmodifiable(_liked);
  List<UserPlaylist> get playlists => List<UserPlaylist>.unmodifiable(_playlists);
  bool get ready => _ready;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final likedRaw = prefs.getString(_kLiked);
      if (likedRaw != null && likedRaw.isNotEmpty) {
        final list = jsonDecode(likedRaw);
        if (list is List) {
          _liked = list
              .whereType<Map>()
              .map((m) => SongModel.fromStorage(Map<String, dynamic>.from(m)))
              .toList();
        }
      }
      final plRaw = prefs.getString(_kPlaylists);
      if (plRaw != null && plRaw.isNotEmpty) {
        final list = jsonDecode(plRaw);
        if (list is List) {
          _playlists = list
              .whereType<Map>()
              .map((m) => UserPlaylist.fromJson(Map<String, dynamic>.from(m)))
              .toList();
        }
      }
    } catch (e) {
      debugPrint('⚠️ 读取我的音乐库失败: $e');
    }
    version.value++;
  }

  bool isLiked(String songId) => _liked.any((s) => s.id == songId);

  /// 切换点赞，返回切换**之后**是否处于已赞状态。
  Future<bool> toggleLike(SongModel song) async {
    final idx = _liked.indexWhere((s) => s.id == song.id);
    final likedNow = idx < 0;
    if (likedNow) {
      _liked.insert(0, song); // 最近点赞排在最前
    } else {
      _liked.removeAt(idx);
    }
    await _saveLiked();
    version.value++;
    return likedNow;
  }

  Future<UserPlaylist> createPlaylist(String name) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final p = UserPlaylist(
      id: 'up_$now',
      name: name.trim().isEmpty ? '新建歌单' : name.trim(),
      createdAtMs: now,
      songs: const <SongModel>[],
    );
    _playlists.insert(0, p);
    await _savePlaylists();
    version.value++;
    return p;
  }

  Future<void> deletePlaylist(String id) async {
    _playlists.removeWhere((p) => p.id == id);
    await _savePlaylists();
    version.value++;
  }

  Future<void> renamePlaylist(String id, String name) async {
    final i = _playlists.indexWhere((p) => p.id == id);
    if (i < 0) return;
    _playlists[i] = _playlists[i].copyWith(
      name: name.trim().isEmpty ? _playlists[i].name : name.trim(),
    );
    await _savePlaylists();
    version.value++;
  }

  /// 批量加入歌单，返回**实际新增**的条数（已存在的会跳过）。
  Future<int> addSongsToPlaylist(String playlistId, List<SongModel> songs) async {
    final i = _playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return 0;
    final existing = _playlists[i].songs.map((s) => s.id).toSet();
    final add = songs.where((s) => existing.add(s.id)).toList();
    if (add.isEmpty) return 0;
    _playlists[i] = _playlists[i].copyWith(
      songs: [..._playlists[i].songs, ...add],
    );
    await _savePlaylists();
    version.value++;
    return add.length;
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    final i = _playlists.indexWhere((p) => p.id == playlistId);
    if (i < 0) return;
    _playlists[i] = _playlists[i].copyWith(
      songs: _playlists[i].songs.where((s) => s.id != songId).toList(),
    );
    await _savePlaylists();
    version.value++;
  }

  /// 清空（设置页「清理数据」调用）。点赞与自建歌单一起清。
  Future<void> clearAll() async {
    _liked = <SongModel>[];
    _playlists = <UserPlaylist>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kLiked);
      await prefs.remove(_kPlaylists);
    } catch (_) {}
    version.value++;
  }

  Future<void> _saveLiked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kLiked,
        jsonEncode(_liked.map((s) => s.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('⚠️ 保存点赞失败: $e');
    }
  }

  Future<void> _savePlaylists() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kPlaylists,
        jsonEncode(_playlists.map((p) => p.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('⚠️ 保存歌单失败: $e');
    }
  }
}

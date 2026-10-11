import 'package:netease_music_api/netease_music_api.dart';

/// 音源标识（ARCH §4.2）。
///
/// [code] 用于持久化，[label] 用于 UI 展示。
enum SongSource {
  netease('netease', '网易云'),
  kugou('kugou', '酷狗概念版');

  const SongSource(this.code, this.label);

  final String code;
  final String label;

  /// 旧数据（无 source 键）默认网易云，保证向后兼容
  static SongSource fromCode(String? code) => SongSource.values.firstWhere(
        (e) => e.code == code,
        orElse: () => SongSource.netease,
      );
}

class SongModel {
  final String id;
  final String name;
  final String artist;
  final String album;
  final String? coverUrl;
  final int? duration;

  /// 音源归属（新增，默认网易云 → 旧调用点零改动）
  final SongSource source;

  /// 酷狗 hash（新增）
  final String? hash;

  /// 酷狗 album_id（新增）
  final String? albumId;

  /// 酷狗 album_audio_id（新增）
  final String? albumAudioId;

  const SongModel({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    this.coverUrl,
    this.duration,
    this.source = SongSource.netease,
    this.hash,
    this.albumId,
    this.albumAudioId,
  });

  /// 从库的 Song 类型创建
  factory SongModel.fromNeteaseSong(Song song) {
    final artistNames = song.artists
            ?.map((a) => a.name ?? '')
            .where((n) => n.isNotEmpty)
            .join(' / ') ??
        '';

    return SongModel(
      id: song.id,
      name: song.name ?? '',
      artist: artistNames,
      album: song.album?.name ?? '',
      coverUrl: song.album?.picUrl,
      duration: song.duration,
    );
  }

  /// 从每日推荐接口的 Song2 类型创建
  factory SongModel.fromSong2(Song2 song) {
    final artistNames = song.ar
            ?.map((a) => a.name ?? '')
            .where((n) => n.isNotEmpty)
            .join(' / ') ??
        '';

    return SongModel(
      id: song.id,
      name: song.name ?? '',
      artist: artistNames,
      album: song.al.name ?? '',
      coverUrl: song.al.picUrl,
      duration: song.dt,
    );
  }

  /// 从酷狗接口返回的条目创建（兼容 complexsearch v2 与 mobilecdn 两种字段命名）
  factory SongModel.fromKugouJson(Map<String, dynamic> json) {
    String pick(List<String> keys) {
      for (final k in keys) {
        final v = json[k];
        if (v != null && v.toString().trim().isNotEmpty) return v.toString().trim();
      }
      return '';
    }

    final hash = pick(['hash', 'Hash', 'FileHash', 'filehash']);
    var name = pick(['songname', 'SongName', 'song_name', 'name']);
    var singer = pick(['singername', 'SingerName', 'singer', 'author_name']);
    final album = pick(['album_name', 'AlbumName', 'albumname']);
    final albumId = pick(['album_id', 'AlbumID', 'albumid']);
    final albumAudioId = pick([
      'album_audio_id',
      'EMixSongID',
      'AudioId',
      'audio_id',
      'mixsongid',
    ]);

    // 部分兜底接口只给 filename「歌手 - 歌名」，此处拆解
    if (name.isEmpty || singer.isEmpty) {
      final filename = pick(['filename', 'FileName']);
      if (filename.contains(' - ')) {
        final parts = filename.split(' - ');
        if (singer.isEmpty) singer = parts.first.trim();
        if (name.isEmpty) {
          name = parts.sublist(1).join(' - ').trim();
          // 去掉 filename 结尾的 .mp3/.flac 等扩展名
          final dot = name.lastIndexOf('.');
          if (dot > 0) name = name.substring(0, dot);
        }
      }
    }

    // 时长：complexsearch 给毫秒（timelength），mobilecdn 给秒（duration）
    int? duration;
    final timelength = json['timelength'] ?? json['Timelength'];
    final durationRaw = json['duration'] ?? json['Duration'];
    if (timelength is int && timelength > 0) {
      duration = timelength;
    } else if (durationRaw is int && durationRaw > 0) {
      duration = durationRaw > 10000 ? durationRaw : durationRaw * 1000;
    } else if (durationRaw is String) {
      final n = int.tryParse(durationRaw);
      if (n != null && n > 0) duration = n > 10000 ? n : n * 1000;
    }

    // 封面：酷狗常见 imgurl / Image / union_cover，占位符 {size} 替换为 480
    var cover = pick(['imgurl', 'Image', 'image', 'union_cover', 'cover']);
    if (cover.isNotEmpty) cover = cover.replaceAll('{size}', '480');

    final id = albumAudioId.isNotEmpty
        ? albumAudioId
        : (hash.isNotEmpty ? hash : name);

    return SongModel(
      id: id,
      name: name,
      artist: singer,
      album: album,
      coverUrl: cover.isEmpty ? null : cover,
      duration: duration,
      source: SongSource.kugou,
      hash: hash.isEmpty ? null : hash,
      albumId: albumId.isEmpty ? null : albumId,
      albumAudioId: albumAudioId.isEmpty ? null : albumAudioId,
    );
  }

  /// 创建副本并覆盖字段
  SongModel copyWith({
    String? id,
    String? name,
    String? artist,
    String? album,
    String? coverUrl,
    int? duration,
    SongSource? source,
    String? hash,
    String? albumId,
    String? albumAudioId,
  }) {
    return SongModel(
      id: id ?? this.id,
      name: name ?? this.name,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      coverUrl: coverUrl ?? this.coverUrl,
      duration: duration ?? this.duration,
      source: source ?? this.source,
      hash: hash ?? this.hash,
      albumId: albumId ?? this.albumId,
      albumAudioId: albumAudioId ?? this.albumAudioId,
    );
  }

  /// 从原始 JSON 创建（兼容旧接口）
  factory SongModel.fromJson(Map<String, dynamic> json) {
    final artists = json['ar'] as List<dynamic>? ?? [];
    final artistNames = artists
        .map((a) => (a as Map<String, dynamic>)['name'] as String? ?? '')
        .join(' / ');

    return SongModel(
      id: (json['id'] as dynamic).toString(),
      name: json['name'] as String? ?? '',
      artist: artistNames,
      album: (json['al'] as Map<String, dynamic>?)?['name'] as String? ?? '',
      coverUrl: (json['al'] as Map<String, dynamic>?)?['picUrl'] as String?,
      duration: json['dt'] as int?,
    );
  }

  String get durationText {
    if (duration == null) return '';
    final totalSeconds = duration! ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'artist': artist,
      'album': album,
      'coverUrl': coverUrl,
      'duration': duration,
      'source': source.code,
      'hash': hash,
      'albumId': albumId,
      'albumAudioId': albumAudioId,
    };
  }

  /// 从本地存储反序列化：旧 playlist.json 无 `source` 键 → 默认网易云（无迁移脚本）
  factory SongModel.fromStorage(Map<String, dynamic> json) {
    return SongModel(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      coverUrl: json['coverUrl'] as String?,
      duration: json['duration'] as int?,
      source: SongSource.fromCode(json['source'] as String?),
      hash: json['hash'] as String?,
      albumId: json['albumId'] as String?,
      albumAudioId: json['albumAudioId'] as String?,
    );
  }
}

class PlaylistModel {
  final String id;
  final String name;
  final String? coverUrl;
  final String? description;
  final int? trackCount;
  final String? creatorName;
  final int? playCount;

  const PlaylistModel({
    required this.id,
    required this.name,
    this.coverUrl,
    this.description,
    this.trackCount,
    this.creatorName,
    this.playCount,
  });

  factory PlaylistModel.fromNeteaseTopList(TopList topList) {
    return PlaylistModel(
      id: topList.id,
      name: topList.name ?? '',
      coverUrl: topList.coverImgUrl,
      description: topList.description,
      trackCount: topList.trackCount,
      playCount: topList.playCount,
    );
  }

  factory PlaylistModel.fromNeteasePlay(Play play) {
    return PlaylistModel(
      id: play.id,
      name: play.name ?? '',
      coverUrl: play.coverImgUrl,
      description: play.description,
      trackCount: play.trackCount,
      creatorName: play.creator?.nickname,
      playCount: play.playCount,
    );
  }
}

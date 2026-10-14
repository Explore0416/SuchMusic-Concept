import 'package:netease_music_api/netease_music_api.dart';

import 'kugou_platform.dart';

/// 音源标识（ARCH §4.2）。
///
/// [code] 用于持久化，[label] 用于 UI 展示。
enum SongSource {
  netease('netease', '网易云'),
  kugouStandard('kugou_std', '酷狗音乐'),
  kugou('kugou', '酷狗概念版'),
  local('local', '本地音乐');

  const SongSource(this.code, this.label);

  /// 是否本地文件（不参与在线音源切换、不请求任何接口）
  bool get isLocal => this == local;

  /// 可在「设置 → 音源」中切换的在线音源（本地音乐不在其中）。
  static List<SongSource> get selectable =>
      values.where((e) => e != local).toList();

  final String code;
  final String label;

  /// 是否属于酷狗家族（概念版 / 原版）——用于「是否走酷狗接口」的语义判断。
  bool get isKugou => this == kugou || this == kugouStandard;

  /// 对应的酷狗平台变体（非酷狗音源返回 null）。
  KugouPlatform? get kugouPlatform => switch (this) {
        SongSource.kugou => KugouPlatform.lite,
        SongSource.kugouStandard => KugouPlatform.standard,
        _ => null,
      };

  /// 旧数据（无 source 键）默认网易云，保证向后兼容
  static SongSource fromCode(String? code) => SongSource.values.firstWhere(
        (e) => e.code == code,
        orElse: () => SongSource.netease,
      );

  /// 由酷狗平台变体反查音源标识。
  static SongSource fromKugouPlatform(KugouPlatform platform) =>
      platform == KugouPlatform.lite ? SongSource.kugou : SongSource.kugouStandard;
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

  /// 本地音频 Uri（仅 [SongSource.local] 有值；形如 `content://...` 或 `file://...`）。
  ///
  /// 非空时播放器直接用该 Uri 播放，**不请求任何在线接口**。
  final String? localUri;

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
    this.localUri,
  });

  /// 用系统「打开方式」/分享进来的本地音频构造歌曲。
  ///
  /// [displayName] 为原生侧解析出的文件名（形如 `xxx.mp3`），用于展示歌名；
  /// 去掉扩展名后作为歌名，无法解析时使用「本地音乐」兜底。
  factory SongModel.fromLocalUri(
    String uri, {
    String? displayName,
  }) {
    var title = (displayName ?? '').trim();
    if (title.isEmpty) {
      title = Uri.tryParse(uri)?.pathSegments.isNotEmpty == true
          ? Uri.parse(uri).pathSegments.last
          : '本地音乐';
    }
    // 去掉常见音频扩展名，展示更干净
    title = title.replaceAll(
      RegExp(r'\.(mp3|flac|wav|aac|m4a|ogg|opus)$', caseSensitive: false),
      '',
    );
    return SongModel(
      id: 'local:$uri',
      name: title.isEmpty ? '本地音乐' : title,
      artist: '本地音乐',
      album: '本地文件',
      source: SongSource.local,
      localUri: uri,
    );
  }

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

  /// 从酷狗接口返回的条目创建（兼容 complexsearch v2 与 mobilecdn 两种字段命名）。
  ///
  /// ── 实测字段映射（2024 对 `complexsearch.kugou.com/v2/search/song` 真实响应
  /// keyword=「晴天 周杰伦」dump 全字段核对，共 106 键；**大小写敏感**）──
  /// - 歌名：[SongName]（=`晴天`）；备用 [FileName]（=`周杰伦 - 晴天`，按
  ///   `"歌手 - 歌名"` 拆解，缺 [SongName] 时兜底）。
  /// - 歌手：[SingerName]（=`周杰伦`）。另有 `Singers`（对象数组），暂不使用。
  /// - hash：[FileHash]（=`B3A52A7A958BF0AED0EBFBA2E9A818B7`）。注意尚有
  ///   `HQFileHash`/`SQFileHash`/`ResFileHash` 等**其它音质**的 hash，勿误取。
  /// - 专辑：**[AlbumName]**（=`叶惠美`）——✅ 真实响应**存在**该字段，
  ///   此前「响应无专辑字段」的判断有误。（`AlbumImage` 恒为空串。）
  /// - 专辑 id：[AlbumID]（=`966846`）。
  /// - album_audio_id：[MixSongID]（=`32100650`，注意大小写）；备选
  ///   [Audioid]（=`20505418`）。旧代码只认 `EMixSongID`/`AudioId` 等
  ///   **大小写不同**的键，导致恒为 null（已修正）。
  /// - 时长：[Duration]（=`269`）**单位秒** → 经下方逻辑 ×1000 = 269000ms。
  ///   （complexsearch v2 实测**不含** `timelength` 键，仅 `Duration` 秒值。）
  /// - 封面：[Image]（=`http://imge.kugou.com/.../{size}/...jpg`，占位符
  ///   `{size}` → 480）；另有嵌套 `trans_param.union_cover`（同图，作兜底）。
  factory SongModel.fromKugouJson(Map<String, dynamic> json,
      {SongSource source = SongSource.kugou}) {
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
    // 实测含 [AlbumName]；保留旧接口小写候选以兼容 mobilecdn 等
    final album = pick(['album_name', 'AlbumName', 'albumname']);
    final albumId = pick(['album_id', 'AlbumID', 'albumid']);
    // album_audio_id：优先级按真实字段名排序（大小写敏感，`MixSongID` 居前）
    final albumAudioId = pick([
      'album_audio_id',
      'EMixSongID',
      'MixSongID', // 实测 complexsearch v2：= 32100650
      'Audioid', // 实测 complexsearch v2：= 20505418（备用）
      'AudioId',
      'audio_id',
      'mixsongid',
      'MixSongId',
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

    // 时长：complexsearch v2 实测给 [Duration] **秒**（=269）；旧 mobilecdn
    // 给 `duration` 秒。个别接口给毫秒 `timelength`，故保留毫秒直取分支。
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

    // 封面：实测主字段 [Image]（占位符 `{size}` → 480）；`AlbumImage` 恒空；
    // 嵌套 `trans_param.union_cover` 作末位兜底；其余为旧接口候选。
    var cover = pick(['imgurl', 'Image', 'image', 'union_cover', 'cover']);
    if (cover.isEmpty) {
      final transParam = json['trans_param'];
      if (transParam is Map && transParam['union_cover'] != null) {
        final uc = transParam['union_cover'].toString().trim();
        if (uc.isNotEmpty) cover = uc;
      }
    }
    if (cover.isNotEmpty) cover = cover.replaceAll('{size}', '480');

    // id：**优先 hash**（酷狗内唯一且短），而非 album_audio_id。
    // 理由：`hash` 是酷狗取源/去重的稳定标识；album_audio_id（MixSongID）在
    // 本轮修复前恒为空 → 历史上入库的酷狗曲目 id 均为 hash。若改为优先
    // albumAudioId，会与既有 `playlist.json` 中 id=hash 的旧条目不一致，
    // 触发 AudioPlayerService 去重（`s.id == song.id`）失效 → 重复入列。
    // 故保持 hash 优先以向后兼容；hash 缺失时再退化用 albumAudioId / name。
    final id = hash.isNotEmpty
        ? hash
        : (albumAudioId.isNotEmpty ? albumAudioId : name);

    return SongModel(
      id: id,
      name: name,
      artist: singer,
      album: album,
      coverUrl: cover.isEmpty ? null : cover,
      duration: duration,
      source: source,
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

  /// 音源归属（默认网易云 → 旧调用点零改动）
  final SongSource source;

  const PlaylistModel({
    required this.id,
    required this.name,
    this.coverUrl,
    this.description,
    this.trackCount,
    this.creatorName,
    this.playCount,
    this.source = SongSource.netease,
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

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import '../models/song_model.dart';
import 'audio_player_service.dart';
import 'island_service.dart';
import 'notification_lyric_service.dart';

/// 构造媒体项。
///
/// [subtitle] 为当前歌词行（非空时写入副标题 `artist` 字段，全 Android 生效）；
/// 为空时回退「歌手 - 专辑」。
MediaItem _songToMediaItem(SongModel song,
    {String? filePath, String? subtitle}) {
  Uri? artUri;
  if (filePath != null) {
    artUri = Uri.file(filePath);
  } else {
    var coverUrl = song.coverUrl;
    if (coverUrl != null && coverUrl.startsWith('http://')) {
      coverUrl = coverUrl.replaceFirst('http://', 'https://');
    }
    if (coverUrl != null && coverUrl.isNotEmpty) {
      try {
        artUri = Uri.parse(coverUrl);
      } catch (_) {
        artUri = null;
      }
    }
  }

  final hasSubtitle = subtitle != null && subtitle.isNotEmpty;
  final String artistText;
  if (hasSubtitle) {
    artistText = subtitle;
  } else if (song.artist.isNotEmpty) {
    artistText = song.album.isNotEmpty ? '${song.artist} - ${song.album}' : song.artist;
  } else {
    artistText = song.album;
  }

  final duration = song.duration;
  return MediaItem(
    id: song.id,
    album: song.album,
    title: song.name,
    artist: artistText,
    duration: duration != null ? Duration(milliseconds: duration) : null,
    artUri: artUri,
  );
}

class AudioPlayerHandler extends BaseAudioHandler {
  final AudioPlayerService _service = AudioPlayerService();
  final NotificationLyricService _lyricService =
      NotificationLyricService.instance;

  /// 当前副标题（歌词行）；空串表示回退歌手-专辑
  String _subtitle = '';

  AudioPlayerHandler() {
    _service.onStateChanged.listen(_onStateChanged);
    _service.onPositionChanged.listen(_onPositionChanged);
    _service.onDurationChanged.listen(_onDurationChanged);
    _service.onCurrentSongChanged.listen(_onCurrentSongChanged);
    _service.onPlaylistChanged.listen(_onPlaylistChanged);
    _service.onFmModeChanged.listen((_) => _emitPlaybackState());

    // 歌词行（仅在文本变化时发射）→ 去抖/节流 → 副标题流
    _service.onLyricChanged.listen(_lyricService.feed);
    _lyricService.onSubtitleChanged.listen(_onSubtitleChanged);

    _emitCurrentState();
  }

  void _emitCurrentState() {
    final song = _service.currentSong;
    if (song != null) {
      mediaItem.add(_songToMediaItem(song, subtitle: _subtitle));
    }
    final playlist = _service.playlist;
    if (playlist.isNotEmpty) {
      queue.add(playlist.map(_songToMediaItem).toList());
    }
    _emitPlaybackState();
  }

  void _emitPlaybackState() {
    final controls = _buildControls();
    final state = PlaybackState(
      controls: controls,
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices:
          controls.length >= 3 ? [0, 1, 2] : List.generate(controls.length, (i) => i),
      processingState: _toAudioProcessingState(_service.state),
      playing: _service.isPlaying,
      updatePosition: _service.position,
      bufferedPosition: Duration.zero,
      speed: 1.0,
    );
    debugPrint(
        '[AudioPlayerHandler] emitPlaybackState: playing=${_service.isPlaying}, state=${_service.state}, controls=${controls.map((c) => c.label).toList()}');
    playbackState.add(state);
  }

  void _onStateChanged(PlayerState state) {
    _emitPlaybackState();
  }

  void _onPositionChanged(Duration position) {
    playbackState.add(playbackState.value.copyWith(
      updatePosition: position,
    ));
  }

  void _onDurationChanged(Duration duration) {
    if (mediaItem.value != null) {
      mediaItem.add(mediaItem.value!.copyWith(duration: duration));
    }
  }

  void _onCurrentSongChanged(SongModel? song) {
    if (song != null) {
      _subtitle = '';
      mediaItem.add(_songToMediaItem(song));
      _lyricService.reset();
      _updateMediaItemWithCover(song);
    } else {
      _subtitle = '';
      _lyricService.reset();
      IslandService.instance.clearFocus();
    }
    _emitPlaybackState();
  }

  /// 副标题流（歌词行）→ 更新 MediaItem.artist + 联动超级岛增强
  void _onSubtitleChanged(String line) {
    _subtitle = line;
    final song = _service.currentSong;
    if (song == null) return;
    final coverUrl = song.coverUrl;
    final filePath = (coverUrl != null && coverUrl.isNotEmpty)
        ? AudioPlayerService.coverFileUri(coverUrl)
        : null;
    mediaItem
        .add(_songToMediaItem(song, filePath: filePath, subtitle: _subtitle));
    _updateIsland(song);
  }

  /// 小米超级岛增强：开关开 + 能力支持 + 有歌词时注入，否则清除；失败静默
  void _updateIsland(SongModel song) {
    if (!_lyricService.enabled || _subtitle.isEmpty) {
      IslandService.instance.clearFocus();
      return;
    }
    IslandService.instance
        .applyFocus(title: song.name, content: _subtitle);
  }

  void _updateMediaItemWithCover(SongModel song) async {
    final coverUrl = song.coverUrl;
    if (coverUrl == null || coverUrl.isEmpty) return;
    await AudioPlayerService.preFetchCover(coverUrl);
    final filePath = AudioPlayerService.coverFileUri(coverUrl);
    if (filePath != null) {
      mediaItem
          .add(_songToMediaItem(song, filePath: filePath, subtitle: _subtitle));
    }
  }

  void _onPlaylistChanged(List<SongModel> playlist) {
    queue.add(playlist.map(_songToMediaItem).toList());
    _emitPlaybackState();
  }

  List<MediaControl> _buildControls() {
    final isFm = _service.isFmMode;
    final isPlaying = _service.isPlaying;

    final playPause = isPlaying ? MediaControl.pause : MediaControl.play;

    if (isFm) {
      return [playPause, MediaControl.skipToNext];
    }
    return [
      MediaControl.skipToPrevious,
      playPause,
      MediaControl.skipToNext,
    ];
  }

  AudioProcessingState _toAudioProcessingState(PlayerState state) {
    switch (state) {
      case PlayerState.idle:
        return AudioProcessingState.idle;
      case PlayerState.loading:
        return AudioProcessingState.buffering;
      case PlayerState.playing:
        return AudioProcessingState.ready;
      case PlayerState.paused:
        return AudioProcessingState.ready;
      case PlayerState.error:
        return AudioProcessingState.error;
    }
  }

  @override
  Future<void> play() => _service.resume();

  @override
  Future<void> pause() => _service.pause();

  @override
  Future<void> stop() async {
    await IslandService.instance.clearFocus();
    await _service.clearPlaylist();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _service.seek(position);

  @override
  Future<void> skipToNext() => _service.playNext();

  @override
  Future<void> skipToPrevious() => _service.playPrevious();
}

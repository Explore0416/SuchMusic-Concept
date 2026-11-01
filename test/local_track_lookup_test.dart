// 本地播放回查契约：歌曲 id 带 local: 前缀，扫描结果的键是裸 uri。
// 这条不变量一旦被改坏，表现是「点歌没反应、一首也放不出来」且没有任何提示，
// 所以用单测钉住，而不是靠肉眼点。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/local_music_service.dart';

LocalTrack _track({String uri = 'content://media/external/audio/media/42'}) {
  return LocalTrack(
    uri: uri,
    path: '/storage/emulated/0/Music/a.mp3',
    name: '东风破',
    artist: '周杰伦',
    album: '',
    durationMs: 300000,
    size: 1024,
    ext: 'mp3',
    kind: 'media',
  );
}

void main() {
  group('本地曲目回查', () {
    test('SongModel.id 带 local: 前缀，与扫描结果的裸 uri 键不同', () {
      final track = _track();
      final song = track.toSongModel();

      expect(track.id, startsWith('content://'));
      expect(song.id, startsWith('local:'));
      expect(song.id, isNot(track.id));
      expect(song.localUri, track.uri);
    });

    test('用 localUri 能查到原始条目（曾经用 song.id 查，永远落空）', () {
      final track = _track();
      final song = track.toSongModel();
      final tracks = {track.id: track};

      // 错误用法必须查不到，说明这不是「碰巧能过」
      expect(tracks[song.id], isNull);
      // 正确用法必须查到
      expect(findTrackFor(tracks, song), same(track));
    });

    test('解密后的曲目换了 uri，回查会落空——所以解密必须在播放前拿到 track', () {
      final track = LocalTrack(
        uri: 'file:///storage/emulated/0/kgmusic/a.kgm',
        path: '/storage/emulated/0/kgmusic/a.kgm',
        name: '以父之名',
        artist: '周杰伦',
        album: '',
        durationMs: 0,
        size: 2048,
        ext: 'kgm',
        kind: 'kgm',
      );
      final base = track.toSongModel();
      final decoded = base.copyWith(
        localUri: 'file:///data/user/0/app/cache/decoded.mp3',
      );
      final tracks = {track.id: track};

      // 解码产物是新 uri，回查原始条目要靠兜底分支
      expect(findTrackFor(tracks, decoded), isNull);
      // 播放本身仍然走解码后的 uri
      expect(decoded.localUri, 'file:///data/user/0/app/cache/decoded.mp3');
    });

    test('找不到对应条目时返回 null，由调用方给出失败提示', () {
      final song = _track(uri: 'file:///a.mp3').toSongModel();
      expect(findTrackFor(const {}, song), isNull);
    });

    test('本地歌曲一律标记为 local 音源，避免回退在线取址', () {
      final song = _track().toSongModel();
      expect(song.source, SongSource.local);
      expect(song.source.isLocal, isTrue);
    });
  });
}

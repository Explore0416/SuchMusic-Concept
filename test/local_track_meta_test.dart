import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/local_music_service.dart';

void main() {
  group('isUnknownMeta', () {
    test('MediaStore 的占位值都算未知', () {
      expect(isUnknownMeta('<unknown>'), isTrue);
      expect(isUnknownMeta('UNKNOWN'), isTrue);
      expect(isUnknownMeta('null'), isTrue);
      expect(isUnknownMeta(''), isTrue);
      expect(isUnknownMeta(null), isTrue);
      expect(isUnknownMeta('本地文件'), isTrue);
    });

    test('真实歌手名不算未知', () {
      expect(isUnknownMeta('周杰伦'), isFalse);
      expect(isUnknownMeta('Jay-Z'), isFalse);
    });
  });

  group('stripAudioExtension', () {
    test('去掉已知音频扩展名', () {
      expect(stripAudioExtension('周杰伦 - 东风破.kgm'), '周杰伦 - 东风破');
      expect(stripAudioExtension('song.FLAC'), 'song');
    });

    test('非音频扩展名保持不变', () {
      expect(stripAudioExtension('demo.v2'), 'demo.v2');
      expect(stripAudioExtension('noext'), 'noext');
    });
  });

  group('splitArtistTitle', () {
    test('按「 - 」拆歌手与歌名', () {
      final r = splitArtistTitle('周杰伦 - 东风破.kgm');
      expect(r.artist, '周杰伦');
      expect(r.title, '东风破');
    });

    test('支持全角/长破折号分隔', () {
      expect(splitArtistTitle('A – B').artist, 'A');
      expect(splitArtistTitle('A — B').title, 'B');
    });

    test('不误拆 Jay-Z 这类连字符名字', () {
      final r = splitArtistTitle('Jay-Z - 99 Problems');
      expect(r.artist, 'Jay-Z');
      expect(r.title, '99 Problems');
      expect(splitArtistTitle('Jay-Z').artist, '');
    });

    test('无分隔符时保留整名为歌名', () {
      final r = splitArtistTitle('东风破');
      expect(r.artist, '');
      expect(r.title, '东风破');
    });
  });

  group('LocalTrack.fromMap', () {
    test('<unknown> 歌手回落为未知歌手，并从文件名推出歌手', () {
      final t = LocalTrack.fromMap(<dynamic, dynamic>{
        'uri': 'content://1',
        'name': '周杰伦 - 东风破',
        'artist': '<unknown>',
        'album': '<unknown>',
      });
      expect(t.name, '东风破');
      expect(t.artist, '周杰伦');
      expect(t.album, '');
      expect(t.toSongModel().artist, '周杰伦');
    });

    test('完全无信息时展示未知歌手', () {
      final t = LocalTrack.fromMap(<dynamic, dynamic>{
        'uri': 'file:///a/b.kgm',
        'name': 'track01',
        'artist': '<unknown>',
      });
      expect(t.name, 'track01');
      expect(t.artist, '');
      expect(t.toSongModel().artist, '未知歌手');
      expect(t.toSongModel().name, 'track01');
    });

    test('已有真实标签时不被文件名覆盖', () {
      final t = LocalTrack.fromMap(<dynamic, dynamic>{
        'uri': 'content://2',
        'name': 'track02',
        'artist': '陈奕迅',
        'album': 'U87',
      });
      expect(t.artist, '陈奕迅');
      expect(t.album, 'U87');
    });
  });
}

// SongModel / SongSource 兼容性测试（ARCH §4.2 / §4.3）。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';

void main() {
  group('SongSource.fromCode 兼容性', () {
    test('null → netease（旧 playlist.json 无 source 键）', () {
      expect(SongSource.fromCode(null), SongSource.netease);
    });

    test('未知串 → netease（兜底，不抛异常）', () {
      expect(SongSource.fromCode(''), SongSource.netease);
      expect(SongSource.fromCode('qqmusic'), SongSource.netease);
      expect(SongSource.fromCode('KUGOU'), SongSource.netease); // 大小写敏感
    });

    test('已定义 code 精确匹配', () {
      expect(SongSource.fromCode('netease'), SongSource.netease);
      expect(SongSource.fromCode('kugou'), SongSource.kugou);
    });

    test('枚举 code/label 契约', () {
      expect(SongSource.netease.code, 'netease');
      expect(SongSource.kugou.code, 'kugou');
      expect(SongSource.kugou.label, '酷狗概念版');
    });
  });

  group('toJson / fromStorage 往返一致性', () {
    test('kugou 全字段往返无损', () {
      const s = SongModel(
        id: 'EMIX123',
        name: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        coverUrl: 'https://img/cover.jpg',
        duration: 269000,
        source: SongSource.kugou,
        hash: 'HASHABC',
        albumId: 'ALB1',
        albumAudioId: 'AAID1',
      );
      final json = s.toJson();
      expect(json['source'], 'kugou');
      expect(json['hash'], 'HASHABC');
      expect(json['albumId'], 'ALB1');
      expect(json['albumAudioId'], 'AAID1');

      final r = SongModel.fromStorage(json);
      expect(r.id, 'EMIX123');
      expect(r.name, '晴天');
      expect(r.artist, '周杰伦');
      expect(r.album, '叶惠美');
      expect(r.coverUrl, 'https://img/cover.jpg');
      expect(r.duration, 269000);
      expect(r.source, SongSource.kugou);
      expect(r.hash, 'HASHABC');
      expect(r.albumId, 'ALB1');
      expect(r.albumAudioId, 'AAID1');
    });

    test('netease 默认值往返（新增字段为 null）', () {
      const s = SongModel(id: '1', name: 'n', artist: 'a', album: 'b');
      final r = SongModel.fromStorage(s.toJson());
      expect(r.source, SongSource.netease);
      expect(r.hash, isNull);
      expect(r.albumId, isNull);
      expect(r.albumAudioId, isNull);
    });

    test('旧 playlist.json（无 source/hash 等键）→ 反序列化为 netease', () {
      final oldJson = <String, dynamic>{
        'id': '12345',
        'name': '老歌',
        'artist': '老歌手',
        'album': '老专辑',
        'coverUrl': null,
        'duration': 200000,
      };
      final r = SongModel.fromStorage(oldJson);
      expect(r.source, SongSource.netease);
      expect(r.hash, isNull);
      expect(r.albumId, isNull);
      expect(r.id, '12345');
    });

    test('fromStorage：缺 name/artist/album 键时取空串，不抛异常', () {
      final r = SongModel.fromStorage({'id': '9'});
      expect(r.name, '');
      expect(r.artist, '');
      expect(r.album, '');
      expect(r.source, SongSource.netease);
    });

    test('copyWith 可切换 source 及其它字段', () {
      const s = SongModel(id: '1', name: 'n', artist: 'a', album: 'b');
      final k = s.copyWith(source: SongSource.kugou, hash: 'H', albumId: 'A');
      expect(k.source, SongSource.kugou);
      expect(k.hash, 'H');
      expect(k.albumId, 'A');
      expect(k.id, '1');
    });
  });

  group('fromKugouJson 映射（兼容 complexsearch v2 / mobilecdn）', () {
    test('complexsearch 风格：毫秒 timelength + 大写字段', () {
      final s = SongModel.fromKugouJson({
        'Hash': 'H1',
        'SongName': '歌曲',
        'SingerName': '歌手',
        'AlbumName': '专辑',
        'AlbumID': 'A1',
        'EMixSongID': 'E1',
        'Timelength': 210000,
        'Image': 'http://img/{size}/x.jpg',
      });
      expect(s.source, SongSource.kugou);
      expect(s.hash, 'H1');
      expect(s.name, '歌曲');
      expect(s.artist, '歌手');
      expect(s.albumId, 'A1');
      expect(s.albumAudioId, 'E1');
      expect(s.duration, 210000); // 直接毫秒
      expect(s.coverUrl, 'http://img/480/x.jpg'); // {size} → 480
      expect(s.id, 'H1'); // 优先 hash（稳定标识，向后兼容旧 playlist）
    });

    test('complexsearch 主路径：真实字段名（大小写敏感）', () {
      // 照抄 2024 实测 `complexsearch.kugou.com/v2/search/song` 响应结构
      // （keyword=「晴天 周杰伦」首条）的关键字段名，防字段名再次踩坑。
      final s = SongModel.fromKugouJson({
        'SongName': '晴天',
        'FileName': '周杰伦 - 晴天',
        'SingerName': '周杰伦',
        'FileHash': 'B3A52A7A958BF0AED0EBFBA2E9A818B7',
        'Duration': 269, // 单位：秒
        'AlbumID': 966846, // int，非字符串
        'AlbumName': '叶惠美',
        'MixSongID': 32100650, // 注意大小写：MixSongID（非 EMixSongID/AudioId）
        'Audioid': 20505418, // 备份候选
        'ID': 32100650,
        'Scid': 20505418,
        'Image': 'http://imge.kugou.com/stdmusic/{size}/x.jpg',
        'AlbumImage': '', // 实测恒空
      });
      expect(s.source, SongSource.kugou);
      expect(s.name, '晴天');
      expect(s.artist, '周杰伦');
      expect(s.hash, 'B3A52A7A958BF0AED0EBFBA2E9A818B7');
      expect(s.album, '叶惠美'); // AlbumName 真实存在
      expect(s.albumId, '966846');
      expect(s.albumAudioId, '32100650'); // MixSongID（修复前恒 null）
      expect(s.duration, 269000); // 269 秒 → 毫秒
      expect(s.coverUrl, 'http://imge.kugou.com/stdmusic/480/x.jpg');
      expect(s.id, s.hash); // 稳定标识优先 hash
    });

    test('albumAudioId 优先级：MixSongID > Audioid，且兼容旧 EMixSongID', () {
      expect(
        SongModel.fromKugouJson({'FileHash': 'H', 'MixSongID': 111, 'Audioid': 222})
            .albumAudioId,
        '111',
      );
      // 仅剩 Audioid 时取 Audioid
      expect(
        SongModel.fromKugouJson({'FileHash': 'H', 'Audioid': 222}).albumAudioId,
        '222',
      );
      // 旧接口 EMixSongID 仍优先于 MixSongID
      expect(
        SongModel.fromKugouJson(
                {'FileHash': 'H', 'EMixSongID': 9, 'MixSongID': 111})
            .albumAudioId,
        '9',
      );
    });

    test('封面兜底：Image 缺失时取 trans_param.union_cover', () {
      final s = SongModel.fromKugouJson({
        'FileHash': 'H',
        'SongName': 's',
        'trans_param': {
          'union_cover': 'http://imge.kugou.com/u/{size}/y.jpg',
        },
      });
      expect(s.coverUrl, 'http://imge.kugou.com/u/480/y.jpg');
    });

    test('mobilecdn 风格：秒 duration → 转毫秒', () {
      final s = SongModel.fromKugouJson({
        'hash': 'h2',
        'songname': 's',
        'singername': 'a',
        'duration': 210,
      });
      expect(s.duration, 210000);
      expect(s.id, 'h2'); // 无 albumAudioId → 退化用 hash
    });

    test('duration 已是毫秒（>10000）不重复放大', () {
      final s = SongModel.fromKugouJson({'hash': 'h', 'duration': 210000});
      expect(s.duration, 210000);
    });

    test('filename「歌手 - 歌名.mp3」拆解 + 去扩展名', () {
      final s = SongModel.fromKugouJson({'hash': 'h', 'filename': '周杰伦 - 晴天.mp3'});
      expect(s.artist, '周杰伦');
      expect(s.name, '晴天');
    });

    test('name/artist 缺失且无 filename → 保持空（由 _mapSongs 过滤）', () {
      final s = SongModel.fromKugouJson({'hash': 'h'});
      expect(s.name, '');
      expect(s.artist, '');
      expect(s.id, 'h'); // 无 albumAudioId → hash
    });
  });

  group('durationText', () {
    test('毫秒格式化 mm:ss', () {
      expect(const SongModel(id: '1', name: 'n', artist: 'a', album: 'b', duration: 269000)
          .durationText, '04:29');
      expect(const SongModel(id: '1', name: 'n', artist: 'a', album: 'b', duration: 5000)
          .durationText, '00:05');
    });

    test('duration 为 null → 空串', () {
      expect(const SongModel(id: '1', name: 'n', artist: 'a', album: 'b')
          .durationText, '');
    });
  });
}

// 曲风推断服务单测（设计文档 §3 / §10.1）。
//
// 覆盖：关键词提取、置信度合成 conf = 1−Π(1−cᵢ)、S1/S2/S3/S4/S5 采集、
// 阈值过滤、优雅降级、快照往返。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/recommendation_profile.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/genre_metadata_service.dart';

SongModel _song(String id, String name, String artist) => SongModel(
      id: id,
      name: name,
      artist: artist,
      album: '',
    );

List<int> _zeros() => List<int>.filled(24, 0);

PlayStatV2 _entry(SongModel song, int lastPlayedAt) => PlayStatV2(
      song: song,
      count: 1,
      lastPlayedAt: lastPlayedAt,
      hourCounts: _zeros(),
      artistKey: normalizeArtist(song.artist),
    );

void main() {
  const cfg = RecommendationConfig.defaults;
  const nowMs = 1000000000000;

  setUp(() => GenreMetadataService().clear());
  tearDown(() => GenreMetadataService().clear());

  group('extractGenres() 关键词提取', () {
    test('命中已知曲风关键词', () {
      expect(extractGenres('中国风'), contains('中国风'));
      expect(extractGenres('华语流行'), contains('流行'));
      expect(extractGenres('古风歌单'), contains('中国风'));
      expect(extractGenres('Rock 摇滚'), contains('摇滚'));
    });

    test('无命中返回空（允许推断不出）', () {
      expect(extractGenres('周杰伦'), isEmpty);
      expect(extractGenres(''), isEmpty);
    });
  });

  group('置信度合成 conf = 1−Π(1−cᵢ)', () {
    test('两次 S3（0.4）叠加 → 1-(0.6)(0.6)=0.64', () {
      final song = _song('1', 'x', '周杰伦');
      GenreMetadataService().observeSearchKeyword(song, '中国风', nowMs: nowMs);
      expect(
        GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs)['中国风'],
        closeTo(0.4, 1e-9),
      );
      GenreMetadataService().observeSearchKeyword(song, '中国风', nowMs: nowMs);
      expect(
        GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs)['中国风'],
        closeTo(0.64, 1e-9),
      );
    });

    test('S1（1.0）与 S3（0.4）叠加 → 1.0', () {
      final song = _song('2', 'y', '周杰伦');
      GenreMetadataService().observePlaylistTags(song, ['中国风'], nowMs: nowMs);
      GenreMetadataService().observeSearchKeyword(song, '中国风', nowMs: nowMs);
      expect(
        GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs)['中国风'],
        closeTo(1.0, 1e-9),
      );
    });
  });

  group('S1/S2/S3 采集', () {
    test('S1 歌单来源标签', () {
      final song = _song('3', '东风破', '周杰伦');
      GenreMetadataService().observePlaylistTags(song, ['古风中国风'], nowMs: nowMs);
      final tags = GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs);
      expect(tags.containsKey('中国风'), true);
      expect(tags['中国风'], closeTo(1.0, 1e-9));
    });

    test('S2 官方分类字典匹配（本地匹配）', () {
      final target = _song('100', '东风破', '周杰伦');
      GenreMetadataService().refreshCategoryDictionary(
        categorySongs: <String, List<SongModel>>{
          '中国风': [_song('100', '东风破', '周杰伦')],
          '流行': [_song('999', '无关', '某人')],
        },
        history: [_entry(target, nowMs)],
        nowMs: nowMs,
      );
      final tags = GenreMetadataService().tagsFor(target, cfg, nowMs: nowMs);
      expect(tags['中国风'], closeTo(0.8, 1e-9));
    });

    test('S3 搜索关键词标签', () {
      final song = _song('4', 'x', '周杰伦');
      GenreMetadataService().observeSearchKeyword(song, '摇滚', nowMs: nowMs);
      expect(
        GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs)['摇滚'],
        closeTo(0.4, 1e-9),
      );
    });
  });

  group('S4 艺人聚合 / S5 共现传播', () {
    test('S4：同艺人无直接标签的曲目通过代理获得标签', () {
      final a = _song('a', '东风破', '周杰伦');
      GenreMetadataService().observePlaylistTags(a, ['中国风'], nowMs: nowMs);
      GenreMetadataService().rebuildFromHistory([_entry(a, nowMs)], cfg);
      expect(
        GenreMetadataService().artistIndex['周杰伦']?['中国风'],
        greaterThan(0.0),
      );
      final other = _song('z', '兰亭序', '周杰伦');
      final tags = GenreMetadataService().tagsFor(other, cfg, nowMs: nowMs);
      expect(tags.containsKey('中国风'), true);
    });

    test('S5：同一会话内互相传播标签', () {
      final a = _song('a', '东风破', '周杰伦');
      final b = _song('b', '青花瓷', '某人');
      GenreMetadataService().observePlaylistTags(a, ['中国风'], nowMs: nowMs);
      final entries = [
        _entry(a, nowMs),
        _entry(b, nowMs + 60 * 1000), // 间隔 1 分钟 ≤ 30 → 同会话
      ];
      GenreMetadataService().rebuildFromHistory(entries, cfg);
      final tagsB = GenreMetadataService().tagsFor(b, cfg, nowMs: nowMs + 60000);
      expect(tagsB.containsKey('中国风'), true);
    });

    test('S5：超过会话间隔不传播', () {
      final a = _song('a', '东风破', '周杰伦');
      final b = _song('b', '青花瓷', '某人');
      GenreMetadataService().observePlaylistTags(a, ['中国风'], nowMs: nowMs);
      final entries = [
        _entry(a, nowMs),
        _entry(b, nowMs + 2 * 60 * 60 * 1000), // 间隔 2 小时 > 30 → 不同会话
      ];
      GenreMetadataService().rebuildFromHistory(entries, cfg);
      final tagsB = GenreMetadataService().tagsFor(b, cfg, nowMs: nowMs);
      expect(tagsB.containsKey('中国风'), false);
    });
  });

  group('阈值过滤与优雅降级', () {
    test('conf < tagConfMin 的标签被剔除', () {
      final song = _song('9', 'x', '某人');
      GenreMetadataService().restore(
        <String, dynamic>{
          'tagIndex': {
            'netease:9': {'摇滚': 0.2},
          },
          'artistIndex': <String, dynamic>{},
        },
        savedAt: nowMs,
      );
      expect(GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs), isEmpty);
    });

    test('无任何推断 → tagsFor 返回空（触发降级）', () {
      final song = _song('10', 'x', '某人');
      expect(GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs), isEmpty);
    });

    test('每曲最多保留 3 个标签', () {
      final song = _song('11', 'x', '某人');
      for (final kw in ['中国风', '摇滚', '民谣', '爵士', '电子']) {
        final s = _song('11', 'x', '某人');
        GenreMetadataService().observeSearchKeyword(s, kw, nowMs: nowMs);
      }
      final stored = GenreMetadataService().tagIndex['netease:11'];
      expect(stored, isNotNull);
      expect(stored!.length, lessThanOrEqualTo(3));
      // song 变量仅为保持引用（避免未使用告警）
      expect(song.id, '11');
    });
  });

  group('快照往返', () {
    test('snapshot → clear → restore 后标签一致', () {
      final song = _song('12', 'x', '周杰伦');
      GenreMetadataService().observePlaylistTags(song, ['中国风'], nowMs: nowMs);
      final snap = GenreMetadataService().snapshot();

      GenreMetadataService().clear();
      expect(GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs), isEmpty);

      final n = GenreMetadataService().restore(snap, savedAt: nowMs);
      expect(n, greaterThan(0));
      expect(
        GenreMetadataService().tagsFor(song, cfg, nowMs: nowMs)['中国风'],
        closeTo(1.0, 1e-9),
      );
    });
  });
}

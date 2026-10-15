// 播放历史 v1 → v2 迁移 / 备份往返单测（设计文档 §7 / §10.1）。
//
// 关键断言：v1 的全部播放历史在迁移后**逐字段保留**（count/lastPlayedAt/
// hourCounts/song 不变），仅补默认字段；迁移幂等；备份导入兼容 v1 / v2。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/recommendation_profile.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/genre_metadata_service.dart';
import 'package:such_music/services/play_history_service.dart';

SongModel _song(String id, String name, String artist) => SongModel(
      id: id,
      name: name,
      artist: artist,
      album: '',
    );

List<int> _hours({Map<int, int> at = const {}}) {
  final list = List<int>.filled(24, 0);
  at.forEach((k, v) => list[k] = v);
  return list;
}

Map<String, dynamic> _v1Entry({
  required String id,
  required String name,
  required String artist,
  required int count,
  required int lastPlayedAt,
  required Map<int, int> hourAt,
}) =>
    <String, dynamic>{
      'song': <String, dynamic>{
        'id': id,
        'name': name,
        'artist': artist,
        'album': '专辑',
        'source': 'netease',
      },
      'count': count,
      'lastPlayedAt': lastPlayedAt,
      'hourCounts': _hours(at: hourAt),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('migrateFromV1() 逐字段保留 + 补默认值', () {
    final v1 = <String, dynamic>{
      'version': 1,
      'entries': [
        _v1Entry(
          id: '186016',
          name: '晴天',
          artist: '周杰伦 / 阿信',
          count: 12,
          lastPlayedAt: 1759990000000,
          hourAt: {8: 2, 19: 3},
        ),
      ],
    };

    test('count/lastPlayedAt/hourCounts/song 不变，新增字段为默认', () {
      final profile = LocalRecommendationProfile.migrateFromV1(v1);
      expect(profile.version, 2);
      expect(profile.entries.length, 1);
      final e = profile.entries.first;
      expect(e.count, 12);
      expect(e.lastPlayedAt, 1759990000000);
      expect(e.hourCounts.length, 24);
      expect(e.hourCounts[8], 2);
      expect(e.hourCounts[19], 3);
      expect(e.song.id, '186016');
      expect(e.song.name, '晴天');
      expect(e.song.artist, '周杰伦 / 阿信');
      // 新增字段默认值
      expect(e.completionSum, 0);
      expect(e.completionCount, 0);
      expect(e.skipCount, 0);
      expect(e.srcTags, isEmpty);
      // 派生字段：多艺人取首位
      expect(e.artistKey, '周杰伦');
      // 索引首启为空
      expect(profile.tagIndex, isEmpty);
      expect(profile.artistIndex, isEmpty);
    });

    test('幂等：再次迁移字段不变', () {
      final once = LocalRecommendationProfile.migrateFromV1(v1);
      final twice = LocalRecommendationProfile.migrateFromV1(once.toJson());
      expect(twice.entries.length, 1);
      expect(twice.entries.first.count, 12);
      expect(twice.entries.first.lastPlayedAt, 1759990000000);
      expect(twice.entries.first.hourCounts[8], 2);
      expect(twice.entries.first.artistKey, '周杰伦');
    });

    test('脏数据单条跳过而非整体失败；hourCounts 长度 <24 补零', () {
      final dirty = <String, dynamic>{
        'version': 1,
        'entries': [
          <String, dynamic>{'count': 3}, // 无 song → 跳过
          <String, dynamic>{
            'song': <String, dynamic>{'id': '2', 'name': 'x', 'artist': 'y', 'source': 'netease'},
            'count': 5,
            'lastPlayedAt': 1000,
            'hourCounts': <int>[1, 1, 1], // 长度 3 → 补零到 24
          },
        ],
      };
      final profile = LocalRecommendationProfile.migrateFromV1(dirty);
      expect(profile.entries.length, 1);
      expect(profile.entries.first.hourCounts.length, 24);
      expect(profile.entries.first.hourCounts[0], 1);
      expect(profile.entries.first.hourCounts[3], 0);
      expect(profile.entries.first.count, 5);
    });
  });

  group('fromJson 版本容错', () {
    test('未知 version 仍按 v2 结构容错解析', () {
      final json = <String, dynamic>{
        'version': 99,
        'entries': [
          _v1Entry(id: '7', name: 'n', artist: 'a', count: 2, lastPlayedAt: 5000, hourAt: {1: 1}),
        ],
        'tagIndex': <String, dynamic>{
          'netease:7': <String, dynamic>{'流行': 0.5},
        },
      };
      final p = LocalRecommendationProfile.fromJson(json);
      expect(p.version, 2);
      expect(p.entries.length, 1);
      expect(p.tagIndex['netease:7']?['流行'], closeTo(0.5, 1e-9));
    });
  });

  group('PlayHistoryService 落盘迁移 + 备份往返', () {
    setUp(() {
      GenreMetadataService().clear();
    });

    test('init() 读到 v1 → 迁移保留历史', () async {
      final v1 = <String, dynamic>{
        'version': 1,
        'entries': [
          _v1Entry(id: '186016', name: '晴天', artist: '周杰伦', count: 12, lastPlayedAt: 1759990000000, hourAt: {8: 2}),
        ],
      };
      SharedPreferences.setMockInitialValues(
          <String, Object>{PlayHistoryService.storageKey: jsonEncode(v1)});
      final svc = PlayHistoryService();
      await svc.init();
      expect(svc.count, 1);
      expect(svc.totalPlays, 12);
      expect(svc.entries.first.count, 12);
      expect(svc.entries.first.lastPlayedAt, 1759990000000);
      expect(svc.entries.first.hourOf(8), 2);
    });

    test('v2 snapshot → restore 往返：entries/tagIndex 一致', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final svc = PlayHistoryService();
      await svc.init();
      await svc.clear();

      await svc.record(_song('1', '晴天', '周杰伦'));
      await svc.record(_song('2', '红尘客栈', '周杰伦'));
      await svc.record(_song('2', '红尘客栈', '周杰伦'));
      GenreMetadataService().observePlaylistTags(
          _song('2', '红尘客栈', '周杰伦'), ['中国风'],
          nowMs: DateTime.now().millisecondsSinceEpoch);

      final snap = svc.snapshot();
      expect(snap['version'], 2);
      final entryCount = (snap['entries'] as List).length;
      expect(entryCount, 2);

      await svc.clear();
      expect(svc.count, 0);

      final n = await svc.restore(snap);
      expect(n, 2);
      expect(svc.totalPlays, 3);
      expect(svc.entries.firstWhere((e) => e.song.id == '2').count, 2);
      // 曲风档案随快照恢复
      expect(
        GenreMetadataService().tagsFor(_song('2', '红尘客栈', '周杰伦'),
            RecommendationConfig.defaults)['中国风'],
        isNotNull,
      );
    });

    test('restore 兼容 v1 导入', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final svc = PlayHistoryService();
      await svc.init();
      await svc.clear();

      final v1 = <String, dynamic>{
        'version': 1,
        'entries': [
          _v1Entry(id: '5', name: 'n', artist: 'a', count: 7, lastPlayedAt: 8000, hourAt: {2: 1}),
        ],
      };
      final n = await svc.restore(v1);
      expect(n, 1);
      expect(svc.entries.first.count, 7);
      expect(svc.entries.first.lastPlayedAt, 8000);
    });

    test('无历史 → suggest 返回空（冷启动不报错、不空态）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final svc = PlayHistoryService();
      await svc.init();
      await svc.clear();
      expect(svc.suggest(limit: 12), isEmpty);
    });

    test('有历史 → suggest 返回非空且不抛异常', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final svc = PlayHistoryService();
      await svc.init();
      await svc.clear();
      await svc.record(_song('1', '晴天', '周杰伦'));
      await svc.record(_song('2', '东风破', '周杰伦'));
      await svc.record(_song('3', '某歌', '某人'));
      final picks = svc.suggest(limit: 12);
      expect(picks, isNotEmpty);
      expect(picks.length, lessThanOrEqualTo(3));
    });
  });
}

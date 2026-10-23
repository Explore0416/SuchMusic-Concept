import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/recommend_service.dart';

SongModel song(String id, String name, String artist) => SongModel(
      id: id,
      name: name,
      artist: artist,
      album: '',
      source: SongSource.netease,
    );

void main() {
  group('mixPicks（本地偏好 + 在线新歌混排）', () {
    test('无新歌时原样返回本地结果', () {
      final local = [song('1', 'A', 'a'), song('2', 'B', 'b')];
      final out = RecommendService.mixPicks(local: local, fresh: const []);
      expect(out.map((s) => s.id), ['1', '2']);
    });

    test('无本地时直接返回新歌（冷启动）', () {
      final fresh = [song('9', 'X', 'x')];
      final out = RecommendService.mixPicks(local: const [], fresh: fresh);
      expect(out.single.id, '9');
    });

    test('已在本地的歌不会重复出现在新歌位（按 id 与歌名+歌手去重）', () {
      final local = [song('1', 'A', 'a')];
      final fresh = [
        song('1', 'A', 'a'), // 同 id
        song('99', 'A', 'a'), // 同歌名+歌手
        song('2', 'C', 'c'),
      ];
      final out = RecommendService.mixPicks(local: local, fresh: fresh, limit: 6);
      final ids = out.map((s) => s.id).toList();
      expect(ids.where((id) => id == '1').length, 1);
      expect(ids.contains('99'), isFalse);
      expect(ids.contains('2'), isTrue);
    });

    test('结果不超过 limit，且本地占多数', () {
      final local = List.generate(10, (i) => song('L$i', 'n$i', 'artist$i'));
      final fresh = List.generate(10, (i) => song('F$i', 'x$i', 'other$i'));
      final out = RecommendService.mixPicks(
        local: local,
        fresh: fresh,
        limit: 9,
        localRatio: 2,
        maxExplore: 2,
      );
      expect(out.length, 9);
      final localCount = out.where((s) => s.id.startsWith('L')).length;
      expect(localCount, greaterThan(out.length ~/ 2));
    });

    test('陌生艺人最多 2 首（避免整屏全是没听过的）', () {
      final local = [song('L0', 'n0', 'known')];
      final fresh = List.generate(
        8,
        (i) => song('F$i', 'x$i', 'stranger$i'),
      );
      final out = RecommendService.mixPicks(
        local: local,
        fresh: fresh,
        limit: 9,
        localRatio: 2,
        maxExplore: 2,
      );
      final strangers =
          out.where((s) => s.artist.startsWith('stranger')).length;
      expect(strangers, lessThanOrEqualTo(2));
    });

    test('熟悉艺人的新歌优先于陌生艺人', () {
      final local = [song('L0', 'n0', 'known')];
      final fresh = [
        song('F1', 'x1', 'stranger1'),
        song('F2', 'x2', 'known'),
      ];
      final out = RecommendService.mixPicks(local: local, fresh: fresh, limit: 5);
      final ids = out.map((s) => s.id).toList();
      expect(ids.indexOf('F2'), lessThan(ids.indexOf('F1')));
    });

    test('limit <= 0 返回空列表', () {
      expect(
        RecommendService.mixPicks(
          local: [song('1', 'A', 'a')],
          fresh: [song('2', 'B', 'b')],
          limit: 0,
        ),
        isEmpty,
      );
    });
  });
}

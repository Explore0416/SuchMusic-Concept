// 跨源歌曲匹配 pickBestMatch 单元测试（高-1 对端歌曲解析的核心逻辑）。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/sources/song_matcher.dart';

SongModel _song(String name, String artist) =>
    SongModel(id: name, name: name, artist: artist, album: '');

void main() {
  group('pickBestMatch', () {
    const target = SongModel(id: 'K', name: '晴天', artist: '周杰伦', album: '');

    test('歌名完全一致 + 歌手有交集 → 命中，且优先于仅同名者', () {
      final candidates = [
        _song('晴天', '未知歌手'), // 同名、歌手无交集（100）
        _song('晴天 (Live)', '周杰伦'), // 相关名、歌手交集（90）
        _song('晴天', '周杰伦'), // 同名 + 歌手交集（150）→ 最优
      ];
      final best = pickBestMatch(target, candidates);
      expect(best?.name, '晴天');
      expect(best?.artist, '周杰伦');
    });

    test('歌名完全一致（歌手无交集）仍视为匹配', () {
      final best = pickBestMatch(target, [_song('晴天', '别人')]);
      expect(best?.name, '晴天');
    });

    test('仅歌名相关（包含）且歌手无交集 → 不匹配', () {
      final best = pickBestMatch(target, [_song('晴天了', '别人')]);
      expect(best, isNull);
    });

    test('相关歌名 + 歌手交集 → 匹配', () {
      final best = pickBestMatch(target, [_song('晴天 (Live)', '周杰伦')]);
      expect(best?.name, '晴天 (Live)');
    });

    test('歌名无关 → 不匹配', () {
      final best = pickBestMatch(target, [_song('稻香', '周杰伦')]);
      expect(best, isNull);
    });

    test('多个歌手用分隔符拆分后做交集判断', () {
      final multi = SongModel(id: 'M', name: '歌', artist: 'A/B', album: '');
      final cand = [_song('歌', 'B & C')];
      expect(pickBestMatch(multi, cand)?.name, '歌');
    });

    test('目标歌名为空 → 直接返回 null', () {
      final empty = SongModel(id: 'E', name: '  ', artist: 'x', album: '');
      expect(pickBestMatch(empty, [_song('任何', '任何')]), isNull);
    });

    test('候选为空 → 返回 null', () {
      expect(pickBestMatch(target, const []), isNull);
    });
  });

  // ── 边界加固（第 2 轮）───────────────────────────────────────
  group('pickBestMatch 边界（确定行为）', () {
    const target = SongModel(id: 'K', name: '晴天', artist: '周杰伦', album: '');

    test('同名多结果（评分相同）→ 取第一个（非 null，顺序稳定）', () {
      final c1 = _song('晴天', '周杰伦');
      final c2 = SongModel(id: '2', name: '晴天', artist: '周杰伦', album: '');
      final best = pickBestMatch(target, [c1, c2]);
      expect(best, isNotNull);
      expect(identical(best, c1), isTrue, reason: '同分时保留首个候选');
    });

    test('歌名完全一致但歌手无交集 → 仍视为匹配（exact-name 优先，分=100）', () {
      final best = pickBestMatch(target, [_song('晴天', '林俊杰')]);
      expect(best?.artist, '林俊杰');
    });

    test('仅歌名包含（非完全一致）且歌手无交集 → 返回 null（分=40<90）', () {
      final best = pickBestMatch(target, [_song('晴天娃娃', '林俊杰')]);
      expect(best, isNull);
    });

    test('候选歌名含括号/Live 而歌手有交集 → 匹配（40+50=90）', () {
      final best = pickBestMatch(target, [_song('晴天【Live】', '周杰伦')]);
      expect(best?.name, '晴天【Live】');
    });

    test('候选歌名含 feat. 而歌手有交集 → 匹配', () {
      const t = SongModel(
          id: 'K', name: 'Faded', artist: 'Iselin Solheim', album: '');
      final best =
          pickBestMatch(t, [_song('Faded (feat. Iselin Solheim)', 'Iselin Solheim')]);
      expect(best, isNotNull);
    });

    test('候选歌名为空 → 跳过该候选', () {
      final best = pickBestMatch(target, [_song('', '周杰伦')]);
      expect(best, isNull);
    });
  });
}

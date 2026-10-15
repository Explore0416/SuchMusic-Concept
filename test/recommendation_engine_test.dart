// 「猜你想听」打分引擎单测（设计文档 §5 / §6 / §10.1）。
//
// 全部为**纯函数**测试：注入 now / 显式传入输入，无 IO、无时钟、确定性。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/recommendation_profile.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/recommendation_engine.dart';

SongModel _song(String id, String name, String artist) => SongModel(
      id: id,
      name: name,
      artist: artist,
      album: '',
    );

ProfileInputs _profile({
  int totalPlays = 100,
  Map<String, int>? artistPlays,
  Map<String, int>? artistLastDays,
  Map<String, int>? tagPlays,
  Map<String, int>? tagLastDays,
  Map<String, int>? hourArtistPlays,
  Map<String, int>? hourTagPlays,
  int nowHour = 1,
}) =>
    ProfileInputs(
      totalPlays: totalPlays,
      artistPlays: artistPlays ?? <String, int>{},
      artistLastDays: artistLastDays ?? <String, int>{},
      tagPlays: tagPlays ?? <String, int>{},
      tagLastDays: tagLastDays ?? <String, int>{},
      hourArtistPlays: hourArtistPlays ?? <String, int>{},
      hourTagPlays: hourTagPlays ?? <String, int>{},
      nowHour: nowHour,
    );

void main() {
  const cfg = RecommendationConfig.defaults;

  group('decay() 时间衰减', () {
    test('Δt<0 视为 0；Δt=H 恰为 0.5；单调递减', () {
      expect(decay(-5, 30), 1.0);
      expect(decay(0, 30), 1.0);
      expect(decay(30, 30), closeTo(0.5, 1e-9));
      expect(decay(60, 30), closeTo(0.25, 1e-9));
      expect(decay(10, 30), greaterThan(decay(20, 30)));
    });

    test('半衰期 ≤ 0 返回 0', () {
      expect(decay(1, 0), 0.0);
      expect(decay(1, -3), 0.0);
    });
  });

  group('logShare() 对数抑制', () {
    test('total=0 / x=0 → 0；单调递增', () {
      expect(logShare(5, 0), 0.0);
      expect(logShare(0, 100), 0.0);
      expect(logShare(10, 100), greaterThan(logShare(5, 100)));
      expect(logShare(100, 100), closeTo(1.0, 1e-9));
    });
  });

  group('§5.6 黄金算例：composeFinal 复现设计表数值', () {
    test('红尘客栈(周杰伦·中国风·深夜) = 0.782', () {
      final v = composeFinal(
        s: 0.60,
        a: 0.80,
        g: 0.75,
        t: 0.70,
        hasArtist: true,
        hasGenre: true,
        cfg: cfg,
      );
      expect(v, closeTo(0.782, 1e-9));
    });

    test('兰亭序 = 0.760', () {
      final v = composeFinal(
        s: 0.55,
        a: 0.80,
        g: 0.75,
        t: 0.68,
        hasArtist: true,
        hasGenre: true,
        cfg: cfg,
      );
      expect(v, closeTo(0.7598, 1e-9));
    });

    test('某热门流行(非周杰伦·非中国风·非深夜) = 0.359、且低于黄金曲目', () {
      final hot = composeFinal(
        s: 0.70,
        a: 0.30,
        g: 0.20,
        t: 0.20,
        hasArtist: true,
        hasGenre: true,
        cfg: cfg,
      );
      final golden = composeFinal(
        s: 0.60,
        a: 0.80,
        g: 0.75,
        t: 0.70,
        hasArtist: true,
        hasGenre: true,
        cfg: cfg,
      );
      expect(hot, closeTo(0.3592, 1e-9));
      expect(golden, greaterThan(hot));
    });
  });

  group('降级归一化（无曲风标签 → 剔除 wGenre 并重新归一化）', () {
    test('hasGenre=false 时结果与 g 取值无关，且按激活权重归一化', () {
      final withGenre = composeFinal(
        s: 0.7,
        a: 0.5,
        g: 0.9,
        t: 0.4,
        hasArtist: true,
        hasGenre: true,
        cfg: cfg,
      );
      final noGenreA = composeFinal(
        s: 0.7,
        a: 0.5,
        g: 0.0,
        t: 0.4,
        hasArtist: true,
        hasGenre: false,
        cfg: cfg,
      );
      final noGenreB = composeFinal(
        s: 0.7,
        a: 0.5,
        g: 0.9,
        t: 0.4,
        hasArtist: true,
        hasGenre: false,
        cfg: cfg,
      );
      expect(noGenreA, noGenreB);
      expect(noGenreA, isNot(closeTo(withGenre, 1e-9)));
      // active 权重和 0.9 → 0.7，比例 = fullW/activeW
      expect(noGenreA, closeTo(0.9 * (0.3 * 0.7 + 0.25 * 0.5 + 0.15 * 0.4) / 0.7, 1e-9));
    });

    test('无艺人历史时同时剔除 wArtist 与 wGenre', () {
      final v = composeFinal(
        s: 0.7,
        a: 0.9,
        g: 0.9,
        t: 0.4,
        hasArtist: false,
        hasGenre: false,
        cfg: cfg,
      );
      expect(v, closeTo(0.9 * (0.3 * 0.7 + 0.15 * 0.4) / (0.3 + 0.15), 1e-9));
    });
  });

  group('scoreSong() 多维综合排序', () {
    test('「周杰伦 × 中国风 × 深夜」显著高于普通热门', () {
      final profile = _profile(
        totalPlays: 100,
        artistPlays: {'周杰伦': 60, '某歌手': 40},
        artistLastDays: {'周杰伦': 0, '某歌手': 10},
        tagPlays: {'中国风': 50, '流行': 3},
        tagLastDays: {'中国风': 0, '流行': 5},
        hourArtistPlays: {'1|周杰伦': 40, '1|某歌手': 2},
        hourTagPlays: {'1|中国风': 35, '1|流行': 1},
        nowHour: 1,
      );

      final golden = SongFeatures(
        songId: 'hczk',
        artistKey: '周杰伦',
        name: '红尘客栈',
        count: 12,
        hourCountAtWindow: 8,
        hoursSinceLastPlay: 48,
        tags: {'中国风': 0.86},
        completion: 0.7,
        skipRate: 0.2,
      );
      final hot = SongFeatures(
        songId: 'pop',
        artistKey: '某歌手',
        name: '某热门流行',
        count: 30,
        hourCountAtWindow: 1,
        hoursSinceLastPlay: 12,
        tags: {'流行': 0.6},
        completion: 0.95,
        skipRate: 0.0,
      );

      final goldenScore =
          RecommendationEngine.scoreSong(s: golden, p: profile, cfg: cfg);
      final hotScore =
          RecommendationEngine.scoreSong(s: hot, p: profile, cfg: cfg);
      expect(goldenScore, greaterThan(hotScore));
      // 即便普通热门单曲分数更高，多维综合仍让黄金曲目胜出
      expect(songScore(hot, profile, cfg), greaterThan(songScore(golden, profile, cfg)));
    });
  });

  group('artistAffinity() 时间衰减生效', () {
    test('近期 vs 久远同频次 → 近期更高', () {
      final recent = _profile(
        artistPlays: {'a': 10},
        artistLastDays: {'a': 0},
      );
      final old = _profile(
        artistPlays: {'a': 10},
        artistLastDays: {'a': 120},
      );
      expect(
        artistAffinity(artistKey: 'a', p: recent, cfg: cfg),
        greaterThan(artistAffinity(artistKey: 'a', p: old, cfg: cfg)),
      );
      expect(artistAffinity(artistKey: 'missing', p: recent, cfg: cfg), 0.0);
    });
  });

  group('genreAffinity() 多标签加权与阈值', () {
    test('多标签加权求和；conf<tagConfMin 被忽略；无标签 → 0', () {
      final profile = _profile(
        tagPlays: {'中国风': 20, '流行': 5},
        tagLastDays: {'中国风': 0, '流行': 0},
      );
      final both = genreAffinity(
        tags: {'中国风': 0.9, '流行': 0.6},
        p: profile,
        cfg: cfg,
      );
      final onlyStrong = genreAffinity(tags: {'中国风': 0.9}, p: profile, cfg: cfg);
      expect(both, greaterThan(0.0));
      expect(onlyStrong, greaterThan(0.0));
      expect(
        genreAffinity(tags: {'流行': 0.6}, p: profile, cfg: cfg),
        lessThan(onlyStrong),
      );
      // 低于阈值 → 被忽略 → 0
      expect(genreAffinity(tags: {'中国风': 0.1}, p: profile, cfg: cfg), 0.0);
      expect(genreAffinity(tags: <String, double>{}, p: profile, cfg: cfg), 0.0);
    });
  });

  group('hourAffinity() 时段环形窗口', () {
    test('h=0 的窗口为 {22,23,0,1,2}', () {
      expect(hourWindowHours(0, 2), <int>[22, 23, 0, 1, 2]);
      expect(hourWindowHours(23, 1), <int>[22, 23, 0]);
    });

    test('深夜偏好曲目在深夜调用时 T 更高', () {
      final night = SongFeatures(
        songId: 'n',
        artistKey: 'a',
        name: 'n',
        count: 10,
        hourCountAtWindow: 8,
        hoursSinceLastPlay: 0,
        tags: const <String, double>{},
        completion: 0.5,
        skipRate: 0,
      );
      final day = SongFeatures(
        songId: 'd',
        artistKey: 'a',
        name: 'd',
        count: 10,
        hourCountAtWindow: 0,
        hoursSinceLastPlay: 0,
        tags: const <String, double>{},
        completion: 0.5,
        skipRate: 0,
      );
      final profile = _profile(nowHour: 1);
      expect(
        hourAffinity(s: night, nowHour: 1, p: profile, cfg: cfg),
        greaterThan(hourAffinity(s: day, nowHour: 1, p: profile, cfg: cfg)),
      );
    });
  });

  group('applyDiversityAndExplore() 多样性与探索', () {
    List<Scored> ranked(List<(String artist, double score)> items) {
      final out = <Scored>[];
      for (var i = 0; i < items.length; i++) {
        final (artist, score) = items[i];
        out.add(Scored(
          song: _song('s$i', '歌$i', artist),
          artistKey: artist,
          score: score,
          count: 10,
          tags: <String, double>{},
        ));
      }
      out.sort((a, b) => b.score.compareTo(a.score));
      return out;
    }

    test('单艺人封顶不超过 ceil(maxArtistShare·limit)', () {
      final items = <(String, double)>[
        for (var i = 0; i < 8; i++) ('A', 1.0 - i * 0.01),
        ('B', 0.5),
        ('C', 0.4),
        ('D', 0.3),
        ('E', 0.2),
      ];
      final result = applyDiversityAndExplore(
        ranked: ranked(items),
        limit: 12,
        cfg: cfg,
      );
      final cap = (cfg.maxArtistShare * 12).ceil(); // = 4
      final artistACount = result.where((s) => s.artistKey == 'A').length;
      expect(artistACount, lessThanOrEqualTo(cap));
      // 结果仍含其他艺人（多样性）
      expect(result.map((s) => s.artistKey).toSet().length, greaterThan(1));
    });

    test('去重：同 (artistKey,name) 只保留一条', () {
      final dup = <Scored>[
        Scored(song: _song('1', '同名', 'A'), artistKey: 'A', score: 0.9, count: 1, tags: <String, double>{}),
        Scored(song: songKeyDummy2(), artistKey: 'A', score: 0.8, count: 1, tags: <String, double>{}),
      ];
      final result = applyDiversityAndExplore(ranked: dup, limit: 10, cfg: cfg);
      expect(result.length, 1);
    });

    test('探索槽：至少保留 1 个非头部艺人条目', () {
      final items = <(String, double)>[
        for (var i = 0; i < 10; i++) ('A', 1.0 - i * 0.01),
        ('B', 0.2),
        ('C', 0.15),
      ];
      final result = applyDiversityAndExplore(
        ranked: ranked(items),
        limit: 6,
        cfg: cfg,
      );
      final top = result.first.artistKey;
      expect(result.where((s) => s.artistKey != top).length, greaterThanOrEqualTo(1));
    });
  });
}

/// 构造第二个「同名不同 id」的富对象（去重测试用，需同 name）。
SongModel songKeyDummy2() => SongModel(id: '2', name: '同名', artist: 'A', album: '');

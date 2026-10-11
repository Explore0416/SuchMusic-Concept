// SourceManager 路由 / 回退语义测试（ARCH §4.5）。
//
// 通过注入「假 run 回调 + 假对端解析器」验证回退的**路由行为**，
// 不触发任何真实网络请求。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/sources/source_manager.dart';

const _kugouSong = SongModel(
  id: 'KUGOU_ID',
  name: 'k',
  artist: 'a',
  album: 'b',
  source: SongSource.kugou,
  hash: 'HASH',
);

const _neteaseSong = SongModel(id: 'NETEASE_ID', name: 'n', artist: 'a', album: 'b');

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SourceManager().setFallbackEnabled(true);
  });

  tearDown(() async {
    await SourceManager().setFallbackEnabled(true);
  });

  group('sourceFor / currentSource', () {
    test('sourceFor 返回对应实现，默认音源为网易云', () {
      expect(SourceManager().sourceFor(SongSource.netease).kind,
          SongSource.netease);
      expect(SourceManager().sourceFor(SongSource.kugou).kind,
          SongSource.kugou);
      expect(SourceManager().currentSource, SongSource.netease);
    });
  });

  group('withFallback 回退语义', () {
    test('主音源(酷狗)返回 null → 用网易云重试，最终返回网易云结果', () async {
      final calls = <SongSource>[];
      final result = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async {
          calls.add(src.kind);
          return src.kind == SongSource.kugou ? null : 'http://ne/x.mp3';
        },
        resolve: (s) async => _neteaseSong,
      );
      expect(calls, [SongSource.kugou, SongSource.netease]);
      expect(result, 'http://ne/x.mp3');
    });

    test('空串 / 空集合 均视为失败并触发回退', () async {
      for (final empty in <Object>['', <String>[], <String, dynamic>{}]) {
        final calls = <SongSource>[];
        await SourceManager().withFallback<Object>(
          _kugouSong,
          (src, s, strict) async {
            calls.add(src.kind);
            return src.kind == SongSource.kugou ? empty : 'ok';
          },
          resolve: (s) async => _neteaseSong,
        );
        expect(calls, [SongSource.kugou, SongSource.netease], reason: '$empty');
      }
    });

    test('网易云为主音源时不跨音源回退（只调用一次）', () async {
      final calls = <SongSource>[];
      final r = await SourceManager().withFallback<String>(
          _neteaseSong, (src, s, strict) async {
        calls.add(src.kind);
        return null;
      });
      expect(calls, [SongSource.netease]);
      expect(r, isNull);
    });

    test('回退开关关闭时不重试', () async {
      await SourceManager().setFallbackEnabled(false);
      final calls = <SongSource>[];
      final r = await SourceManager().withFallback<String>(
          _kugouSong, (src, s, strict) async {
        calls.add(src.kind);
        return null;
      });
      expect(calls, [SongSource.kugou]);
      expect(r, isNull);
    });

    test('回退时广播「已回退网易云」提示', () async {
      final hints = <String>[];
      final sub = SourceManager().onFallbackHint.listen(hints.add);
      await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async => src.kind == SongSource.kugou ? null : 'ok',
        resolve: (s) async => _neteaseSong,
      );
      await Future<void>.delayed(Duration.zero);
      expect(hints, ['已回退网易云']);
      await sub.cancel();
    });

    // ── 修复验证（高-1）：回退前必须解析出对端歌曲，避免用酷狗 id 请求网易云 ──
    test('【修复验证】回退时网易云收到的是解析出的对端歌曲（非酷狗 id）', () async {
      final seen = <String>[];
      final url = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async {
          seen.add('${src.kind.code}:${s.id}');
          return src.kind == SongSource.kugou ? null : 'http://ne/${s.id}.mp3';
        },
        resolve: (s) async => _neteaseSong,
      );
      expect(seen, ['kugou:KUGOU_ID', 'netease:NETEASE_ID']);
      expect(url, 'http://ne/NETEASE_ID.mp3');
    });

    test('【修复验证】未能解析到对端歌曲 → 回退失败，不广播提示', () async {
      final hints = <String>[];
      final sub = SourceManager().onFallbackHint.listen(hints.add);
      var neteaseCalled = false;
      final r = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async {
          if (src.kind == SongSource.netease) neteaseCalled = true;
          return null;
        },
        resolve: (s) async => null, // 匹配不到对端
      );
      await Future<void>.delayed(Duration.zero);
      expect(r, isNull);
      expect(neteaseCalled, isFalse, reason: '无对端歌曲时不应再调网易云 run');
      expect(hints, isEmpty);
      await sub.cancel();
    });

    // ── 修复验证（高-2）：回退分支用 strict 判定真实成功与否 ──
    test('【修复验证】回退分支 strict 失败（含兜底 URL） → 回退失败，不误判成功', () async {
      final hints = <String>[];
      final sub = SourceManager().onFallbackHint.listen(hints.add);
      final r = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async {
          if (src.kind == SongSource.kugou) return null;
          // 回退分支必须以 strict=true 调用：strict 下只有真实地址才成功
          return strict ? null : 'http://ne/fallback.mp3';
        },
        resolve: (s) async => _neteaseSong,
      );
      await Future<void>.delayed(Duration.zero);
      expect(r, isNull, reason: 'strict 分支返回 null 即回退失败');
      expect(hints, isEmpty, reason: '回退失败不应广播成功提示');
      await sub.cancel();
    });

    test('【修复验证】主音源 strict=false；回退分支 strict=true', () async {
      final flags = <bool>[];
      await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async {
          flags.add(strict);
          return src.kind == SongSource.kugou ? null : 'ok';
        },
        resolve: (s) async => _neteaseSong,
      );
      expect(flags, [false, true]);
    });
  });

  // ── 边界加固（第 2 轮）：四条回退分支矩阵 ──────────────────────
  group('withFallback 四分支矩阵（注入假 resolver + 假 run）', () {
    test('分支A 主音源成功 → 仅调一次、(伪)对端调用 null、不广播回退', () async {
      final hints = <String>[];
      final calls = <SongSource>[];
      final sub = SourceManager().onFallbackHint.listen(hints.add);
      final r = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async {
          calls.add(src.kind);
          return 'http://kugou/ok.mp3';
        },
        resolve: (s) async => fail('主音源成功时不应调用 resolver'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(r, 'http://kugou/ok.mp3');
      expect(calls, [SongSource.kugou]);
      expect(hints, isEmpty);
      await sub.cancel();
    });

    test('分支B 主音源失败 + 对端解析成功 + 回退成功 → 返回回退结果并广播', () async {
      final hints = <String>[];
      final sub = SourceManager().onFallbackHint.listen(hints.add);
      final r = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async => src.kind == SongSource.kugou ? null : 'http://ne/ok.mp3',
        resolve: (s) async => _neteaseSong,
      );
      await Future<void>.delayed(Duration.zero);
      expect(r, 'http://ne/ok.mp3');
      expect(hints, ['已回退网易云']);
      await sub.cancel();
    });

    test('分支C 对端解析失败 → 返回主音源(空)结果，不再调用 run，不广播', () async {
      final hints = <String>[];
      final sub = SourceManager().onFallbackHint.listen(hints.add);
      var neteaseCalls = 0;
      final r = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async {
          if (src.kind == SongSource.netease) neteaseCalls++;
          return null;
        },
        resolve: (s) async => null,
      );
      await Future<void>.delayed(Duration.zero);
      expect(r, isNull, reason: '返回主音源空结果，语义为失败');
      expect(neteaseCalls, 0);
      expect(hints, isEmpty);
      await sub.cancel();
    });

    test('分支D 回退 strict 失败 → 返回主音源(空)结果，不误判成功、不广播', () async {
      final hints = <String>[];
      final sub = SourceManager().onFallbackHint.listen(hints.add);
      final r = await SourceManager().withFallback<String>(
        _kugouSong,
        (src, s, strict) async =>
            src.kind == SongSource.kugou ? null : (strict ? null : 'http://ne/must-not-use.mp3'),
        resolve: (s) async => _neteaseSong,
      );
      await Future<void>.delayed(Duration.zero);
      expect(r, isNull, reason: 'strict 下兜底 URL 不算成功');
      expect(hints, isEmpty);
      await sub.cancel();
    });
  });
}

// 四类数据 provider 单测（ARCHITECTURE §6.2 / §6.5）。
//
// 覆盖：曲风聚合（累加 → 归一化 → 前 10）、令牌未登录、
// 直链 SongModel 字段映射、代播动作路由。
// 全部依赖（tagIndex / 凭证 / 直链 / 播放器）通过构造参数注入，不触真实服务。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/kugou_platform.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/third_party/third_party_data_provider.dart';

/// 记录调用的播放端口替身。
class FakePlayback implements PlaybackPort {
  final List<String> actions = <String>[];
  final List<SongModel> played = <SongModel>[];

  @override
  Future<void> playSongs(List<SongModel> songs) async {
    actions.add('play');
    played.addAll(songs);
  }

  @override
  Future<void> pause() async => actions.add('pause');

  @override
  Future<void> resume() async => actions.add('resume');

  @override
  Future<void> next() async => actions.add('next');

  @override
  Future<void> previous() async => actions.add('previous');
}

void main() {
  const now = 1731600000;

  group('genre.read 曲风聚合', () {
    test('累加所有歌曲的 tag 权重 → 归一化 → 取前 10 且按权重降序', () async {
      // 12 个 tag，权重设计成「后者更小」；同一 tag 出现在两首歌里需要累加
      final tagIndex = <String, Map<String, double>>{
        'a#song-a': <String, double>{
          '流行': 3.0,
          '摇滚': 2.0,
          'tag03': 1.0,
        },
        'b#song-b': <String, double>{
          '流行': 1.0,
          'tag04': 0.9,
          'tag05': 0.8,
        },
        'c#song-c': <String, double>{
          for (var i = 6; i <= 12; i++) 'tag${i.toString().padLeft(2, '0')}': 0.7 - i * 0.01,
        },
      };

      final provider = ThirdPartyDataProvider(
        tagIndexSource: () => tagIndex,
        now: () => now,
      );

      final result = await provider.fetch(ThirdPartyScope.genreRead, null);
      final top = result['topGenres'] as List<Map<String, Object?>>;

      // 12 个 tag 只取前 10
      expect(top.length, 10);
      // 累加后「流行」= 4.0，权重最高
      expect(top.first['tag'], '流行');
      expect(top[1]['tag'], '摇滚');

      // 归一化按**全量**权重做（ARCH §6.2）：总量 12.97，「流行」= 4/12.97
      expect(top.first['weight'] as double, closeTo(4 / 12.97, 0.001));
      // 被截掉的两个尾巴（tag11=0.59 / tag12=0.58）不出现，故前 10 之和 < 1
      expect(top.map((e) => e['tag']), isNot(contains('tag11')));
      expect(top.map((e) => e['tag']), isNot(contains('tag12')));
      final sum = top.fold<double>(
        0,
        (acc, item) => acc + (item['weight'] as double),
      );
      expect(sum, closeTo(1 - (0.59 + 0.58) / 12.97, 0.005));
      // 降序
      for (var i = 1; i < top.length; i++) {
        final prev = top[i - 1]['weight'] as double;
        final cur = top[i]['weight'] as double;
        expect(prev, greaterThanOrEqualTo(cur));
      }
      expect(result['sampleSize'], 3);
      expect(result['updatedAt'], now);
    });

    test('空索引返回空列表且不抛异常', () async {
      final provider = ThirdPartyDataProvider(
        tagIndexSource: () => <String, Map<String, double>>{},
        now: () => now,
      );
      final result = await provider.fetch(ThirdPartyScope.genreRead, null);
      expect(result['topGenres'], isEmpty);
      expect(result['sampleSize'], 0);
    });

    test('权重为 0 / 空 tag 名不参与聚合', () async {
      final provider = ThirdPartyDataProvider(
        tagIndexSource: () => <String, Map<String, double>>{
          'a#x': <String, double>{'  ': 1.0, '流行': 2.0},
          'b#y': <String, double>{'电子': 0.0},
        },
        now: () => now,
      );
      final result = await provider.fetch(ThirdPartyScope.genreRead, null);
      final top = result['topGenres'] as List<Map<String, Object?>>;
      expect(top.length, 1);
      expect(top.first['tag'], '流行');
      expect(top.first['weight'], 1.0);
      expect(result['sampleSize'], 1);
    });
  });

  group('account.token', () {
    test('未登录 → not_logged_in', () async {
      final provider = ThirdPartyDataProvider(
        credentialSource: (KugouPlatform platform) =>
            (token: null, userId: null, nickname: null),
        now: () => now,
      );

      await expectLater(
        provider.fetch(ThirdPartyScope.accountToken, null),
        throwsA(
          isA<ThirdPartyException>()
              .having((e) => e.code, 'code', AuthErrors.notLoggedIn),
        ),
      );
    });

    test('token 存在但 userId 缺失也算未登录', () async {
      final provider = ThirdPartyDataProvider(
        credentialSource: (_) => (token: 'tk', userId: ' ', nickname: null),
      );
      await expectLater(
        provider.fetch(ThirdPartyScope.accountToken, null),
        throwsA(isA<ThirdPartyException>()),
      );
    });

    test('已登录按平台返回 token / userId / nickname', () async {
      KugouPlatform? seen;
      final provider = ThirdPartyDataProvider(
        credentialSource: (KugouPlatform platform) {
          seen = platform;
          return (token: 'tk-std', userId: '42', nickname: '昵称');
        },
        now: () => now,
      );

      final result = await provider.fetch(
        ThirdPartyScope.accountToken,
        <String, dynamic>{'platform': 'standard'},
      );

      expect(seen, KugouPlatform.standard);
      expect(result['platform'], 'standard');
      expect(result['token'], 'tk-std');
      expect(result['userId'], '42');
      expect(result['nickname'], '昵称');
    });

    test('默认平台为 lite', () async {
      KugouPlatform? seen;
      final provider = ThirdPartyDataProvider(
        credentialSource: (KugouPlatform platform) {
          seen = platform;
          return (token: 'tk', userId: '1', nickname: null);
        },
        now: () => now,
      );

      await provider.fetch(ThirdPartyScope.accountToken, null);
      expect(seen, KugouPlatform.lite);
    });
  });

  group('url.resolve', () {
    test('song 对象字段正确映射到 SongModel（酷狗字段齐全）', () async {
      SongModel? captured;
      final provider = ThirdPartyDataProvider(
        urlResolver: (SongModel song) async {
          captured = song;
          return 'https://example.com/a.mp3';
        },
        now: () => now,
      );

      final result = await provider.fetch(
        ThirdPartyScope.urlResolve,
        <String, dynamic>{
          'song': <String, dynamic>{
            'id': 'hash-1',
            'name': '歌名',
            'artist': '歌手',
            'album': '专辑',
            'source': 'kugou',
            'hash': 'HASH123',
            'albumId': 'album-9',
            'albumAudioId': 'audio-9',
            'duration': 210,
            'localPath': '/sdcard/secret.mp3', // 白名单外字段必须被忽略
          },
        },
      );

      expect(captured, isNotNull);
      expect(captured!.id, 'hash-1');
      expect(captured!.name, '歌名');
      expect(captured!.artist, '歌手');
      expect(captured!.album, '专辑');
      expect(captured!.source, SongSource.kugou);
      expect(captured!.hash, 'HASH123');
      expect(captured!.albumId, 'album-9');
      expect(captured!.albumAudioId, 'audio-9');
      expect(captured!.duration, 210);
      expect(captured!.localPath, isNull);
      expect(captured!.isLocal, isFalse);

      expect(result['url'], 'https://example.com/a.mp3');
      expect(result['source'], 'kugou');
      expect(result['songId'], 'hash-1');
      expect(result['resolvedAt'], now);
    });

    test('解析失败（返回 null）→ resolve_failed', () async {
      final provider = ThirdPartyDataProvider(
        urlResolver: (_) async => null,
      );
      await expectLater(
        provider.fetch(
          ThirdPartyScope.urlResolve,
          <String, dynamic>{
            'song': <String, dynamic>{'id': 's1'},
          },
        ),
        throwsA(
          isA<ThirdPartyException>()
              .having((e) => e.code, 'code', AuthErrors.resolveFailed),
        ),
      );
    });

    test('解析抛异常 → resolve_failed', () async {
      final provider = ThirdPartyDataProvider(
        urlResolver: (_) async => throw StateError('boom'),
      );
      await expectLater(
        provider.fetch(
          ThirdPartyScope.urlResolve,
          <String, dynamic>{
            'song': <String, dynamic>{'id': 's1'},
          },
        ),
        throwsA(
          isA<ThirdPartyException>()
              .having((e) => e.code, 'code', AuthErrors.resolveFailed),
        ),
      );
    });

    test('缺少 song 且当前无歌 → bad_request（错误信息可行动）', () async {
      final provider = ThirdPartyDataProvider(currentSong: () => null);
      await expectLater(
        provider.fetch(ThirdPartyScope.urlResolve, null),
        throwsA(
          isA<ThirdPartyException>()
              .having((e) => e.code, 'code', AuthErrors.badRequest)
              .having((e) => e.message, 'message', contains('params.song')),
        ),
      );
    });

    test('缺少 song 时回落到 App 当前播放歌曲', () async {
      var resolvedId = '';
      final provider = ThirdPartyDataProvider(
        currentSong: () => const SongModel(
          id: 'now-playing-1',
          name: '东风破',
          artist: '周杰伦',
          album: '叶惠美',
          duration: 300000,
          source: SongSource.local,
        ),
        urlResolver: (song) async {
          resolvedId = song.id;
          return 'http://example.test/${song.id}.mp3';
        },
      );

      final result = await provider.fetch(ThirdPartyScope.urlResolve, null);
      expect(resolvedId, 'now-playing-1');
      expect(result['url'], 'http://example.test/now-playing-1.mp3');
      expect(result['songId'], 'now-playing-1');
    });
  });

  group('playback.control', () {
    test('play 用 SongModel 调 playSongs', () async {
      final playback = FakePlayback();
      final provider = ThirdPartyDataProvider(playback: playback);

      final result = await provider.fetch(
        ThirdPartyScope.playbackControl,
        <String, dynamic>{
          'action': 'play',
          'song': <String, dynamic>{
            'id': 's1',
            'name': '歌名',
            'source': 'netease',
          },
        },
      );

      expect(playback.actions, <String>['play']);
      expect(playback.played.single.id, 's1');
      expect(result['ok'], true);
      expect(result['action'], 'play');
    });

    test('pause / resume / next / previous 路由到现有播放方法', () async {
      final playback = FakePlayback();
      final provider = ThirdPartyDataProvider(playback: playback);

      for (final action in <String>['pause', 'resume', 'next', 'previous']) {
        await provider.fetch(
          ThirdPartyScope.playbackControl,
          <String, dynamic>{'action': action},
        );
      }

      expect(playback.actions, <String>['pause', 'resume', 'next', 'previous']);
    });

    test('未知 action → bad_request', () async {
      final provider = ThirdPartyDataProvider(playback: FakePlayback());
      await expectLater(
        provider.fetch(
          ThirdPartyScope.playbackControl,
          <String, dynamic>{'action': 'rm -rf'},
        ),
        throwsA(
          isA<ThirdPartyException>()
              .having((e) => e.code, 'code', AuthErrors.badRequest),
        ),
      );
    });

    test('play 缺少 song 且当前无歌 → bad_request', () async {
      final provider = ThirdPartyDataProvider(
        playback: FakePlayback(),
        currentSong: () => null,
      );
      await expectLater(
        provider.fetch(
          ThirdPartyScope.playbackControl,
          <String, dynamic>{'action': 'play'},
        ),
        throwsA(isA<ThirdPartyException>()),
      );
    });

    test('play 缺少 song 时播放 App 当前歌曲', () async {
      final playback = FakePlayback();
      final provider = ThirdPartyDataProvider(
        playback: playback,
        currentSong: () => const SongModel(
          id: 'now-playing-2',
          name: '东风破',
          artist: '周杰伦',
          album: '叶惠美',
          duration: 300000,
          source: SongSource.local,
        ),
      );

      await provider.fetch(
        ThirdPartyScope.playbackControl,
        <String, dynamic>{'action': 'play'},
      );
      expect(playback.actions, <String>['play']);
      expect(playback.played.single.id, 'now-playing-2');
    });
  });

  group('SongModel 反序列化', () {
    test('默认音源为 netease，缺失 id 抛 bad_request', () {
      final song = songFromJson(<Object?, Object?>{
        'id': 'x1',
        'name': 'n',
      });
      expect(song.source, SongSource.netease);

      expect(
        () => songFromJson(<Object?, Object?>{'name': 'n'}),
        throwsA(isA<ThirdPartyException>()),
      );
    });
  });
}

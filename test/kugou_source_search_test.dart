import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/sources/kugou_config.dart';
import 'package:such_music/services/sources/kugou_device.dart';
import 'package:such_music/services/sources/kugou_sign.dart';
import 'package:such_music/services/sources/kugou_source.dart';

import 'support/fake_dio.dart';

/// 按 host 分流的假应答。
FakeAdapter routed(Map<String, Future<ResponseBody> Function(RequestOptions)>
    byHost) {
  return FakeAdapter((o) {
    final handler = byHost[o.uri.host];
    if (handler == null) {
      return Future.value(jsonResponse({'status': 0, 'data': {}}));
    }
    return handler(o);
  });
}

void main() {
  group('搜索主路径（complexsearch 唯一主路径 + 完整签名）', () {
    test('主路径命中 → 只用 complexsearch，不触发 mobilecdn', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async => jsonResponse({
              'status': 1,
              'data': {
                'lists': [
                  {
                    'SongName': '晴天',
                    'SingerName': '周杰伦',
                    'FileHash': 'HASH1',
                    'EMixSongID': 'MIX1',
                    'AlbumID': 'ALB1',
                    'timelength': 269000,
                  }
                ]
              }
            }),
        'mobilecdn.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'info': []}}),
      });
      final source = KugouSource.withDio(fakeDio(adapter));

      final songs = await source.search('周杰伦', limit: 30);

      // 仅复杂搜索被调用
      expect(adapter.log.length, 1);
      expect(adapter.log.single.uri.host, 'complexsearch.kugou.com');
      expect(adapter.log.single.uri.path, '/v2/search/song');

      // 字段映射正确
      expect(songs, hasLength(1));
      expect(songs.first.name, '晴天');
      expect(songs.first.artist, '周杰伦');
      expect(songs.first.hash, 'HASH1');
      expect(songs.first.albumAudioId, 'MIX1');
      expect(songs.first.albumId, 'ALB1');
      expect(songs.first.source, SongSource.kugou);
    });

    test('主路径参数集完整，且 signature 覆盖全部参数', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'lists': []}}),
        'mobilecdn.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'info': []}}),
      });
      final source = KugouSource.withDio(fakeDio(adapter));

      await source.search('测试', limit: 20);

      final q = adapter.log
          .firstWhere((r) => r.uri.host == 'complexsearch.kugou.com')
          .queryParameters;
      // 关键参数齐全（漏参数会 20006）
      for (final key in [
        'appid', 'srcappid', 'clientver', 'clienttime', 'dfid', 'mid', 'uuid',
        'keyword', 'page', 'pagesize', 'bitrate', 'isfuzzy', 'inputtype',
        'platform', 'userid', 'iscorrection', 'privilege_filter', 'filter',
        'token', 'signature',
      ]) {
        expect(q.containsKey(key), isTrue, reason: '缺少参数 $key');
      }
      expect(q['appid'], 1005);
      expect(q['srcappid'], 2919);
      expect(q['bitrate'], 0);
      expect(q['isfuzzy'], 0);
      expect(q['inputtype'], 0);
      expect(q['platform'], 'WebFilter');
      expect(q['userid'], 0);
      expect(q['iscorrection'], 1);
      expect(q['privilege_filter'], 0);
      expect(q['filter'], 10);
      expect(q['token'], '');

      // signature = 用 **Web 盐值** 对「去 signature 后的完整参数集」签名
      // （complexsearch 是 Web 端接口；用 Android 盐值会 20006）
      final params = Map<String, dynamic>.from(q)..remove('signature');
      expect(q['signature'], KugouSign.webSignature(params));
    });

    test('CDN 返回 text/html（Dio 未解码为 Map）→ 手动解码仍能解析结果', () async {
      // 复现线上：部分 complexsearch 节点返回 text/html，Dio 不解码 → data 为 String
      final adapter = routed({
        'complexsearch.kugou.com': (_) async => htmlJsonResponse({
              'status': 1,
              'error_code': 0,
              'data': {
                'lists': [
                  {
                    'SongName': '晴天',
                    'SingerName': '周杰伦',
                    'FileHash': 'H1',
                    'EMixSongID': 'MIX1',
                  }
                ]
              }
            }),
      });
      final source = KugouSource.withDio(fakeDio(adapter));

      final songs = await source.search('周杰伦', limit: 30);

      expect(songs, hasLength(1));
      expect(songs.single.name, '晴天');
      expect(songs.single.artist, '周杰伦');
      expect(songs.single.hash, 'H1');
      // 未触发 mobilecdn 兜底（仅 1 次 complexsearch 请求）
      expect(adapter.log.length, 1);
    });

    test('主路径空结果 → mobilecdn 兜底', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'lists': []}}),
        'mobilecdn.kugou.com': (_) async => jsonResponse({
              'status': 1,
              'data': {
                'info': [
                  {'songname': '稻香', 'singername': '周杰伦', 'hash': 'H2'}
                ]
              }
            }),
      });
      final source = KugouSource.withDio(fakeDio(adapter));

      final songs = await source.search('周杰伦', limit: 30);

      expect(adapter.log.map((r) => r.uri.host).toList(),
          ['complexsearch.kugou.com', 'mobilecdn.kugou.com']);
      expect(songs.single.name, '稻香');
      expect(songs.single.hash, 'H2');
    });

    test('主路径空 + mobilecdn 失败 → 返回空（不抛）', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'lists': []}}),
        'mobilecdn.kugou.com': (_) async => throw Exception('HTTP 000'),
      });
      final source = KugouSource.withDio(fakeDio(adapter));
      expect(await source.search('周杰伦'), isEmpty);
    });
  });

  group('取播放地址使用概念版 lite 盐值（REQ-L3）', () {
    test('key 参数 = playKey(..., salt=keySaltLite)', () async {
      const hash = 'b3a52a7a958bf0aed0ebfba2e9a818b7';
      final adapter = routed({
        'gateway.kugou.com': (_) async => jsonResponse({
              'data': [
                {'url': 'https://x/y.mp3'}
              ]
            }),
      });
      final source = KugouSource.withDio(fakeDio(adapter));

      final url = await source.getSongUrl(SongModel(
        id: '1',
        name: 'n',
        artist: 'a',
        album: '',
        hash: hash.toUpperCase(),
        albumId: 'ALB',
        albumAudioId: 'MIX',
      ));

      expect(url, 'https://x/y.mp3');
      final q = adapter.log.single.queryParameters;
      final expected = KugouSign.playKey(
        hash: hash,
        mid: KugouDevice.mid,
        userId: '0',
        salt: KugouConfig.keySaltLite,
      );
      expect(q['key'], expected);
      expect(q['key'], KugouSign.playKey(
        hash: hash,
        mid: KugouDevice.mid,
        userId: '0',
        salt: KugouConfig.keySaltLite,
      ));
      // 明确与标准版不同，钉死盐值归属
      expect(
          q['key'],
          isNot(KugouSign.playKey(
              hash: hash, mid: KugouDevice.mid, userId: '0')));
      expect(q['mid'], KugouDevice.mid);
    });
  });

  group('sanitizePlayUrlForLog（播放直链日志脱敏）', () {
    test('丢弃 query / fragment，仅留 协议+主机+路径', () {
      const url =
          'https://fs.kugou.com/v3/abc.mp3?token=SECRET123&userid=88#frag';
      final s = sanitizePlayUrlForLog(url);
      expect(s, 'https://fs.kugou.com/v3/abc.mp3');
      expect(s.contains('SECRET123'), isFalse);
      expect(s.contains('token='), isFalse);
      expect(s.contains('?'), isFalse);
    });

    test('长路径前缀截断且保留 host', () {
      final long = 'https://h.com/${'a' * 80}?token=x';
      final s = sanitizePlayUrlForLog(long);
      expect(s.startsWith('https://h.com/'), isTrue);
      expect(s.contains('token'), isFalse);
    });

    test('非法 / 无 host 的串退化为截断，不泄漏整串', () {
      final s = sanitizePlayUrlForLog('not-a-url-${'x' * 40}');
      expect(s.length <= 25, isTrue);
      expect(s.endsWith('…'), isTrue);
    });
  });
}

// 1.5.2：歌曲分享改为唤起 Wrensong（协议见 docs/wrensong-share.md）。
//
// 这里只测「决策与 payload 组包」，不测原生压缩 / 唤起：
//  - 未安装 → notInstalled 且**不**调 share（不能白跑一次桥接）；
//  - 有直链 → type=music + music_url（+ 网页 url）；
//  - 无直链 → type=link + url；
//  - 本地曲目 → notSupportedLocal（连安装状态都不查）；
//  - 桥接抛异常 → failed（绝不让异常冒到播放页）；
//  - title/desc 按 runes 截断到 64/120，且 payload JSON ≤8KB。
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/share/wrensong_share_service.dart';

/// 假桥：记录入参 + 可按需返回失败 / 抛异常（不触碰 MethodChannel）。
class _FakeBridge implements WrensongShareBridge {
  _FakeBridge({
    this.installed = true,
    this.result = const WrensongShareResult.ok(),
    this.throwOnShare = false,
    this.throwOnInstalled = false,
  });

  final bool installed;
  final WrensongShareResult result;
  final bool throwOnShare;
  final bool throwOnInstalled;

  int installedCalls = 0;
  int shareCalls = 0;
  String? capturedAppId;
  Map<String, Object?>? capturedPayload;
  Uint8List? capturedThumb;

  @override
  Future<bool> isInstalled() async {
    installedCalls++;
    if (throwOnInstalled) throw StateError('installed boom');
    return installed;
  }

  @override
  Future<WrensongShareResult> share({
    required String appId,
    required Map<String, Object?> payload,
    Uint8List? thumbBytes,
  }) async {
    shareCalls++;
    if (throwOnShare) throw StateError('share boom');
    capturedAppId = appId;
    capturedPayload = payload;
    capturedThumb = thumbBytes;
    return result;
  }
}

const SongModel _neteaseSong = SongModel(
  id: '186016',
  name: '晴天',
  artist: '周杰伦',
  album: '叶惠美',
);

const SongModel _kugouSong = SongModel(
  id: 'B3A52A7A958BF0AED0EBFBA2E9A818B7',
  name: '夜曲',
  artist: '周杰伦',
  album: '',
  source: SongSource.kugou,
);

const SongModel _localSong = SongModel(
  id: 'local:/tmp/东风破.mp3',
  name: '东风破',
  artist: '周杰伦',
  album: '叶惠美',
  source: SongSource.local,
  localUri: 'file:///tmp/suchmusic-wrensong-nonexistent.mp3',
);

/// 构造只注假桥 / 假取址的服务（永不触网）。
WrensongShareService _service(
  _FakeBridge bridge, {
  String? directUrl,
  Uint8List? cover,
}) => WrensongShareService(
  bridge: bridge,
  resolveDirectUrl: (_) async => directUrl,
  fetchCover: (_) async => cover,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shareSong：安装状态分支', () {
    test('未安装 → notInstalled，且不调用 share', () async {
      final bridge = _FakeBridge(installed: false);
      final result = await _service(
        bridge,
        directUrl: 'https://cdn.example.com/a.mp3',
      ).shareSong(_neteaseSong);

      expect(result, isA<WrensongShareNotInstalled>());
      expect(bridge.installedCalls, 1);
      expect(bridge.shareCalls, 0, reason: '未安装时不应再调 share 白跑一趟');
    });

    test('isInstalled 抛异常 → 按未安装处理（不冒泡）', () async {
      final bridge = _FakeBridge(throwOnInstalled: true);
      final result = await _service(bridge).shareSong(_neteaseSong);

      expect(result, isA<WrensongShareNotInstalled>());
      expect(bridge.shareCalls, 0);
    });

    test('bridge 抛异常 → failed，异常不外抛', () async {
      final bridge = _FakeBridge(throwOnShare: true);
      final result = await _service(
        bridge,
        directUrl: 'https://cdn.example.com/a.mp3',
      ).shareSong(_neteaseSong);

      expect(result, isA<WrensongShareFailed>());
      expect((result as WrensongShareFailed).message, contains('boom'));
    });

    test('isInstalled 通过但原生 share 回 not_installed（检查后被卸载）→ 透传', () async {
      final bridge = _FakeBridge(
        result: const WrensongShareResult.notInstalled(),
      );
      final result = await _service(
        bridge,
        directUrl: 'https://cdn.example.com/a.mp3',
      ).shareSong(_neteaseSong);

      expect(result, isA<WrensongShareNotInstalled>());
      expect(bridge.shareCalls, 1);
    });

    test('原生 share 回 failed → 透传 failed（不吞成 ok）', () async {
      final bridge = _FakeBridge(
        result: const WrensongShareResult.failed('security'),
      );
      final result = await _service(
        bridge,
        directUrl: 'https://cdn.example.com/a.mp3',
      ).shareSong(_neteaseSong);

      expect(result, isA<WrensongShareFailed>());
      expect((result as WrensongShareFailed).message, 'security');
    });
  });

  group('shareSong：payload 映射', () {
    test('有直链 → type=music，含 music_url 与网页 url', () async {
      final bridge = _FakeBridge();
      final result = await _service(
        bridge,
        directUrl: 'https://cdn.example.com/a.mp3',
      ).shareSong(_neteaseSong);

      expect(result, isA<WrensongShareOk>());
      expect(bridge.capturedAppId, WrensongShareService.appId);
      final payload = bridge.capturedPayload!;
      expect(payload['type'], 'music');
      expect(payload['music_url'], 'https://cdn.example.com/a.mp3');
      expect(payload['url'], 'https://music.163.com/song?id=186016');
      expect(payload['title'], '晴天');
      expect(payload['desc'], '周杰伦 · 叶惠美');
    });

    test('无直链 → type=link，只含网页 url', () async {
      final bridge = _FakeBridge();
      final result = await _service(bridge).shareSong(_kugouSong);

      expect(result, isA<WrensongShareOk>());
      final payload = bridge.capturedPayload!;
      expect(payload['type'], 'link');
      expect(payload.containsKey('music_url'), isFalse);
      expect(
        payload['url'],
        'https://www.kugou.com/song/#hash=B3A52A7A958BF0AED0EBFBA2E9A818B7',
      );
      // album 为空 → 描述只写歌手
      expect(payload['desc'], '周杰伦');
    });

    test('本地曲目 → notSupportedLocal，且不查安装状态 / 不调 share', () async {
      final bridge = _FakeBridge();
      final result = await _service(bridge).shareSong(_localSong);

      expect(result, isA<WrensongShareNotSupportedLocal>());
      expect(bridge.installedCalls, 0);
      expect(bridge.shareCalls, 0);
    });

    test('payload JSON 序列化后 ≤8KB', () async {
      final bridge = _FakeBridge();
      await _service(
        bridge,
        directUrl: 'https://cdn.example.com/${'a' * 200}.mp3',
      ).shareSong(_neteaseSong);

      final bytes = utf8.encode(jsonEncode(bridge.capturedPayload!));
      expect(bytes.length, lessThanOrEqualTo(WrensongShareService.payloadMaxBytes));
    });
  });

  group('shareSong：字段截断（按 runes）', () {
    test('title 截断到 64 runes，desc 截断到 120 runes', () async {
      final bridge = _FakeBridge();
      // emoji 是代理对：按 code unit 截会切出半个字符（乱码）
      final longSong = SongModel(
        id: 'long',
        name: '🎵' * 100,
        artist: '杰' * 200,
        album: '专辑',
      );

      await _service(bridge, directUrl: 'https://cdn.example.com/a.mp3')
          .shareSong(longSong);

      final payload = bridge.capturedPayload!;
      final title = payload['title']! as String;
      final desc = payload['desc']! as String;
      expect(title.runes.length, WrensongShareService.titleMaxRunes);
      expect(desc.runes.length, WrensongShareService.descMaxRunes);
      // 截断后仍是完整字符（没有孤立代理项）
      expect(title, '🎵' * 64);
    });
  });

  group('降级文案 shareTextOf', () {
    test('在线曲目：歌名 - 歌手 + 网页链接', () {
      expect(
        WrensongShareService.shareTextOf(_neteaseSong),
        '晴天 - 周杰伦\nhttps://music.163.com/song?id=186016',
      );
    });

    test('本地曲目：链接位写「本地文件」', () {
      expect(
        WrensongShareService.shareTextOf(_localSong),
        '东风破 - 周杰伦\n本地文件',
      );
    });
  });
}

// 酷狗真实联网冒烟测试（**可选**，默认跳过，不参与 CI / 离线运行）。
//
// 用途：显式联网验证「扫码登录 + 搜索 + 取播放地址」链路。
// 运行（一行命令）：
//   flutter test --dart-define=LIVE=1 test/live/kugou_live_smoke_test.dart --reporter expanded
// 也支持环境变量：LIVE=1 flutter test test/live/kugou_live_smoke_test.dart
//
// 默认跳过原因：无语义化的联网用例在离线 / CI 环境会误报失败；
// 只有显式开启（[LIVE]=1）才会真正发起网络请求。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sources/kugou_device.dart';
import 'package:such_music/services/sources/kugou_login_models.dart';
import 'package:such_music/services/sources/kugou_login_service.dart';
import 'package:such_music/services/sources/kugou_source.dart';

/// 是否开启联网（--dart-define=LIVE=1 或 环境变量 LIVE=1）。
const String _liveDefine = String.fromEnvironment('LIVE');

bool _liveEnabled() => _liveDefine == '1' || Platform.environment['LIVE'] == '1';

void main() {
  group(
    '酷狗真实联网冒烟（可选，默认跳过）',
    () {
      test('LIVE-SMOKE·设备标识格式', () async {
        expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(KugouDevice.mid), isTrue);
        expect(RegExp(r'^0j[A-Za-z0-9]{20}$').hasMatch(KugouDevice.dfid), isTrue);
        expect(KugouDevice.uuid, KugouDevice.mid);
      });

      test('LIVE-SMOKE·取二维码（真实接口）', () async {
        final svc = KugouLoginService();
        final s = await svc.createQr();
        expect(s, isNotNull, reason: '真实接口应返回二维码');
        expect(s!.key, isNotEmpty);
        expect(s.imageDataUri, startsWith('data:image/'),
            reason: '二维码应为 data URI 图片');
        // ignore: avoid_print
        print('[SMOKE] QR key=${s.key} imgLen=${s.imageDataUri.length}');
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('LIVE-SMOKE·轮询状态（预期 waiting）', () async {
        final svc = KugouLoginService();
        final s = await svc.createQr();
        expect(s, isNotNull);
        final r = await svc.pollStatus(s!.key);
        expect(r, isNotNull, reason: '真实接口应返回状态');
        expect(r!.state, QrLoginState.waiting,
            reason: '未扫码时应为等待态');
        // ignore: avoid_print
        print('[SMOKE] poll state=${r.state}');
      }, timeout: const Timeout(Duration(seconds: 60)));

      test('LIVE-SMOKE·搜索（主路径 complexsearch 应非空且字段完整）', () async {
        final src = KugouSource();
        final songs = await src.search('周杰伦', limit: 10);
        // ignore: avoid_print
        print('[SMOKE] 搜索结果数=${songs.length}');
        for (final s in songs.take(5)) {
          // ignore: avoid_print
          print('  - ${s.name} | ${s.artist} | hash=${s.hash} '
              '| albumAudioId=${s.albumAudioId} | albumId=${s.albumId}');
        }
        expect(songs, isNotEmpty,
            reason: '搜索必须非空（验证已用 Web 盐值签名 complexsearch 主路径）');
        final first = songs.first;
        expect(first.name, isNotEmpty, reason: '歌名应非空');
        expect(first.artist, isNotEmpty, reason: '歌手应非空');
        expect(first.hash, isNotNull, reason: 'hash 应存在（供取播放地址）');
        expect(first.hash, isNotEmpty, reason: 'hash 应非空');
      }, timeout: const Timeout(Duration(seconds: 90)));

      test('LIVE-SMOKE·搜索→取播放地址（应为非签名错误）', () async {
        // 挂拦截器捕获 gateway 响应，读取真实 error_code
        final captured = <Response<dynamic>>[];
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ))
          ..interceptors.add(InterceptorsWrapper(
            onResponse: (r, h) {
              captured.add(r);
              h.next(r);
            },
            onError: (e, h) {
              final resp = e.response;
              if (resp != null) captured.add(resp);
              h.next(e);
            },
          ));
        final src = KugouSource.withDio(dio);

        final songs = await src.search('周杰伦', limit: 10);
        expect(songs, isNotEmpty, reason: '前置搜索应非空');
        final song = songs.firstWhere((s) => (s.hash ?? '').isNotEmpty,
            orElse: () => songs.first);

        // 无凭证时取不到 URL 属正常；关键是**非签名错误**
        final url = await src.getSongUrl(song);
        // ignore: avoid_print
        print('[SMOKE] 播放地址 url=${url ?? "(null，无凭证属正常)"}');

        Response<dynamic>? gw;
        for (final r in captured) {
          if (r.requestOptions.uri.host == 'gateway.kugou.com') gw = r;
        }
        expect(gw, isNotNull, reason: '应发起 gateway 取地址请求');
        final body = gw!.data;
        final errCode = body is Map ? body['error_code'] : null;
        // ignore: avoid_print
        print('[SMOKE] gateway error_code=$errCode');
        expect(errCode?.toString(), isNot('20006'),
            reason: '签名盐值正确 → 不应返回签名错误 20006');
      }, timeout: const Timeout(Duration(seconds: 90)));
    },
    skip: _liveEnabled()
        ? false
        : '联网冒烟默认跳过：需 --dart-define=LIVE=1 或 环境变量 LIVE=1',
  );
}

// 酷狗真实联网冒烟测试（**可选**，默认跳过，不参与 CI / 离线运行）。
//
// 用途：显式联网验证「设备注册 + 扫码登录 + 搜索 + 取播放直链」全链路。
// 运行（一行命令）：
//   flutter test --dart-define=LIVE=1 test/live/kugou_live_smoke_test.dart --reporter expanded
//
// 默认跳过原因：无语义化的联网用例在离线 / CI 环境会误报失败；
// 只有显式开启（[LIVE]=1）才会真正发起网络请求。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/sources/kugou_device.dart';
import 'package:such_music/services/sources/kugou_device_service.dart';
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
      var registered = false;
      setUpAll(() async {
        // prefs mock（设备注册会读写 dfid/mid）；整组只注册一次（服务端限流）
        SharedPreferences.setMockInitialValues({});
        registered = await KugouDeviceService.instance.register();
      });

      test('LIVE-SMOKE·设备标识格式（mid 纯数字 / dfid 非空）', () async {
        expect(RegExp(r'^\d{32}$').hasMatch(KugouDevice.mid), isTrue,
            reason: 'mid 必须为纯数字（注册接口要求）');
        expect(KugouDevice.uuid, KugouDevice.mid);
        expect(KugouDevice.dfid, isNotEmpty);
        expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(KugouDevice.dfid), isTrue);
      });

      test('LIVE-SMOKE·设备注册（register_dev 应返回真实 dfid）', () async {
        expect(registered, isTrue, reason: '设备注册应成功（含重试）');
        expect(KugouDevice.hasRegisteredDfid, isTrue);
        expect(KugouDevice.dfid, isNotEmpty);
        // ignore: avoid_print
        print('[SMOKE] dfid=${KugouDevice.dfid}  mid=${KugouDevice.mid.substring(0, 8)}…');
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
        expect(songs, isNotEmpty,
            reason: '搜索必须非空（验证已用 Web 盐值签名 complexsearch 主路径）');
        final first = songs.first;
        expect(first.name, isNotEmpty, reason: '歌名应非空');
        expect(first.hash, isNotNull, reason: 'hash 应存在（供取播放地址）');
      }, timeout: const Timeout(Duration(seconds: 90)));

      test('LIVE-SMOKE·搜索→设备注册→取播放直链（应拿到可用 URL）', () async {
        final src = KugouSource();
        // 先注册设备（取直链前置）
        await KugouDeviceService.instance.ensureDfid();

        final songs = await src.search('纯音乐 生日快乐', limit: 20);
        expect(songs, isNotEmpty, reason: '前置搜索应非空');
        // 优先挑免费曲（Privilege 低）以便无凭证也能取到 URL
        final song = songs.firstWhere((s) => (s.hash ?? '').isNotEmpty,
            orElse: () => songs.first);

        final url = await src.getSongUrl(song);
        // ignore: avoid_print
        print('[SMOKE] 直链=${url ?? "(null)"}');
        expect(url, isNotNull, reason: '注册设备后应能取到播放直链');
        expect(url!.startsWith('http'), isTrue);

        // 直链可下载（200 + 音频）
        final dio = Dio();
        final head = await dio.get<List<int>>(url,
            options: Options(responseType: ResponseType.bytes,
                headers: {'Range': 'bytes=0-1023'}));
        // ignore: avoid_print
        print('[SMOKE] 直链 HTTP=${head.statusCode} bytes=${head.data?.length}');
        // Range 请求正常返回 206（Partial Content）
        expect(head.statusCode == 200 || head.statusCode == 206, isTrue);
      }, timeout: const Timeout(Duration(seconds: 120)));

      test('LIVE-SMOKE·榜单列表 + 榜单歌曲（酷狗）', () async {
        final src = KugouSource();
        await KugouDeviceService.instance.ensureDfid();

        final ranks = await src.topList();
        // ignore: avoid_print
        print('[SMOKE] 榜单数=${ranks.length}');
        for (final r in ranks.take(3)) {
          // ignore: avoid_print
          print('   - ${r.name} id=${r.id} cover=${r.coverUrl != null}');
        }
        expect(ranks, isNotEmpty, reason: '酷狗榜单列表应非空');
        expect(ranks.first.name, isNotEmpty);
        expect(ranks.first.id, isNotEmpty);

        final songs = await src.rankSongs(ranks.first.id, limit: 10);
        // ignore: avoid_print
        print('[SMOKE] 榜单「${ranks.first.name}」歌曲数=${songs.length}');
        for (final s in songs.take(3)) {
          // ignore: avoid_print
          print('   - ${s.name} / ${s.artist} hash=${(s.hash ?? "").substring(0, 8)}');
        }
        expect(songs, isNotEmpty, reason: '酷狗榜单歌曲应非空');
        expect(songs.first.name, isNotEmpty);
        expect(songs.first.hash, isNotNull, reason: '歌曲应有 hash 供取直链');
        expect(songs.first.source, SongSource.kugou);
      }, timeout: const Timeout(Duration(seconds: 120)));

      test('LIVE-SMOKE·每日推荐（酷狗，FM 兜底数据源）', () async {
        final src = KugouSource();
        await KugouDeviceService.instance.ensureDfid();

        final songs = await src.dailyRecommend();
        // ignore: avoid_print
        print('[SMOKE] 每日推荐数=${songs.length}');
        for (final s in songs.take(3)) {
          // ignore: avoid_print
          print('   - ${s.name} / ${s.artist} hash=${(s.hash ?? "").substring(0, 8)}');
        }
        expect(songs, isNotEmpty, reason: '酷狗每日推荐应非空');
        expect(songs.first.name, isNotEmpty);
        expect(songs.first.hash, isNotNull, reason: '每日推荐应有 hash 供取直链');
        expect(songs.first.source, SongSource.kugou);
      }, timeout: const Timeout(Duration(seconds: 120)));
    },
    skip: _liveEnabled()
        ? false
        : '联网冒烟默认跳过：需 --dart-define=LIVE=1 或 环境变量 LIVE=1',
  );
}

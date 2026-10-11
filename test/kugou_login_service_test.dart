import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sources/kugou_config.dart';
import 'package:such_music/services/sources/kugou_login_models.dart';
import 'package:such_music/services/sources/kugou_login_service.dart';

import 'support/fake_dio.dart';

/// 可控假时钟。
class FakeClock {
  FakeClock(this._t);
  DateTime _t;
  DateTime call() => _t;
  void advance(Duration d) => _t = _t.add(d);
}

/// dispatching handler：按路径分流。
Future<ResponseBody> Function(RequestOptions) router({
  Future<ResponseBody> Function(RequestOptions)? qr,
  Future<ResponseBody> Function(RequestOptions)? status,
}) {
  return (options) {
    if (options.path.endsWith(KugouConfig.loginQrPath)) {
      return qr!(options);
    }
    return status!(options);
  };
}

KugouLoginService serviceWith(
  FakeAdapter adapter, {
  DateTime Function()? now,
  Duration pollInterval = Duration.zero,
}) =>
    KugouLoginService(
      dio: fakeDio(adapter),
      now: now,
      pollInterval: pollInterval,
      sessionTtl: const Duration(seconds: 120),
      maxWait: const Duration(minutes: 3),
      maxConsecutiveErrors: 5,
    );

void main() {
  final base = DateTime.utc(2024, 1, 1, 0, 0, 0);

  group('createQr', () {
    test('成功：返回 key / imageDataUri / expiresAt=now+120s', () async {
      final clock = FakeClock(base);
      final adapter = FakeAdapter(router(
        qr: (_) async => jsonResponse({
          'status': 1,
          'error_code': 0,
          'data': {
            'qrcode': 'K',
            'qrcode_img': 'data:image/png;base64,AAAA',
          },
        }),
        status: (_) async => jsonResponse({'status': 1, 'data': {'status': 1}}),
      ));
      final svc = serviceWith(adapter, now: clock.call);

      final session = await svc.createQr();
      expect(session, isNotNull);
      expect(session!.key, 'K');
      expect(session.imageDataUri, startsWith('data:image/png;base64,'));
      expect(session.expiresAt, base.add(const Duration(seconds: 120)));

      // 请求参数完整性
      final req = adapter.log.single;
      expect(req.path, '${KugouConfig.loginHost}${KugouConfig.loginQrPath}');
      expect(req.queryParameters['appid'], 1005);
      expect(req.queryParameters['srcappid'], 2919);
      expect(req.queryParameters['clientver'], 20489);
      expect(req.queryParameters['type'], 1);
      expect(req.queryParameters['plat'], 4);
      expect(req.queryParameters['qrcode_txt'], KugouConfig.qrTxt);
      expect(req.queryParameters['signature'], isA<String>());
    });

    test('失败不外抛：Dio 抛异常 → null', () async {
      final adapter = FakeAdapter((o) async => throw Exception('boom'));
      final svc = serviceWith(adapter);
      expect(await svc.createQr(), isNull);
    });

    test('缺少 qrcode key → null', () async {
      final adapter = FakeAdapter(
          (_) async => jsonResponse({'status': 1, 'data': <String, dynamic>{}}));
      final svc = serviceWith(adapter);
      expect(await svc.createQr(), isNull);
    });
  });

  group('pollStatus 状态映射', () {
    Future<KugouQrPollResult?> poll(int status,
        {String? token, String? userid}) async {
      final data = <String, dynamic>{'status': status};
      if (token != null) data['token'] = token;
      if (userid != null) data['userid'] = userid;
      final adapter = FakeAdapter((_) async => jsonResponse({
            'status': 1,
            'data': data,
          }));
      return serviceWith(adapter).pollStatus('KEY');
    }

    test('0 → expired', () async =>
        expect((await poll(0))!.state, QrLoginState.expired));
    test('1 → waiting', () async =>
        expect((await poll(1))!.state, QrLoginState.waiting));
    test('2 → scanned', () async =>
        expect((await poll(2))!.state, QrLoginState.scanned));
    test('4 → success 且携带 token/userid', () async {
      final r = await poll(4, token: 'TK', userid: '88');
      expect(r!.state, QrLoginState.success);
      expect(r.token, 'TK');
      expect(r.userId, '88');
    });

    test('响应结构异常 → 容错为 waiting（不抛）', () async {
      final adapter = FakeAdapter((_) async => jsonResponse({'foo': 'bar'}));
      final r = await serviceWith(adapter).pollStatus('KEY');
      expect(r!.state, QrLoginState.waiting);
    });

    test('网络异常 → null（本轮跳过，不终止）', () async {
      final adapter = FakeAdapter((_) async => throw Exception('net'));
      expect(await serviceWith(adapter).pollStatus('KEY'), isNull);
    });
  });

  group('startAutoLogin 状态机', () {
    test('waiting → scanned → success（顺序轮询，无并发）', () async {
      final states = [1, 2, 4];
      var i = 0;
      final adapter = FakeAdapter(router(
        qr: (_) async => jsonResponse({
              'status': 1,
              'data': {'qrcode': 'K', 'qrcode_img': ''},
            }),
        status: (_) async {
          final s = states[i < states.length ? i : states.length - 1];
          i++;
          return jsonResponse({
            'status': 1,
            'data': {
              'status': s,
              if (s == 4) 'token': 'TK',
              if (s == 4) 'userid': '88',
            },
          });
        },
      ));
      final svc = serviceWith(adapter);
      final events = await svc.startAutoLogin().toList();

      expect(events.first.state, QrLoginState.waiting);
      expect(events.map((e) => e.state).toList(), [
        QrLoginState.waiting, // 取码成功后的初始「等待扫码」
        QrLoginState.waiting, // 首次轮询 data.status=1
        QrLoginState.scanned, // data.status=2
        QrLoginState.success, // data.status=4
      ]);
      expect(events.last.token, 'TK');
      expect(events.last.userId, '88');
      expect(adapter.maxActive, lessThanOrEqualTo(1));
    });

    test('接口过期（status=0）→ 自动换码并发射 expired(next)', () async {
      var qrCount = 0;
      var pollCount = 0;
      final adapter = FakeAdapter(router(
        qr: (_) async {
          qrCount++;
          return jsonResponse({
            'status': 1,
            'data': {'qrcode': 'K$qrCount', 'qrcode_img': ''},
          });
        },
        status: (_) async {
          pollCount++;
          // 首次过期，随后成功
          if (pollCount == 1) {
            return jsonResponse({'status': 1, 'data': {'status': 0}});
          }
          return jsonResponse({
            'status': 1,
            'data': {'status': 4, 'token': 'TK', 'userid': '88'},
          });
        },
      ));
      final svc = serviceWith(adapter);
      final events = await svc.startAutoLogin().toList();

      final expired = events.firstWhere((e) => e.state == QrLoginState.expired);
      expect(expired.session, isNotNull);
      expect(expired.session!.key, 'K2'); // 已换成新码
      expect(qrCount, 2);
      expect(events.last.state, QrLoginState.success);
    });

    test('本地 TTL 到期 → 自动换码（不等接口）', () async {
      final clock = FakeClock(base);
      var qrCount = 0;
      final adapter = FakeAdapter(router(
        qr: (_) async {
          qrCount++;
          return jsonResponse({
            'status': 1,
            'data': {'qrcode': 'K$qrCount', 'qrcode_img': ''},
          });
        },
        status: (_) async {
          // 每次轮询推进 130s（> 单码 TTL 120s，< 整体 180s）
          clock.advance(const Duration(seconds: 130));
          return jsonResponse({'status': 1, 'data': {'status': 1}});
        },
      ));
      final svc = serviceWith(adapter, now: clock.call);

      final completer = Completer<KugouQrPollResult>();
      final sub = svc.startAutoLogin().listen((e) {
        if (e.state == QrLoginState.expired && !completer.isCompleted) {
          completer.complete(e);
        }
      });
      final expired = await completer.future;
      expect(expired.session!.key, 'K2');
      await sub.cancel();
      svc.cancel();
    });

    test('连续错误 > 5 次 → failed 并停止', () async {
      final adapter = FakeAdapter(router(
        qr: (_) async => jsonResponse({
              'status': 1,
              'data': {'qrcode': 'K', 'qrcode_img': ''},
            }),
        status: (_) async => throw Exception('net'),
      ));
      final svc = serviceWith(adapter);
      final events = await svc.startAutoLogin().toList();

      expect(events.last.state, QrLoginState.failed);
      expect(events.last.message, contains('网络异常'));
      // 初始 waiting + 1 个 failed
      expect(events.where((e) => e.state == QrLoginState.failed).length, 1);
    });

    test('整体超时 → failed（超时）并停止', () async {
      final clock = FakeClock(base);
      var pollCount = 0;
      final adapter = FakeAdapter(router(
        qr: (_) async => jsonResponse({
              'status': 1,
              'data': {'qrcode': 'K', 'qrcode_img': ''},
            }),
        status: (_) async {
          pollCount++;
          clock.advance(const Duration(seconds: 100));
          return jsonResponse({'status': 1, 'data': {'status': 1}});
        },
      ));
      final svc = serviceWith(adapter, now: clock.call);
      final events = await svc.startAutoLogin().toList();

      expect(events.last.state, QrLoginState.failed);
      expect(events.last.message, contains('超时'));
      expect(pollCount, lessThanOrEqualTo(3));
    });

    test('取码失败 → failed 并停止', () async {
      final adapter = FakeAdapter((_) async => throw Exception('net'));
      final svc = serviceWith(adapter);
      final events = await svc.startAutoLogin().toList();
      expect(events.single.state, QrLoginState.failed);
    });

    test('cancel 幂等；取消后流关闭、无事件泄漏', () async {
      final adapter = FakeAdapter(router(
        qr: (_) async => jsonResponse({
              'status': 1,
              'data': {'qrcode': 'K', 'qrcode_img': ''},
            }),
        status: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return jsonResponse({'status': 1, 'data': {'status': 1}});
        },
      ));
      final svc = serviceWith(
          adapter, pollInterval: const Duration(milliseconds: 10));
      final events = <KugouQrPollResult>[];
      final stream = svc.startAutoLogin();
      final done = stream.listen(events.add).asFuture<void>();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      svc.cancel();
      svc.cancel(); // 二次调用不抛
      svc.dispose();
      await done; // 流已关闭 → done 完成

      // 取消后不再有新的 success/failed 泄漏（仅可能有 waiting）
      expect(events.any((e) => e.state == QrLoginState.success), isFalse);
    });

    test('二次 startAutoLogin 先取消旧流（无并发累积）', () async {
      final adapter = FakeAdapter(router(
        qr: (_) async => jsonResponse({
              'status': 1,
              'data': {'qrcode': 'K', 'qrcode_img': ''},
            }),
        status: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return jsonResponse({'status': 1, 'data': {'status': 4,
              'token': 'TK', 'userid': '88'}});
        },
      ));
      final svc = serviceWith(
          adapter, pollInterval: const Duration(milliseconds: 5));
      final s1 = svc.startAutoLogin();
      final closed = s1.listen((_) {}).asFuture<void>();
      final s2 = svc.startAutoLogin();
      await s2.toList();
      await closed; // 旧流应被关闭
      expect(adapter.maxActive, lessThanOrEqualTo(1));
    });
  });
}

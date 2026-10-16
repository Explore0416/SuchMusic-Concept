// test/services/update_service_test.dart
//
// 验证 UpdateService.rankBySpeed 的线路择优与「永不阻断更新」的回退语义。
// 使用本地 HttpServer 模拟快/慢线路，结果确定（不依赖外网）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/update_service.dart';

void main() {
  group('UpdateService.rankBySpeed', () {
    test('空列表 → 空', () async {
      expect(await UpdateService.rankBySpeed(const <String>[]), isEmpty);
    });

    test('单条线路 → 原样返回（不做无谓探测）', () async {
      expect(await UpdateService.rankBySpeed(const ['only']), const ['only']);
    });

    test('全部不可达 → 回退原顺序且不抛异常（保证测速永不阻断更新）', () async {
      // 127.0.0.1:1 立即拒绝连接 → 两条探测均为 0 → 应回退为原顺序
      const urls = ['http://127.0.0.1:1/a.apk', 'http://127.0.0.1:1/b.apk'];
      final ranked = await UpdateService.rankBySpeed(urls);
      expect(ranked, urls);
    });

    test('实测更快的线路被排到最前', () async {
      final fast = await _serve(delay: Duration.zero);
      final slow = await _serve(delay: const Duration(seconds: 3));
      try {
        final ranked = await UpdateService.rankBySpeed([slow.url, fast.url]);
        expect(ranked.first, fast.url, reason: '快线路应排在慢线路之前');
        expect(ranked.length, 2, reason: '线路数不得增减');
      } finally {
        await fast.close();
        await slow.close();
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}

class _Srv {
  _Srv(this.server);
  final HttpServer server;
  String get url => 'http://127.0.0.1:${server.port}/latest.apk';
  Future<void> close() => server.close(force: true);
}

/// 起一个本地线路：分 8 块返回共 256KB，每块前等待 [delay]。
/// delay=0 → 快；delay=3s → 4 秒窗口内只收到少量数据 → 被判为慢。
Future<_Srv> _serve({required Duration delay}) async {
  const chunk = 32768;
  const chunks = 8; // 8 × 32KB = 256KB
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    req.response.statusCode = 200;
    req.response.headers.contentLength = chunk * chunks;
    for (var i = 0; i < chunks; i++) {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      req.response.add(List<int>.filled(chunk, 0));
    }
    await req.response.close();
  });
  return _Srv(server);
}

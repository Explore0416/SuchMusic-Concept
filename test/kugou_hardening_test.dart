// 酷狗扫码登录 / 双盐值 / 响应容错 / 凭证解析 —— 加固用例（只测不改 lib）。
//
// 目标：锁定 UI 与网络边界上「不会崩、不会泄漏、不会误写、不会串盐」的行为。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/kugou_credential_service.dart';
import 'package:such_music/services/sources/kugou_config.dart';
import 'package:such_music/services/sources/kugou_credential_parser.dart';
import 'package:such_music/services/sources/kugou_device.dart';
import 'package:such_music/services/sources/kugou_login_models.dart';
import 'package:such_music/services/sources/kugou_login_service.dart';
import 'package:such_music/services/sources/kugou_sign.dart';
import 'package:such_music/services/sources/kugou_source.dart';
import 'package:such_music/utils/app_constants.dart';
import 'package:such_music/widgets/kugou_qr_panel.dart';

import 'support/fake_dio.dart';

/// 裸 HTML（非 JSON）响应体，模拟 CDN 挂掉返回错误页。
ResponseBody rawHtml(String body, {int status = 200}) => ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );

FakeAdapter routed(
        Map<String, Future<ResponseBody> Function(RequestOptions)> byHost) =>
    FakeAdapter((o) => byHost[o.uri.host]?.call(o) ??
        Future.value(jsonResponse({'status': 0, 'data': {}})));

void main() {
  // ── 1. 状态机补强 ──────────────────────────────────────────
  group('pollStatus 状态机（H-R1）', () {
    Future<KugouQrPollResult?> poll(Object? status) async {
      final adapter = FakeAdapter((_) async => jsonResponse({
            'status': 1,
            'data': status == null ? <String, dynamic>{} : {'status': status},
          }));
      return KugouLoginService(dio: fakeDio(adapter)).pollStatus('K');
    }

    test('3 → confirmed（锁定当前映射，防静默漂移）', () async {
      expect((await poll(3))!.state, QrLoginState.confirmed);
    });

    test('未知状态 5 / 缺 status → waiting（兜底不抛）', () async {
      expect((await poll(5))!.state, QrLoginState.waiting);
      expect((await poll(null))!.state, QrLoginState.waiting);
    });

    test('status 为字符串 "4" → success', () async {
      final adapter = FakeAdapter((_) async => jsonResponse({
            'status': 1,
            'data': {'status': '4', 'token': 'TK', 'userid': '88'},
          }));
      final r = await KugouLoginService(dio: fakeDio(adapter)).pollStatus('K');
      expect(r!.state, QrLoginState.success);
    });

    test('status=4 但缺 token/userid → success 且字段为 null（不崩）', () async {
      final r = await poll(4);
      expect(r!.state, QrLoginState.success);
      expect(r.token, isNull);
      expect(r.userId, isNull);
    });
  });

  // ── 2. 取消语义：取消后不再发起新轮询 ─────────────────────
  group('startAutoLogin 取消语义（H-R2）', () {
    test('cancel 后轮询请求数冻结（无新循环）', () async {
      var polls = 0;
      final adapter = FakeAdapter((o) {
        if (o.path.endsWith(KugouConfig.loginQrPath)) {
          return Future.value(jsonResponse({
            'status': 1,
            'data': {'qrcode': 'K', 'qrcode_img': ''},
          }));
        }
        polls++;
        return Future.value(jsonResponse({'status': 1, 'data': {'status': 1}}));
      });
      final svc = KugouLoginService(
        dio: fakeDio(adapter),
        pollInterval: const Duration(milliseconds: 5),
      );
      final sub = svc.startAutoLogin().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 40));
      svc.cancel();
      final frozen = polls;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(polls, frozen, reason: '取消后不得再有新的轮询请求');
      await sub.cancel();
    });

    test('取码失败后 cancel 多次幂等且不抛', () async {
      final adapter = FakeAdapter((_) async => throw Exception('net'));
      final svc = KugouLoginService(dio: fakeDio(adapter));
      await svc.startAutoLogin().toList();
      expect(() {
        svc.cancel();
        svc.cancel();
        svc.dispose();
      }, returnsNormally);
    });
  });

  // ── 3. 响应体容错：HTML / 非 JSON 不崩溃、不误判 ──────────
  group('_extractList 响应体容错（H-R3）', () {
    test('complexsearch 返回裸 HTML → 空，且回退 mobilecdn', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async =>
            rawHtml('<!DOCTYPE html><html><body>blocked</body></html>'),
        'mobilecdn.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'info': []}}),
      });
      final src = KugouSource.withDio(fakeDio(adapter));
      expect(await src.search('周杰伦'), isEmpty);
      expect(adapter.log.map((r) => r.uri.host).toList(),
          ['complexsearch.kugou.com', 'mobilecdn.kugou.com']);
    });

    test('主路径与兜底均返回裸 HTML → 返回空，不抛', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async => rawHtml('<html>err</html>'),
        'mobilecdn.kugou.com': (_) async => rawHtml('<html>err</html>'),
      });
      final src = KugouSource.withDio(fakeDio(adapter));
      expect(await src.search('x'), isEmpty);
    });

    test('text/html 内为合法 JSON 但缺 data.lists → 空回退', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async =>
            htmlJsonResponse({'status': 1, 'data': {'foo': 1}}),
        'mobilecdn.kugou.com': (_) async => jsonResponse({
              'status': 1,
              'data': {
                'info': [
                  {'songname': '稻香', 'singername': '周杰伦', 'hash': 'H'}
                ]
              }
            }),
      });
      final src = KugouSource.withDio(fakeDio(adapter));
      final songs = await src.search('x');
      expect(songs.single.name, '稻香');
    });
  });

  // ── 4. 盐值归属（防再次串盐）──────────────────────────────
  group('双盐值归属（H-R4）', () {
    test('搜索 signature == webSignature 且 != androidSignature', () async {
      final adapter = routed({
        'complexsearch.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'lists': []}}),
        'mobilecdn.kugou.com': (_) async =>
            jsonResponse({'status': 1, 'data': {'info': []}}),
      });
      await KugouSource.withDio(fakeDio(adapter)).search('t');
      final q = adapter.log
          .firstWhere((r) => r.uri.host == 'complexsearch.kugou.com')
          .queryParameters;
      final params = Map<String, dynamic>.from(q)..remove('signature');
      expect(q['signature'], KugouSign.webSignature(params));
      expect(q['signature'], isNot(KugouSign.androidSignature(params)));
    });

    test('gateway 取地址 signature == androidSignature 且 != webSignature', () async {
      // 预置已注册设备：跳过真实设备注册网络请求
      KugouDevice.overrideForTest(
          dfid: '0jAbCdEfGhIjKlMnOpQrSt', registered: true);
      final adapter = routed({
        'gateway.kugou.com': (_) async => jsonResponse({
              'data': [
                {'url': 'https://x/y.mp3'}
              ]
            }),
      });
      await KugouSource.withDio(fakeDio(adapter)).getSongUrl(const SongModel(
        id: '1',
        name: 'n',
        artist: 'a',
        album: '',
        hash: 'B3A52A7A958BF0AED0EBFBA2E9A818B7',
      ));
      final q = adapter.log.single.queryParameters;
      final params = Map<String, dynamic>.from(q)..remove('signature');
      expect(q['signature'], KugouSign.androidSignature(params));
      expect(q['signature'], isNot(KugouSign.webSignature(params)));
      // key 仍为概念版 lite 盐
      expect(q['key'], KugouSign.playKey(
        hash: 'b3a52a7a958bf0aed0ebfba2e9a818b7',
        mid: KugouDevice.mid,
        userId: '0',
        salt: KugouConfig.keySaltLite,
      ));
    });

    test('别名语义：loginSecret==webSecret、secret==androidSecretLite', () {
      expect(KugouConfig.loginSecret, KugouConfig.webSecret);
      expect(KugouConfig.secret, KugouConfig.androidSecretLite);
      expect(KugouConfig.secret, isNot(KugouConfig.webSecret));
    });
  });

  // ── 5. 凭证解析边界 ───────────────────────────────────────
  group('parseCredentialText 边界（H-R5）', () {
    test('空值 token= / userid= → null', () {
      final r = parseCredentialText('token=; userid=');
      expect(r.token, isNull);
      expect(r.userId, isNull);
    });

    test('access_token 不被误判为 token（前置边界）', () {
      expect(parseCredentialText('access_token=abc').token, isNull);
    });

    test('userid=0 视为合法值', () {
      expect(parseCredentialText('userid=0').userId, '0');
    });

    test('多个 token → 取首个', () {
      expect(parseCredentialText('token=first; token=second').token, 'first');
    });

    test('纯噪声 HTML → null 且不抛', () {
      final r = parseCredentialText('<html>no creds</html>');
      expect(r.token, isNull);
      expect(r.userId, isNull);
    });
  });

  group('凭证写入守卫（H-R6）', () {
    test('空 token/userid → save 返回 false 且不落库', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await KugouCredentialService.instance.clear();
      expect(await KugouCredentialService.instance.saveFromLogin('', ''), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.kugouToken), isNull);
    });
  });

  // ── 7. 二维码渲染降级 ─────────────────────────────────────
  group('KugouQrPanel 降级（H-R7）', () {
    Future<void> pump(WidgetTester tester, String image) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: KugouQrPanel(
                state: QrLoginState.waiting,
                session: KugouQrSession(
                  key: 'K',
                  imageDataUri: image,
                  expiresAt: DateTime(2030),
                ),
              ),
            ),
          ),
        );

    testWidgets('非 data-URI 字符串 → 回退 qr_flutter，不崩溃', (tester) async {
      await pump(tester, 'https://example.com/not-an-image');
      expect(find.byType(QrImageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('data:image 前缀但空 base64 → 不崩溃', (tester) async {
      await pump(tester, 'data:image/png;base64,');
      expect(tester.takeException(), isNull);
    });
  });
}

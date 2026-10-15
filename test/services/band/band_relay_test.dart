// 局域网中继 · 纯逻辑与安全判定单测。
//
// 覆盖：令牌校验（正确 / 错误 / 缺失）、非私网来源拒绝、路径校验、
// 信封在 WS 与 interconnect 两条路径行为一致、req.id 去重跨连接幂等、
// 连接 / 断开状态机、二进制帧与文本帧等价、握手超时。
//
// 全程确定性、不依赖真实网络（socket 收敛为 RelaySocket 抽象，核心为纯逻辑）。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/band/band_protocol.dart';
import 'package:such_music/services/band/band_relay_core.dart';
import 'package:such_music/services/band/band_relay_security.dart';
import 'package:such_music/services/band/band_router.dart';
import 'package:such_music/services/band/band_ws_server.dart';

import 'band_test_support.dart';

/// 固定时钟，保证响应的 `ts` / `t` 确定性。
int _fixedClock() => 1730000000000;

const String _tok = 'tok-00112233445566778899aabbccddeeff';

LanRelayCore _core({String token = _tok, BandRouter? router}) => LanRelayCore(
      router: router ?? BandRouter(),
      token: token,
      clock: _fixedClock,
    );

RelayDecision _accept(
  LanRelayCore core, {
  String id = 'c1',
  String remote = '192.168.1.9',
  String path = '/suchmusic',
  String? queryToken = _tok,
  String? authorization,
}) =>
    core.handleConnect(
      connectionId: id,
      requestPath: path,
      remoteAddress: remote,
      queryToken: queryToken,
      authorization: authorization,
    );

/// 经 **interconnect（直连 handleRaw）** 路径执行一次请求。
Future<(String?, List<String>)> _runDirect(
  String id,
  String method, [
  Map<String, dynamic> payload = const {},
]) async {
  final port = TestBandPort();
  final router = BandRouter(clock: _fixedClock)..attach(port);
  final json = BandEnvelope.request(id, method, payload: payload).encode();
  final res = await router.handleRaw(json);
  final calls = List<String>.from(port.calls);
  router.dispose();
  await port.closeAll();
  return (res, calls);
}

/// 会话握手帧（会话就绪闸门：命令前必须先完成 `sys.hello`）。
/// [nick] 用于让不同会话使用不同 `id`，贴近真实客户端「`w-`/`b-` + bootId」命名。
String _helloJson({String nick = '0b12'}) => BandEnvelope.request(
      'h-$nick-0000',
      'sys.hello',
      payload: <String, dynamic>{
        'role': 'windows',
        'proto': <int>[1],
        'caps': kAllCaps,
      },
    ).encode();

/// 经 **局域网 WS（core.onFrame）** 路径执行一次请求（内部先完成握手）。
Future<(String?, List<String>)> _runWs(
  String id,
  String method, [
  Map<String, dynamic> payload = const {},
]) async {
  final port = TestBandPort();
  final router = BandRouter(clock: _fixedClock)..attach(port);
  final core = _core(router: router);
  _accept(core);
  await core.onFrame('c1', _helloJson()); // 先握手（否则命令会被会话就绪闸门拒绝）
  final json = BandEnvelope.request(id, method, payload: payload).encode();
  final out = await core.onFrame('c1', json);
  final calls = List<String>.from(port.calls);
  router.dispose();
  await port.closeAll();
  return (out.isEmpty ? null : out.first, calls);
}

void main() {
  group('令牌校验（正确 / 错误 / 缺失）', () {
    test('正确令牌：接受并登记连接', () {
      final core = _core();
      final d = _accept(core);
      expect(d.accepted, isTrue);
      expect(d.statusCode, 101);
      expect(core.connectionCount, 1);
    });

    test('错误令牌：401 拒绝且不登记连接', () {
      final core = _core();
      final d = _accept(core, queryToken: 'wrong-token');
      expect(d.accepted, isFalse);
      expect(d.statusCode, 401);
      expect(core.connectionCount, 0);
      expect(core.lastConnectionSummary, contains('令牌'));
    });

    test('缺失令牌（query 与 header 均无）：401', () {
      final core = _core();
      final d = _accept(core, queryToken: null);
      expect(d.accepted, isFalse);
      expect(d.statusCode, 401);
      expect(core.connectionCount, 0);
    });

    test('空串令牌：401', () {
      final core = _core();
      final d = _accept(core, queryToken: '');
      expect(d.accepted, isFalse);
      expect(d.statusCode, 401);
    });

    test('Authorization: Bearer <token> 亦可授权', () {
      final core = _core();
      final d = _accept(core, queryToken: null, authorization: 'Bearer $_tok');
      expect(d.accepted, isTrue);
    });

    test('verifyToken 语义（缺失 / 空 / 服务端空一律失败）', () {
      expect(RelaySecurity.verifyToken('abc', 'abc'), isTrue);
      expect(RelaySecurity.verifyToken('abc', 'abd'), isFalse);
      expect(RelaySecurity.verifyToken('abc', null), isFalse);
      expect(RelaySecurity.verifyToken('abc', ''), isFalse);
      expect(RelaySecurity.verifyToken('', ''), isFalse);
    });

    test('generateToken：注入 Random 确定性 + 长度 + 字符集', () {
      final t1 = RelaySecurity.generateToken(random: Random(42), bytes: 8);
      final t2 = RelaySecurity.generateToken(random: Random(42), bytes: 8);
      expect(t1, t2);
      expect(t1, hasLength(16));
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(t1), isTrue);
    });

    test('tokenEquals 常量时间比较正确性', () {
      expect(RelaySecurity.tokenEquals('hello', 'hello'), isTrue);
      expect(RelaySecurity.tokenEquals('hello', 'hellp'), isFalse);
      expect(RelaySecurity.tokenEquals('hello', 'hell'), isFalse);
      expect(RelaySecurity.tokenEquals('hello', 'helloo'), isFalse);
      expect(RelaySecurity.tokenEquals('', ''), isTrue);
    });
  });

  group('私网来源限制', () {
    test('isPrivate 判定表（IPv4 / IPv6 / 非法）', () {
      expect(RelaySecurity.isPrivate('192.168.1.5'), isTrue);
      expect(RelaySecurity.isPrivate('10.0.0.3'), isTrue);
      expect(RelaySecurity.isPrivate('172.16.5.5'), isTrue);
      expect(RelaySecurity.isPrivate('172.31.255.254'), isTrue);
      expect(RelaySecurity.isPrivate('172.32.0.1'), isFalse);
      expect(RelaySecurity.isPrivate('169.254.10.10'), isTrue);
      expect(RelaySecurity.isPrivate('127.0.0.1'), isFalse); // 回环一律拒绝
      expect(RelaySecurity.isPrivate('127.9.9.9'), isFalse); // 127/8 整段拒绝
      expect(RelaySecurity.isPrivate('8.8.8.8'), isFalse);
      expect(RelaySecurity.isPrivate('1.1.1.1'), isFalse);
      expect(RelaySecurity.isPrivate('::1'), isFalse); // IPv6 回环拒绝
      expect(RelaySecurity.isPrivate('fe80::1'), isTrue);
      expect(RelaySecurity.isPrivate('fd12:3456::1'), isTrue);
      expect(RelaySecurity.isPrivate('2001:4860::1'), isFalse);
      expect(RelaySecurity.isPrivate('::ffff:192.168.1.5'), isTrue);
      expect(RelaySecurity.isPrivate('fe80::1%wlan0'), isTrue);
      expect(RelaySecurity.isPrivate(null), isFalse);
      expect(RelaySecurity.isPrivate(''), isFalse);
      expect(RelaySecurity.isPrivate('not-an-ip'), isFalse);
    });

    test('非私网来源 → 403 拒绝且不登记连接', () {
      final core = _core();
      final d = _accept(core, remote: '8.8.8.8');
      expect(d.accepted, isFalse);
      expect(d.statusCode, 403);
      expect(core.connectionCount, 0);
    });
  });

  group('路径校验', () {
    test('非 /suchmusic 路径 → 404', () {
      final core = _core();
      final d = _accept(core, path: '/foo');
      expect(d.accepted, isFalse);
      expect(d.statusCode, 404);
    });

    test('正确路径 /suchmusic → 接受', () {
      final core = _core();
      expect(_accept(core, path: '/suchmusic').accepted, isTrue);
    });
  });

  group('信封在 WS 与 interconnect 两条路径下行为一致', () {
    test('playback.next：响应 JSON 与副作用日志完全一致', () async {
      final a = await _runDirect('w-0b12-0001', 'playback.next');
      final b = await _runWs('w-0b12-0001', 'playback.next');
      expect(b.$1, a.$1);
      expect(b.$2, a.$2);
      expect(a.$2, contains('next'));
    });

    test('playback.pause：两条路径一致', () async {
      final a = await _runDirect('w-0b12-0002', 'playback.pause');
      final b = await _runWs('w-0b12-0002', 'playback.pause');
      expect(b.$1, a.$1);
      expect(b.$2, a.$2);
    });

    test('state.get：两条路径一致（时钟注入 → 快照可比）', () async {
      final a = await _runDirect('w-0b12-0003', 'state.get');
      final b = await _runWs('w-0b12-0003', 'state.get');
      expect(b.$1, a.$1);
    });

    test('未知方法：两条路径一致返回 E_UNSUPPORTED', () async {
      final a = await _runDirect('w-0b12-0004', 'does.not.exist');
      final b = await _runWs('w-0b12-0004', 'does.not.exist');
      expect(b.$1, a.$1);
      expect(a.$1, contains('E_UNSUPPORTED'));
    });
  });

  group('req.id 去重跨连接仍然幂等', () {
    test('两个连接发同一 req.id → 只执行一次，响应一致', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      _accept(core, id: 'cA', remote: '192.168.1.2');
      _accept(core, id: 'cB', remote: '192.168.1.3');
      // 两条连接各自完成握手（会话就绪闸门：命令前必须握手）
      await core.onFrame('cA', _helloJson(nick: '0a0a'));
      await core.onFrame('cB', _helloJson(nick: '0b0b'));

      final json =
          BandEnvelope.request('w-0b12-0001', 'playback.next').encode();
      final r1 = await core.onFrame('cA', json);
      final r2 = await core.onFrame('cB', json);

      expect(port.calls.where((c) => c == 'next').length, 1, reason: '跨连接去重');
      expect(r1, r2);
    });

    test('WS 与 interconnect 共用同一 router → 去重跨路径生效', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);
      await core.onFrame('c1', _helloJson()); // WS 会话先握手

      final json =
          BandEnvelope.request('b-7fa1-0007', 'playback.next').encode();
      final direct = await router.handleRaw(json); // interconnect 路径
      final ws = await core.onFrame('c1', json); // WS 路径
      expect(ws.single, direct);
      expect(port.calls.where((c) => c == 'next').length, 1);
    });
  });

  group('连接 / 断开状态机', () {
    test('accept → handshaking → hello → ready → close → 移除', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      expect(_accept(core).accepted, isTrue);
      expect(core.connectionCount, 1);
      expect(core.lastConnection!.state, RelayConnState.handshaking);

      final hello = BandEnvelope.request('w-0001-0000', 'sys.hello', payload: {
        'role': 'windows',
        'proto': [1],
        'caps': ['playback', 'queue'],
      }).encode();
      await core.onFrame('c1', hello);
      expect(core.lastConnection!.state, RelayConnState.ready);
      expect(core.lastConnection!.role, 'windows');
      expect(core.lastConnectionSummary, contains('就绪'));

      core.onClose('c1');
      expect(core.connectionCount, 0);
      // 已关闭连接再收帧 → 无响应
      expect(await core.onFrame('c1', '{}'), isEmpty);
    });

    test('握手超时：超时连接被列出待关闭', () {
      var now = 1000;
      final core = LanRelayCore(
        router: BandRouter(),
        token: _tok,
        clock: () => now,
        handshakeTimeoutMs: 5000,
      );
      _accept(core);
      expect(core.handshakeTimeouts(), isEmpty);

      now = 5001; // 4001ms ≤ 5000 → 仍未超时
      expect(core.handshakeTimeouts(), isEmpty);

      now = 7000; // 6000ms > 5000 → 超时
      expect(core.handshakeTimeouts(), ['c1']);
    });

    test('二进制帧（UTF-8）与文本帧等价', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);

      final json = BandEnvelope.request('w-1-1', 'sys.ping').encode();
      final textRes = await core.onFrame('c1', json);
      final binRes = await core.onFrame('c1', utf8.encode(json));
      expect(binRes, textRes);
      expect(textRes.single, contains('"t":1730000000000'));
    });

    test('多连接计数与逐个断开', () {
      final core = _core(router: BandRouter());
      _accept(core, id: 'c1', remote: '192.168.1.2');
      _accept(core, id: 'c2', remote: '192.168.1.3');
      _accept(core, id: 'c3', remote: '192.168.1.4');
      expect(core.connectionCount, 3);
      core.onClose('c2');
      expect(core.connectionCount, 2);
      expect(core.connections.map((c) => c.id), containsAll(['c1', 'c3']));
    });
  });

  group('BandRouter.handleRaw（统一入口）', () {
    test('非法 JSON → null', () async {
      final router = BandRouter();
      expect(await router.handleRaw('{oops'), isNull);
      expect(await router.handleRaw('[1,2,3]'), isNull);
    });

    test('evt → null（无需回执）', () async {
      final router = BandRouter();
      expect(await router.handleRaw(BandEnvelope.event('player.song').encode()),
          isNull);
    });

    test('req → 返回响应 JSON，可再次 decode', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      final out =
          await router.handleRaw(BandEnvelope.request('b-1', 'sys.ping').encode());
      expect(out, isNotNull);
      expect(BandEnvelope.decode(out!).type, 'res');
    });
  });

  group('私网接口枚举（真实但不依赖外网）', () {
    test('lanAddresses 不含 0.0.0.0 / 回环，且均为私网', () async {
      final list = await BandWsServer.lanAddresses();
      for (final a in list) {
        expect(a.address, isNot('0.0.0.0'));
        expect(a.isLoopback, isFalse);
        expect(RelaySecurity.isPrivate(a.address), isTrue);
      }
    });
  });
}

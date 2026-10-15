// 局域网中继加固（v0.14.1）· 回归单测。
//
// 覆盖 QA 定位的三项问题：
//   1) 【安全】会话就绪闸门：READY（成功 sys.hello）之前仅放行 sys.*，
//      其余方法一律 E_NOT_READY 且**不产生任何副作用**（用 TestBandPort.calls 桩断言）；
//      两条传输路径（手环 interconnect / 局域网 WS）行为一致；握手成功后命令恢复正常。
//   2) 【正确性】定向投递：请求-响应类（res / xfer.chunk）只回发起请求的那条连接，
//      全局事件（player.*）仍广播；req.id 去重语义不受影响。
//   3) 【安全】拒绝回环来源（127/8、::1），保留既有私网 / 链路本地判定。
//
// 全程确定性、不依赖真实网络（socket 收敛为 RelaySocket 抽象，核心为纯逻辑）。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/audio_player_service.dart';
import 'package:such_music/services/band/band_protocol.dart';
import 'package:such_music/services/band/band_relay_core.dart';
import 'package:such_music/services/band/band_relay_security.dart';
import 'package:such_music/services/band/band_router.dart';

import 'band_test_support.dart';

int _fixedClock() => 1730000000000;

const String _tok = 'tok-00112233445566778899aabbccddeeff';

LanRelayCore _core({BandRouter? router}) => LanRelayCore(
      router: router ?? BandRouter(),
      token: _tok,
      clock: _fixedClock,
    );

RelayDecision _accept(
  LanRelayCore core, {
  String id = 'c1',
  String remote = '192.168.1.9',
  String? queryToken = _tok,
}) =>
    core.handleConnect(
      connectionId: id,
      requestPath: '/suchmusic',
      remoteAddress: remote,
      queryToken: queryToken,
    );

/// 握手帧（caps 取全量 → 握手后各命令都在能力范围内）。
String _hello(String id, {String role = 'windows'}) =>
    BandEnvelope.request(id, 'sys.hello', payload: <String, dynamic>{
      'role': role,
      'proto': <int>[1],
      'caps': kAllCaps,
    }).encode();

String _req(String id, String method, [Map<String, dynamic> payload = const {}]) =>
    BandEnvelope.request(id, method, payload: payload).encode();

BandEnvelope _decode(String raw) => BandEnvelope.decode(raw);

void main() {
  // ─────────────────────────────────────────────────────────────
  group('问题 1 · 会话就绪闸门（READY 之前仅放行 sys.*）', () {
    test('WS 路径：未握手 playback.next / queue.play 被拒且无副作用', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core); // 已接受连接，但尚未 sys.hello

      final next = await core.onFrame('c1', _req('w-1', 'playback.next'));
      expect(_decode(next.single).type, 'err');
      expect(_decode(next.single).payload['code'], 'E_NOT_READY');

      final play = await core.onFrame(
          'c1', _req('w-2', 'queue.play', {'index': 0}));
      expect(_decode(play.single).payload['code'], 'E_NOT_READY');

      // 副作用桩：两条命令都不得触达播放器端口
      expect(port.calls, isEmpty, reason: '闸门拒绝不得产生任何副作用');
    });

    test('WS 路径：非 sys.* 的只读方法也被闸门拦（state.get）', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);

      final res = await core.onFrame('c1', _req('w-1', 'state.get'));
      expect(_decode(res.single).payload['code'], 'E_NOT_READY');
    });

    test('WS 路径：sys.ping 未握手仍可通过', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);

      final res = await core.onFrame('c1', _req('w-1', 'sys.ping'));
      expect(_decode(res.single).type, 'res');
      expect(_decode(res.single).payload['t'], 1730000000000);
    });

    test('WS 路径：握手成功后命令恢复正常', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);

      final hello = await core.onFrame('c1', _hello('h-1'));
      expect(_decode(hello.single).type, 'res');
      expect(router.isSessionReady('c1'), isTrue);

      final res = await core.onFrame('c1', _req('w-2', 'playback.next'));
      expect(_decode(res.single).type, 'res');
      expect(port.calls, contains('next'), reason: '握手后命令应真正执行');
    });

    test('interconnect 路径：未握手命令被拒且无副作用', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });

      final res = await router.handleRaw(
          _req('b-1', 'playback.next'),
          session: kBandSession);
      expect(_decode(res!).payload['code'], 'E_NOT_READY');
      expect(port.calls, isEmpty);

      // 握手后恢复
      await router.handleRaw(_hello('h-1', role: 'band'), session: kBandSession);
      expect(router.isSessionReady(kBandSession), isTrue);
      final ok = await router.handleRaw(
          _req('b-2', 'playback.next'),
          session: kBandSession);
      expect(_decode(ok!).type, 'res');
      expect(port.calls, contains('next'));
    });

    test('两条路径对同一未握手命令行为完全一致', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core); // c1 未握手

      final req = _req('x-1', 'playback.next');
      final wsOut = (await core.onFrame('c1', req)).single; // WS 路径
      final icOut = await router.handleRaw(req, session: kBandSession); // interconnect 路径

      expect(wsOut, icOut);
      expect(_decode(wsOut).payload['code'], 'E_NOT_READY');
      expect(port.calls, isEmpty);
    });

    test('闸门拒绝不写进去重缓存：握手后同 id 重发仍可执行', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);

      const id = 'w-fixed-0001';
      final pre = await core.onFrame('c1', _req(id, 'playback.next'));
      expect(_decode(pre.single).payload['code'], 'E_NOT_READY');
      expect(port.calls, isEmpty);

      await core.onFrame('c1', _hello('h-1'));
      final post = await core.onFrame('c1', _req(id, 'playback.next'));
      expect(_decode(post.single).type, 'res');
      expect(port.calls.where((c) => c == 'next').length, 1,
          reason: '同一 id 在闸门拒绝后不应被去重缓存“粘住”');
    });

    test('握手失败（无公共版本）后仍被闸门拦', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);

      final bad = await core.onFrame(
          'c1', _req('h-1', 'sys.hello', {'proto': <int>[2], 'caps': kAllCaps}));
      expect(_decode(bad.single).type, 'err');
      expect(router.isSessionReady('c1'), isFalse);

      final res = await core.onFrame('c1', _req('w-2', 'playback.pause'));
      expect(_decode(res.single).payload['code'], 'E_NOT_READY');
      expect(port.calls, isEmpty);
    });

    test('resetSession（重连 / 断开）清除就绪状态 → 需重新握手', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core);
      await core.onFrame('c1', _hello('h-1'));
      expect(router.isSessionReady('c1'), isTrue);

      router.resetSession('c1'); // 模拟重连
      final res = await core.onFrame('c1', _req('w-2', 'playback.next'));
      expect(_decode(res.single).payload['code'], 'E_NOT_READY');
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('问题 2 · 定向投递（请求-响应只回发起连接，全局事件仍广播）', () {
    test('A 触发的 xfer.chunk 分片 target == A，且不投递给 B', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      final events = <BandEnvelope>[];
      final sub = router.onOutgoing.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        router.dispose();
        await port.closeAll();
      });
      _accept(core, id: 'cA', remote: '192.168.1.2');
      _accept(core, id: 'cB', remote: '192.168.1.3');
      await core.onFrame('cA', _hello('h-a'));
      await core.onFrame('cB', _hello('h-b'));

      // A 发起大载荷搜索 → 触发分片
      final res = await core.onFrame(
          'cA', _req('w-a-1', 'search.song', {'keyword': '周杰伦', 'limit': 50}));
      await pumpEventQueue();

      final resEnv = _decode(res.single);
      expect(resEnv.id, 'w-a-1');
      expect(resEnv.payload['__chunked'], isTrue);

      final chunks = events.where((e) => e.event == 'xfer.chunk').toList();
      expect(chunks, isNotEmpty);
      expect(chunks.every((e) => e.target == 'cA'), isTrue,
          reason: '分片必须定向到发起连接 cA');

      // 投递裁决：仅 cA 命中，cB 收不到
      expect(outgoingTargets(chunks.first, <String>{'cA', 'cB'}), <String>{'cA'});
      expect(outgoingTargets(chunks.first, <String>{'cB'}), isEmpty,
          reason: 'A 的分片不得投递给 B');
    });

    test('player.* 全局事件（target == null）仍广播给全部连接', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final events = <BandEnvelope>[];
      final sub = router.onOutgoing.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        router.dispose();
        await port.closeAll();
      });
      // 需先握手让 capability 门禁放行 player.mode（playmode）
      await router.handleRaw(_hello('h-1'), session: kBandSession);
      final before = events.length;

      port.emitMode(PlayMode.shuffle);
      await pumpEventQueue();

      final mode = events
          .sublist(before)
          .firstWhere((e) => e.event == 'player.mode');
      expect(mode.target, isNull, reason: '全局事件不应带定向目标');
      expect(outgoingTargets(mode, <String>{'cA', 'cB'}),
          <String>{'cA', 'cB'}, reason: '全局事件应广播给全部在线连接');
    });

    test('定向帧目标不在线 → 丢弃（不误发给其它连接）', () {
      final directed = BandEnvelope.event('xfer.chunk',
          payload: const <String, dynamic>{}, id: 'p-1', target: 'cA');
      expect(outgoingTargets(directed, <String>{'cB', 'cC'}), isEmpty);
      expect(outgoingTargets(directed, <String>{'cA', 'cB'}), <String>{'cA'});
    });

    test('sys.hello_ack 也定向回发起握手的会话', () async {
      final router = BandRouter(clock: _fixedClock);
      final events = <BandEnvelope>[];
      final sub = router.onOutgoing.listen(events.add);
      addTearDown(() async {
        await sub.cancel();
        router.dispose();
      });

      await router.handleRaw(_hello('h-1'), session: 'cX');
      await pumpEventQueue();

      final ack = events.firstWhere((e) => e.event == 'sys.hello_ack');
      expect(ack.target, 'cX');
    });

    test('req.id 去重语义不受定向投递改动影响（跨连接仍只执行一次）', () async {
      final port = TestBandPort();
      final router = BandRouter(clock: _fixedClock)..attach(port);
      final core = _core(router: router);
      addTearDown(() async {
        router.dispose();
        await port.closeAll();
      });
      _accept(core, id: 'cA', remote: '192.168.1.2');
      _accept(core, id: 'cB', remote: '192.168.1.3');
      await core.onFrame('cA', _hello('h-a'));
      await core.onFrame('cB', _hello('h-b'));

      final req = _req('w-dup-1', 'playback.next');
      final r1 = await core.onFrame('cA', req);
      final r2 = await core.onFrame('cB', req);
      expect(r1, r2);
      expect(port.calls.where((c) => c == 'next').length, 1);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('问题 3 · 拒绝回环来源（保留既有私网判定）', () {
    test('isPrivate：回环一律拒绝', () {
      expect(RelaySecurity.isPrivate('127.0.0.1'), isFalse);
      expect(RelaySecurity.isPrivate('127.0.0.5'), isFalse);
      expect(RelaySecurity.isPrivate('127.255.255.254'), isFalse);
      expect(RelaySecurity.isPrivate('::1'), isFalse);
      expect(RelaySecurity.isPrivate('::ffff:127.0.0.1'), isFalse);
    });

    test('isPrivate：私网 / 链路本地 / IPv4-mapped 判定保留', () {
      expect(RelaySecurity.isPrivate('10.0.0.3'), isTrue);
      expect(RelaySecurity.isPrivate('172.16.5.5'), isTrue);
      expect(RelaySecurity.isPrivate('192.168.1.5'), isTrue);
      expect(RelaySecurity.isPrivate('169.254.10.10'), isTrue);
      expect(RelaySecurity.isPrivate('fe80::1'), isTrue);
      expect(RelaySecurity.isPrivate('fd12:3456::1'), isTrue);
      expect(RelaySecurity.isPrivate('::ffff:192.168.1.5'), isTrue);
      expect(RelaySecurity.isPrivate('fe80::1%wlan0'), isTrue);
      expect(RelaySecurity.isPrivate('8.8.8.8'), isFalse);
      expect(RelaySecurity.isPrivate('2001:4860::1'), isFalse);
    });

    test('handleConnect：回环来源 → 403 拒绝且不登记连接', () {
      for (final remote in <String>['127.0.0.1', '127.0.0.9', '::1']) {
        final core = _core(router: BandRouter());
        final d = core.handleConnect(
          connectionId: 'c1',
          requestPath: '/suchmusic',
          remoteAddress: remote,
          queryToken: _tok,
        );
        expect(d.accepted, isFalse, reason: '回环来源 $remote 必须被拒');
        expect(d.statusCode, 403);
        expect(core.connectionCount, 0);
      }
    });

    test('handleConnect：私网来源仍可正常接受', () {
      final core = _core(router: BandRouter());
      final d = _accept(core, remote: '192.168.1.9');
      expect(d.accepted, isTrue);
      expect(core.connectionCount, 1);
    });
  });

  // ─────────────────────────────────────────────────────────────
  group('回归 · 协议字段冻结（target 不参与序列化）', () {
    test('target 不影响 encode/decode（线上协议不变）', () {
      final env = BandEnvelope.event('xfer.chunk',
          payload: <String, dynamic>{'tid': 't-1'}, id: 'p-1', target: 'cA');
      final json = env.encode();
      expect(json.contains('target'), isFalse, reason: 'target 不得出现在线协议里');
      final round = BandEnvelope.decode(json);
      expect(round.target, isNull);
      expect(jsonEncode(round.toJson()), json);

      // 未带 target 的信封反序列化后 target 为 null（全局事件语义）
      final plain = BandEnvelope.decode(
          BandEnvelope.event('player.mode', payload: const {}).encode());
      expect(plain.target, isNull);
    });

    test('Random 生成的回环判定不误伤私网地址（抽样）', () {
      final rnd = Random(7);
      for (var i = 0; i < 200; i++) {
        final a = rnd.nextInt(256);
        final b = rnd.nextInt(256);
        final ip = '$a.$b.${rnd.nextInt(256)}.${rnd.nextInt(256)}';
        final expected = a == 10 ||
            (a == 172 && b >= 16 && b <= 31) ||
            (a == 192 && b == 168) ||
            (a == 169 && b == 254);
        expect(RelaySecurity.isPrivate(ip), expected, reason: ip);
      }
    });
  });
}

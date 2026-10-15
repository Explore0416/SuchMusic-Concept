// 手环协议纯逻辑单测（ARCH §3）：信封编解码 / 字段校验 / 版本·能力协商 / 模式映射。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/band/band_protocol.dart';

void main() {
  group('BandEnvelope 编解码往返', () {
    test('req：含 id / method / payload', () {
      final env = BandEnvelope.request('b-7fa1-0007', 'playback.next',
          payload: const {'x': 1}, ts: 1730000000000);
      final decoded = BandEnvelope.decode(env.encode());
      expect(decoded.v, 1);
      expect(decoded.type, 'req');
      expect(decoded.id, 'b-7fa1-0007');
      expect(decoded.method, 'playback.next');
      expect(decoded.event, isNull);
      expect(decoded.payload, {'x': 1});
      expect(decoded.ts, 1730000000000);
    });

    test('res：复用 id、payload 恒存在', () {
      final env = BandEnvelope.response('b-7fa1-0007', payload: const {'ok': true});
      final decoded = BandEnvelope.decode(env.encode());
      expect(decoded.type, 'res');
      expect(decoded.id, 'b-7fa1-0007');
      expect(decoded.payload, {'ok': true});
    });

    test('err：携带 code / message', () {
      final env = BandEnvelope.error('b-1', 'E_TIMEOUT', 'timeout');
      final decoded = BandEnvelope.decode(env.encode());
      expect(decoded.type, 'err');
      expect(decoded.payload['code'], 'E_TIMEOUT');
      expect(decoded.payload['message'], 'timeout');
    });

    test('evt：含 event、id 可为空', () {
      final env = BandEnvelope.event('player.song', payload: const {'song': {}});
      final decoded = BandEnvelope.decode(env.encode());
      expect(decoded.type, 'evt');
      expect(decoded.event, 'player.song');
      expect(decoded.id, isNull);
      expect(decoded.payload, {'song': {}});
    });

    test('中文 / 特殊字符 payload 往返无损', () {
      final env = BandEnvelope.event('lyric.line',
          payload: const {'text': '晴天「周杰伦」\\n"引号"'});
      final decoded = BandEnvelope.decode(env.encode());
      expect(decoded.payload['text'], '晴天「周杰伦」\\n"引号"');
    });
  });

  group('BandEnvelope 字段校验', () {
    test('非对象 → E_BADREQ', () {
      expect(
        () => BandEnvelope.decode('[1,2,3]'),
        throwsA(isA<BandEnvelopeException>()
            .having((e) => e.code, 'code', BandErrorCode.badReq)),
      );
    });

    test('缺少 / 非法 v → E_BADREQ', () {
      expect(BandEnvelope.validate('{"type":"req","id":"b-1","method":"m"}'),
          'v must be int');
      expect(BandEnvelope.validate('{"v":"1","type":"req","id":"b-1","method":"m"}'),
          'v must be int');
    });

    test('未知 type → E_BADREQ', () {
      expect(BandEnvelope.validate('{"v":1,"type":"foo","payload":{}}'),
          'type must be one of [req, res, evt, err]');
    });

    test('req 缺 method → E_BADREQ', () {
      expect(BandEnvelope.validate('{"v":1,"type":"req","id":"b-1"}'),
          'req requires non-empty method');
    });

    test('req 缺 id → E_BADREQ', () {
      expect(BandEnvelope.validate('{"v":1,"type":"req","method":"m"}'),
          'req requires non-empty id');
    });

    test('evt 缺 event → E_BADREQ', () {
      expect(BandEnvelope.validate('{"v":1,"type":"evt","payload":{}}'),
          'evt requires non-empty event');
    });

    test('payload 非对象 → E_BADREQ', () {
      expect(
          BandEnvelope.validate(
              '{"v":1,"type":"res","id":"b-1","payload":[1]}'),
          'payload must be an object');
    });

    test('payload 缺省视为空对象（合法）', () {
      final env = BandEnvelope.decode('{"v":1,"type":"res","id":"b-1"}');
      expect(env.payload, isEmpty);
    });

    test('非法 JSON → 校验返回描述', () {
      expect(BandEnvelope.validate('{oops'), isNotNull);
    });

    test('合法 req 校验通过返回 null', () {
      expect(
          BandEnvelope.validate(
              '{"v":1,"type":"req","id":"b-1","method":"sys.ping","payload":{}}'),
          isNull);
    });
  });

  group('版本协商', () {
    test('交集取最大', () {
      expect(BandProtocol.negotiateVersion([1, 2, 3], [2, 3, 4]), 3);
      expect(BandProtocol.negotiateVersion([1], [1]), 1);
    });

    test('交集为空 → null', () {
      expect(BandProtocol.negotiateVersion([2], [1]), isNull);
      expect(BandProtocol.negotiateVersion([], [1]), isNull);
    });

    test('顺序无关', () {
      expect(BandProtocol.negotiateVersion([3, 1, 2], [1, 2, 3]), 3);
    });
  });

  group('能力协商', () {
    test('取交集、去重、排序（确定性）', () {
      final caps = BandProtocol.negotiateCaps(
        ['playback', 'queue', 'playback', 'nope'],
        ['queue', 'playback', 'lyric'],
      );
      expect(caps, ['playback', 'queue']);
    });

    test('无交集 → 空列表', () {
      expect(BandProtocol.negotiateCaps(['cover'], ['lyric']), isEmpty);
    });
  });

  group('能力表查询', () {
    test('methodCap', () {
      expect(BandProtocol.methodCap('playback.next'), 'playback');
      expect(BandProtocol.methodCap('playback.setMode'), 'playmode');
      expect(BandProtocol.methodCap('playback.setVolume'), 'volume');
      expect(BandProtocol.methodCap('sys.hello'), isNull);
    });

    test('eventCap', () {
      expect(BandProtocol.eventCap('player.progress'), 'playback');
      expect(BandProtocol.eventCap('lyric.line'), 'lyric');
      expect(BandProtocol.eventCap('sys.hello_ack'), isNull);
    });

    test('isKnownMethod', () {
      expect(BandProtocol.isKnownMethod('state.get'), isTrue);
      expect(BandProtocol.isKnownMethod('queue.play'), isTrue);
      expect(BandProtocol.isKnownMethod('does.not.exist'), isFalse);
    });
  });

  group('BandPlayMode 映射', () {
    test('code ↔ 枚举 往返', () {
      for (final m in BandPlayMode.values) {
        expect(BandPlayMode.fromCode(m.code), m);
      }
    });

    test('未知 / null 回退 loop', () {
      expect(BandPlayMode.fromCode('nope'), BandPlayMode.loop);
      expect(BandPlayMode.fromCode(null), BandPlayMode.loop);
    });

    test('code 契约', () {
      expect(BandPlayMode.loop.code, 'loop');
      expect(BandPlayMode.single.code, 'single');
      expect(BandPlayMode.shuffle.code, 'shuffle');
    });
  });
}

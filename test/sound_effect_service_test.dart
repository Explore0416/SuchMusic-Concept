// 音效服务（Dart ↔ 原生契约）回归测试。
//
// 覆盖本次「音效兼容性修复」的 Dart 侧关键契约与熔断语义：
//  - apply / setSessionId 的**方法名与参数键**（code / sessionId / id）必须与
//    `SoundEffectBridge.kt` 的 `setMethodCallHandler` 完全一致，否则真机上会
//    静默返回 false（表现为「点击预设无效」）；
//  - 只有 `MissingPluginException`（通道根本不存在）才熔断；业务性失败
//    （含 PlatformException）**不熔断**，否则启动时 sessionId 为 null 的必然失败
//    会永久毒化整个进程内的音效调用；
//  - `restore()` 只读取当前 code，**不做实际 apply**。
//
// 说明：`SoundEffectService` 为进程单例且 `_broken` 私有不可重置，故「熔断」
// 用例必须放在最后声明（测试按声明顺序执行），以保证其入口时 `_broken == false`。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sound_effect_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与 SoundEffectBridge.CHANNEL / SoundEffectService._channel 必须一致
  const channel = MethodChannel('com.lightningteam.suchmusic/soundfx');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  void mockHandler(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls.clear();
    // 默认：通道存在，返回 null（安全值）
    mockHandler((_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  final svc = SoundEffectService.instance;

  group('SoundEffectService ↔ 原生契约', () {
    test('apply 且 sessionId > 0：方法名为 apply，参数含 code + sessionId', () async {
      mockHandler((call) async => true);

      final ok = await svc.apply('jbl_flip', sessionId: 1234);

      expect(ok, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'apply');
      final args = Map<Object?, Object?>.from(calls.single.arguments as Map);
      expect(args['code'], 'jbl_flip');
      expect(args['sessionId'], 1234);
    });

    test('apply 且 sessionId 为 null/0：不携带 sessionId 键（原生回退 0）', () async {
      mockHandler((call) async => true);

      await svc.apply('default'); // 未传 sessionId
      await svc.apply('default', sessionId: 0); // 非正数

      expect(calls, hasLength(2));
      for (final c in calls) {
        expect(c.method, 'apply');
        final args = Map<Object?, Object?>.from(c.arguments as Map);
        expect(args['code'], 'default');
        expect(args.containsKey('sessionId'), isFalse);
      }
    });

    test('apply 空 code：直接返回 false 且不触达通道', () async {
      final ok = await svc.apply('');
      expect(ok, isFalse);
      expect(calls, isEmpty);
    });

    test('setSessionId：方法名为 setSessionId，参数键为 id', () async {
      mockHandler((call) async => true);

      final ok = await svc.setSessionId(4321);

      expect(ok, isTrue);
      expect(calls.single.method, 'setSessionId');
      final args = Map<Object?, Object?>.from(calls.single.arguments as Map);
      expect(args['id'], 4321);
    });

    test('setSessionId(null / <=0)：返回 false 且不触达通道', () async {
      expect(await svc.setSessionId(null), isFalse);
      expect(await svc.setSessionId(0), isFalse);
      expect(await svc.setSessionId(-1), isFalse);
      expect(calls, isEmpty);
    });

    test('available / disable / current：方法名与原生一致', () async {
      mockHandler((call) async {
        switch (call.method) {
          case 'available':
            return true;
          case 'disable':
            return true;
          case 'current':
            return 'jbl_partybox';
          default:
            return null;
        }
      });

      expect(await svc.available(), isTrue);
      expect(await svc.disable(), isTrue);
      expect(await svc.current(), 'jbl_partybox');
      expect(calls.map((c) => c.method).toList(),
          ['available', 'disable', 'current']);
    });

    test('diagnose：方法名正确且键统一为 String', () async {
      mockHandler((call) async => <Object?, Object?>{
            'sdkInt': 34,
            'lastError': 'boom',
            'sessionId': 1234,
          });

      final diag = await svc.diagnose();

      expect(calls.single.method, 'diagnose');
      expect(diag, isNotNull);
      expect(diag!['sdkInt'], 34);
      expect(diag['lastError'], 'boom');
      expect(diag['sessionId'], 1234);
    });

    test('presets：通道返回空列表时回退内置 fallback（UI 永不空白）', () async {
      mockHandler((call) async => <Object?>[]);
      final list = await svc.presets();
      expect(list, isNotEmpty);
      expect(list.first.code, SoundEffectPreset.fallback.first.code);
    });

    test('restore：只读取 current，不做实际 apply', () async {
      mockHandler((call) async {
        if (call.method == 'current') return 'origin_voice';
        return true;
      });

      final code = await svc.restore();

      expect(code, 'origin_voice');
      // 关键：全程不得调用 apply
      expect(calls.where((c) => c.method == 'apply'), isEmpty);
      expect(calls.single.method, 'current');
    });
  });

  group('熔断语义：业务失败不熔断', () {
    test('PlatformException（业务失败）不熔断，后续调用仍触达通道', () async {
      // 第一次：原生抛业务异常
      mockHandler((call) async {
        throw PlatformException(code: 'BOOM', message: 'apply failed');
      });
      expect(await svc.available(), isFalse);

      // 第二次：换回正常 handler，必须仍被调用（证明未熔断）
      var invoked = false;
      mockHandler((call) async {
        invoked = true;
        return true;
      });
      calls.clear();
      expect(await svc.available(), isTrue);
      expect(invoked, isTrue);
      expect(calls, hasLength(1));
    });
  });

  // ⚠️ 本用例会令单例 `_broken = true`，必须置于文件末尾。
  group('熔断语义：通道不存在才熔断（置末）', () {
    test('MissingPluginException → 熔断：此后不再触达通道', () async {
      // 通道不存在
      messenger.setMockMethodCallHandler(channel, null);
      calls.clear();

      expect(await svc.available(), isFalse); // 触发 MissingPluginException

      // 重新注册正常 handler；若已熔断，则不应被调用
      var invoked = false;
      mockHandler((call) async {
        invoked = true;
        return true;
      });
      calls.clear();

      expect(await svc.available(), isFalse);
      expect(invoked, isFalse);
      expect(calls, isEmpty);
    });
  });
}

// 1.5.4 修复回归：
// ① 授权深链不得被当成音频播放（suchmusic:// 拦截）；
// ② 冷启动竞态：清单未就绪时补救刷新后重查，而不是直接判「未登记」；
// ③ 授权失败必须回传 onError（绝不静默）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/local_audio_intent_service.dart';
import 'package:such_music/services/third_party/auth_code_service.dart';
import 'package:such_music/services/third_party/client_registry.dart';
import 'package:such_music/services/third_party/deep_link_service.dart';
import 'package:such_music/services/third_party/third_party_auth_service.dart';

import 'support/fake_third_party.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('① 入站音频 scheme 防线', () {
    test('content / file 来源放行', () {
      expect(LocalAudioIntentService.acceptsSource('content://media/1'), isTrue);
      expect(LocalAudioIntentService.acceptsSource('file:///sdcard/a.mp3'), isTrue);
    });

    test('授权深链 suchmusic://oauth/authorize 必须被拦下', () {
      // 1.5.3 实机故障形态：lastPathSegment="authorize" 被当成歌名播放
      expect(
        LocalAudioIntentService.acceptsSource(
          'suchmusic://oauth/authorize?client_id=sm_x&scopes=genre.read',
        ),
        isFalse,
      );
    });

    test('其它 scheme（http 等）同样不放行', () {
      expect(LocalAudioIntentService.acceptsSource('http://a/b.mp3'), isFalse);
      expect(LocalAudioIntentService.acceptsSource(''), isFalse);
    });
  });

  group('② 冷启动竞态：清单未就绪', () {
    late FakeBridge bridge;
    late AuthCodeService codes;
    int now = 1731600000;

    setUp(() {
      bridge = FakeBridge();
      codes = AuthCodeService(autoPurge: false, now: () => now);
    });

    tearDown(() async {
      await bridge.dispose();
      codes.dispose();
    });

    ThirdPartyAuthService build({
      required List<ThirdPartyClient> bag,
      Future<void> Function()? onUnknownClient,
    }) {
      return ThirdPartyAuthService(
        registry: ClientRegistry.live(() => bag),
        bridge: bridge,
        codes: codes,
        server: FakeLoopback(),
        dataProvider: FakeProvider(),
        now: () => now,
        onUnknownClient: onUnknownClient,
      );
    }

    test('首次未命中 → 补救刷新后命中 → 正常走完授权', () async {
      final bag = <ThirdPartyClient>[];
      var remedyCalls = 0;
      final service = build(
        bag: bag,
        onUnknownClient: () async {
          remedyCalls++;
          // 模拟「远端清单此刻才就绪」
          bag.add(kTestClient);
        },
      );

      final outcome = await service.handleAuthorizeRequest(
        authorizeUri(),
        confirm: (_) async => true,
      );

      expect(remedyCalls, 1);
      expect(outcome, isA<AuthCompleted>());
    });

    test('补救后仍未登记 → client_mismatch（不放行）', () async {
      var remedyCalls = 0;
      final service = build(
        bag: <ThirdPartyClient>[],
        onUnknownClient: () async => remedyCalls++,
      );

      final outcome = await service.handleAuthorizeRequest(
        authorizeUri(),
        confirm: (_) async => true,
      );

      expect(remedyCalls, 1);
      expect(outcome, isA<AuthFailed>());
      expect((outcome as AuthFailed).error, AuthErrors.clientMismatch);
    });

    test('未注入钩子（测试默认）→ 直接判未登记', () async {
      final service = build(
        bag: <ThirdPartyClient>[],
        onUnknownClient: null,
      );

      final outcome = await service.handleAuthorizeRequest(
        authorizeUri(),
        confirm: (_) async => true,
      );

      expect(outcome, isA<AuthFailed>());
      expect((outcome as AuthFailed).error, AuthErrors.clientMismatch);
    });

    test('已命中时不触发补救钩子', () async {
      var remedyCalls = 0;
      final service = build(
        bag: <ThirdPartyClient>[kTestClient],
        onUnknownClient: () async => remedyCalls++,
      );

      final outcome = await service.handleAuthorizeRequest(
        authorizeUri(),
        confirm: (_) async => true,
      );

      expect(outcome, isA<AuthCompleted>());
      expect(remedyCalls, 0);
    });
  });

  group('③ 授权失败回传 onError', () {
    late FakeBridge bridge;
    late AuthCodeService codes;
    late DeepLinkService deepLink;
    int now = 1731600000;

    setUp(() {
      bridge = FakeBridge();
      codes = AuthCodeService(autoPurge: false, now: () => now);
    });

    tearDown(() async {
      deepLink.stop();
      await bridge.dispose();
      codes.dispose();
    });

    test('未登记深链 → onError 收到 client_mismatch 与文案', () async {
      final service = ThirdPartyAuthService(
        registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
        bridge: bridge,
        codes: codes,
        server: FakeLoopback(),
        dataProvider: FakeProvider(),
        now: () => now,
      );
      deepLink = DeepLinkService(
        authService: service,
        bridge: bridge,
        registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
      );

      String? gotError;
      String? gotMessage;
      await deepLink.start(
        onError: (error, message) {
          gotError = error;
          gotMessage = message;
        },
      );

      final outcome = await deepLink.handleUri(
        authorizeUri(clientId: 'unknown.client').toString(),
      );

      expect(outcome, isA<AuthFailed>());
      expect(gotError, AuthErrors.clientMismatch);
      expect(gotMessage, isNotEmpty);
    });

    test('未接 onError 只打日志、不抛异常', () async {
      final service = ThirdPartyAuthService(
        registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
        bridge: bridge,
        codes: codes,
        server: FakeLoopback(),
        dataProvider: FakeProvider(),
        now: () => now,
      );
      deepLink = DeepLinkService(
        authService: service,
        bridge: bridge,
        registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
      );
      await deepLink.start();

      final outcome = await deepLink.handleUri(
        authorizeUri(clientId: 'unknown.client').toString(),
      );
      expect(outcome, isA<AuthFailed>());
    });
  });
}

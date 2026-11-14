// M6 深链分发测试：静默续期发通知、拒绝时不下发 code。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/third_party/auth_code_service.dart';
import 'package:such_music/services/third_party/client_registry.dart';
import 'package:such_music/services/third_party/deep_link_service.dart';
import 'package:such_music/services/third_party/third_party_auth_service.dart';

import 'support/fake_third_party.dart';

/// 一条可复用的测试链路（全部外部依赖为替身）。
class _Harness {
  _Harness({FakeBridge? bridge}) : bridge = bridge ?? FakeBridge() {
    codes = AuthCodeService(autoPurge: false, now: () => now);
    service = ThirdPartyAuthService(
      registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
      bridge: this.bridge,
      codes: codes,
      server: FakeLoopback(),
      dataProvider: FakeProvider(),
      now: () => now,
    );
    deepLink = DeepLinkService(
      authService: service,
      bridge: this.bridge,
      registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
    );
  }

  final FakeBridge bridge;
  late final AuthCodeService codes;
  late final ThirdPartyAuthService service;
  late final DeepLinkService deepLink;
  int now = 1731600000;

  void advance(int seconds) => now += seconds;

  void dispose() {
    deepLink.stop();
    codes.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('静默访问通知（§6.6 / M6）', () {
    test('静默完成 → 发一条合并通知，内容按 scope 生成', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      // 先正常授权两项可静默能力
      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read,url.resolve'),
        confirm: (_) async => true,
      );
      h.bridge.notices.clear();
      h.advance(10);

      final outcome = await h.deepLink.handleUri(
        authorizeUri(scopes: 'genre.read,url.resolve', silent: true).toString(),
      );

      expect(outcome, isA<AuthCompleted>());
      expect((outcome as AuthCompleted).silent, isTrue);
      expect(h.bridge.notices.length, 1);
      final notice = h.bridge.notices.single;
      expect(notice.title, kThirdPartyAccessNoticeTitle);
      // 「{App} 读取了你的曲风画像、获取了歌曲直链」
      expect(notice.content, '测试客户端 读取了你的曲风画像、获取了歌曲直链');
    });

    test('单一 playback.control 静默 → 「正在通过 SuchMusic 播放」', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'playback.control'),
        confirm: (_) async => true,
      );
      h.bridge.notices.clear();
      h.advance(10);

      await h.deepLink.handleUri(
        authorizeUri(scopes: 'playback.control', silent: true).toString(),
      );

      expect(h.bridge.notices.length, 1);
      expect(h.bridge.notices.single.content, '测试客户端 正在通过 SuchMusic 播放');
    });

    test('非静默（用户刚确认过）不发通知', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      final outcome = await h.deepLink.handleUri(
        authorizeUri(scopes: 'genre.read').toString(),
        confirm: (_) async => true,
      );

      expect(outcome, isA<AuthCompleted>());
      expect((outcome as AuthCompleted).silent, isFalse);
      expect(h.bridge.notices, isEmpty);
    });

    test('撤销后 silent=1 退回确认页，不发通知也不投递 code', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      await h.service.revoke(kTestClientId);
      h.bridge.callbacks.clear();
      h.bridge.notices.clear();
      h.advance(10);

      final outcome = await h.deepLink.handleUri(
        authorizeUri(scopes: 'genre.read', silent: true).toString(),
      );

      expect(outcome, isA<AuthNeedsUi>());
      expect(h.bridge.notices, isEmpty);
      expect(h.bridge.callbacks, isEmpty);
    });
  });

  group('确认页回调接线（§6.3）', () {
    test('confirm 返回 false → access_denied，且 sendClientCallback 未被调用', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      var confirmCalls = 0;
      final outcome = await h.deepLink.handleUri(
        authorizeUri().toString(),
        confirm: (_) async {
          confirmCalls++;
          return false;
        },
      );

      expect(confirmCalls, 1, reason: '首次授权必须询问用户');
      expect(outcome, isA<AuthFailed>());
      expect((outcome as AuthFailed).error, AuthErrors.accessDenied);
      expect(h.bridge.callbacks, isEmpty, reason: '拒绝不得下发 code');
      expect(await h.service.listGrants(), isEmpty);
      expect(h.bridge.notices, isEmpty);
    });

    test('confirm 返回 true → 投递 code（与拒绝路径对称）', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      final outcome = await h.deepLink.handleUri(
        authorizeUri(scopes: 'genre.read').toString(),
        confirm: (_) async => true,
      );

      expect(outcome, isA<AuthCompleted>());
      expect(h.bridge.callbacks.length, 1);
      expect(h.bridge.callbacks.single['package'], kTestPackage);
      expect(await h.service.grantOf(kTestClientId), isNotNull);
    });

    test('confirm 未注入时不弹页（内核可脱离 UI 单独运行）', () async {
      final h = _Harness();
      addTearDown(h.dispose);

      final outcome = await h.deepLink.handleUri(authorizeUri().toString());

      expect(outcome, isA<AuthNeedsUi>());
      expect(h.bridge.callbacks, isEmpty);
      expect(h.bridge.notices, isEmpty);
    });
  });
}

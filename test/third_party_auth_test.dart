// 第三方授权决策链单测（ARCHITECTURE §6.1 / §6.6 / §6.7 / §4 威胁模型）。
//
// 覆盖：注册表校验、签名校验、首次强制 UI、拒绝不落库、允许落库、
// 静默续期条件（含 account.token 例外与 5s 防抖）、限流、撤销即时生效、
// 回调不可达时回滚授权。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/third_party/auth_code_service.dart';
import 'package:such_music/services/third_party/client_registry.dart';
import 'package:such_music/services/third_party/deep_link_service.dart';
import 'package:such_music/services/third_party/third_party_auth_service.dart';

import 'support/fake_third_party.dart';

/// 一条测试用的授权链路（全部外部依赖均为替身）。
class Harness {
  Harness({
    FakeBridge? bridge,
    int clock = 1731600000,
    Duration silentDebounce = const Duration(seconds: 5),
  })  : bridge = bridge ?? FakeBridge(),
        now = clock {
    codes = AuthCodeService(autoPurge: false, now: () => now);
    server = FakeLoopback();
    service = ThirdPartyAuthService(
      registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
      bridge: this.bridge,
      codes: codes,
      server: server,
      dataProvider: FakeProvider(),
      now: () => now,
      silentDebounce: silentDebounce,
    );
  }

  final FakeBridge bridge;
  late final AuthCodeService codes;
  late final FakeLoopback server;
  late final ThirdPartyAuthService service;
  int now;

  /// 前进时钟（秒）。
  void advance(int seconds) => now += seconds;

  void dispose() => codes.dispose();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('身份校验（T1）', () {
    test('未注册 client → client_mismatch，且不写任何记录', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(clientId: 'unknown.client'),
      );

      expect(outcome, isA<AuthFailed>());
      expect((outcome as AuthFailed).error, AuthErrors.clientMismatch);
      expect(await h.service.listGrants(), isEmpty);
      expect(await h.service.recentLogs(), isEmpty);
      // 未登记时连原生查询都不该发生
      expect(h.bridge.infoCalls, 0);
    });

    test('包名与注册表不一致 → client_mismatch', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome =
          await h.service.handleAuthorizeRequest(authorizeUri(package: 'com.evil.app'));

      expect((outcome as AuthFailed).error, AuthErrors.clientMismatch);
      expect(await h.service.listGrants(), isEmpty);
    });

    test('签名不符 → 拒绝，且不写授权记录', () async {
      final h = Harness(bridge: FakeBridge(signature: 'ffff0000'));
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(authorizeUri());

      expect(outcome, isA<AuthFailed>());
      expect((outcome as AuthFailed).error, AuthErrors.clientMismatch);
      expect(await h.service.listGrants(), isEmpty);
      expect(await h.service.recentLogs(), isEmpty);
    });

    test('签名大小写不敏感', () async {
      final h = Harness(bridge: FakeBridge(signature: kTestSignature.toUpperCase()));
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(authorizeUri());
      expect(outcome, isA<AuthNeedsUi>());
    });

    test('目标包未安装 → client_mismatch', () async {
      final h = Harness(bridge: FakeBridge(installed: false));
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(authorizeUri());
      expect((outcome as AuthFailed).error, AuthErrors.clientMismatch);
      expect(await h.service.listGrants(), isEmpty);
    });
  });

  group('参数校验', () {
    test('非 suchmusic 深链 → invalid_request', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service
          .handleAuthorizeRequest(Uri.parse('https://oauth/authorize?client_id=x'));
      expect((outcome as AuthFailed).error, AuthErrors.invalidRequest);
    });

    test('path 不是 /authorize → invalid_request', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service
          .handleAuthorizeRequest(Uri.parse('suchmusic://oauth/revoke?client_id=$kTestClientId'));
      expect((outcome as AuthFailed).error, AuthErrors.invalidRequest);
    });

    test('未知 scope → invalid_scope', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service
          .handleAuthorizeRequest(authorizeUri(scopes: 'genre.read,user.delete'));
      expect((outcome as AuthFailed).error, AuthErrors.invalidScope);
    });

    test('state 超过 128 字符 → invalid_state', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service
          .handleAuthorizeRequest(authorizeUri(state: 'x' * 129));
      expect((outcome as AuthFailed).error, AuthErrors.invalidState);
    });

    test('state 缺失 → invalid_state', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(authorizeUri(state: null));
      expect((outcome as AuthFailed).error, AuthErrors.invalidState);
    });
  });

  group('首次授权（§6.3 / §9.1）', () {
    test('confirm 为 null → AuthNeedsUi，且 request 内容完整', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'url.resolve,genre.read', state: 'abc'),
      );

      expect(outcome, isA<AuthNeedsUi>());
      final request = (outcome as AuthNeedsUi).request;
      expect(request.client.clientId, kTestClientId);
      expect(request.packageName, kTestPackage);
      expect(request.state, 'abc');
      expect(request.silent, isFalse);
      expect(request.scopes, <ThirdPartyScope>[
        ThirdPartyScope.genreRead,
        ThirdPartyScope.urlResolve,
      ]);
      // 还没有授权 → 全部是新增
      expect(request.newScopes.length, 2);
      // 确认页展示 PackageManager 真实应用名 + 签名指纹前 8 位（T10）
      expect(request.displayName, '测试客户端');
      expect(request.signaturePrefix, kTestSignature.substring(0, 8));
      expect(await h.service.listGrants(), isEmpty);
    });

    test('用户拒绝 → access_denied，不落库，写 denied 日志', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(),
        confirm: (AuthRequest request) async => false,
      );

      expect(outcome, isA<AuthFailed>());
      expect((outcome as AuthFailed).error, AuthErrors.accessDenied);
      expect(await h.service.grantOf(kTestClientId), isNull);
      expect(h.bridge.callbacks, isEmpty);
      final logs = await h.service.recentLogs();
      expect(logs.length, 1);
      expect(logs.first.result, 'denied');
    });

    test('用户允许 → AuthCompleted，grant 落库且 scopes 正确', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read,url.resolve'),
        confirm: (AuthRequest request) async => true,
      );

      expect(outcome, isA<AuthCompleted>());
      expect((outcome as AuthCompleted).clientId, kTestClientId);
      expect(outcome.silent, isFalse);

      final grant = await h.service.grantOf(kTestClientId);
      expect(grant, isNotNull);
      expect(grant!.scopes, <ThirdPartyScope>{
        ThirdPartyScope.genreRead,
        ThirdPartyScope.urlResolve,
      });
      expect(grant.callCount, 1);
      expect(grant.grantedAt, h.now);

      // code 已投递给目标包
      final callback = h.bridge.lastCallback!;
      expect(callback['package'], kTestPackage);
      expect(callback['state'], 'state-1');
      expect(callback['client_id'], kTestClientId);
      expect(callback['scopes'], <String>['genre.read', 'url.resolve']);
      expect((callback['code'] as String).length, greaterThanOrEqualTo(40));
      expect(callback['port'], 45678);
      expect(h.codes.lookup(callback['code'] as String).found, isTrue);

      final logs = await h.service.recentLogs();
      expect(logs.first.result, 'granted');
    });

    test('再次授权新 scope → scope 取并集，grantedAt 不变，callCount 递增', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      h.advance(100);
      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'url.resolve'),
        confirm: (_) async => true,
      );

      final grant = await h.service.grantOf(kTestClientId);
      expect(grant!.scopes, <ThirdPartyScope>{
        ThirdPartyScope.genreRead,
        ThirdPartyScope.urlResolve,
      });
      expect(grant.grantedAt, 1731600000);
      expect(grant.lastAccessAt, 1731600100);
      expect(grant.callCount, 2);
    });

    test('目标包没有回调页 → no_callback_activity，且回滚授权记录', () async {
      final h = Harness(bridge: FakeBridge(callbackSent: false));
      addTearDown(h.dispose);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(),
        confirm: (_) async => true,
      );

      expect(outcome, isA<AuthFailed>());
      expect((outcome as AuthFailed).error, AuthErrors.noCallbackActivity);
      // 用户同意了但数据无处可去 → 不能留授权
      expect(await h.service.grantOf(kTestClientId), isNull);
      expect(h.codes.pendingCount, 0);
      expect(h.server.stopCalls, greaterThan(0));
    });

    test('已有授权但回调失败 → 恢复原 grant（不是删掉）', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      h.bridge.callbackSent = false;
      h.advance(10);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'url.resolve', silent: false),
        confirm: (_) async => true,
      );

      expect((outcome as AuthFailed).error, AuthErrors.noCallbackActivity);
      final grant = await h.service.grantOf(kTestClientId);
      expect(grant!.scopes, <ThirdPartyScope>{ThirdPartyScope.genreRead});
      expect(grant.callCount, 1);
    });
  });

  group('静默续期（§6.6 / ADR-003）', () {
    test('已授权 + silent=1 + 仅可静默 scope → 直接完成，不调用 confirm', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read,url.resolve'),
        confirm: (_) async => true,
      );

      var confirmCalls = 0;
      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read', silent: true),
        confirm: (_) async {
          confirmCalls++;
          return true;
        },
      );

      expect(confirmCalls, 0);
      expect(outcome, isA<AuthCompleted>());
      expect((outcome as AuthCompleted).silent, isTrue);
      expect(h.server.startCalls, 2);
    });

    test('已授权但请求 account.token + silent=1 → 仍然需要 UI', () async {
      final h = Harness();
      addTearDown(h.dispose);

      // 先正常授权 account.token（前台确认过）
      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'account.token'),
        confirm: (_) async => true,
      );
      expect(await h.service.grantOf(kTestClientId), isNotNull);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'account.token', silent: true),
      );

      expect(outcome, isA<AuthNeedsUi>());
    });

    test('静默请求 account.token 时 confirm 必须被调用', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'account.token'),
        confirm: (_) async => true,
      );

      var confirmCalls = 0;
      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'account.token', silent: true),
        confirm: (_) async {
          confirmCalls++;
          return true;
        },
      );

      expect(confirmCalls, 1);
      expect(outcome, isA<AuthCompleted>());
    });

    test('未授权时 silent=1 也必须出 UI', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final outcome =
          await h.service.handleAuthorizeRequest(authorizeUri(silent: true));
      expect(outcome, isA<AuthNeedsUi>());
    });

    test('申请了超出已授权范围的 scope → 出 UI，只把新增项标为 new', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read,playback.control', silent: true),
      );

      expect(outcome, isA<AuthNeedsUi>());
      final request = (outcome as AuthNeedsUi).request;
      expect(request.alreadyGranted, <ThirdPartyScope>{ThirdPartyScope.genreRead});
      expect(request.newScopes, <ThirdPartyScope>[ThirdPartyScope.playbackControl]);
    });

    test('5s 内重复静默 → 退回 UI（防抖）', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      final first = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read', silent: true),
      );
      expect(first, isA<AuthCompleted>());

      // 同一秒内再次静默 → 触发防抖
      final second = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read', silent: true),
      );
      expect(second, isA<AuthNeedsUi>());

      // 过了 5s 又可以静默
      h.advance(6);
      final third = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read', silent: true),
      );
      expect(third, isA<AuthCompleted>());
    });
  });

  group('限流（T7）', () {
    test('同一 client 每分钟第 11 次 → rate_limited', () async {
      final h = Harness();
      addTearDown(h.dispose);

      for (var i = 0; i < 10; i++) {
        final outcome = await h.service.handleAuthorizeRequest(
          authorizeUri(scopes: 'genre.read'),
          confirm: (_) async => true,
        );
        expect(outcome, isA<AuthCompleted>(), reason: '第 ${i + 1} 次应成功');
      }

      final eleventh = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      expect(eleventh, isA<AuthFailed>());
      expect((eleventh as AuthFailed).error, AuthErrors.rateLimited);
    });

    test('超过一分钟后计数清零', () async {
      final h = Harness();
      addTearDown(h.dispose);

      for (var i = 0; i < 10; i++) {
        await h.service.handleAuthorizeRequest(
          authorizeUri(scopes: 'genre.read'),
          confirm: (_) async => true,
        );
      }
      h.advance(61);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      expect(outcome, isA<AuthCompleted>());
    });
  });

  group('撤销（§6.7 / T6）', () {
    test('撤销后 silent 请求 → 重新需要 UI，grant 已删除', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      await h.service.revoke(kTestClientId);

      expect(await h.service.grantOf(kTestClientId), isNull);
      // 未使用的 code 被清空
      expect(h.codes.pendingCount, 0);

      final outcome =
          await h.service.handleAuthorizeRequest(authorizeUri(silent: true));
      expect(outcome, isA<AuthNeedsUi>());

      final logs = await h.service.recentLogs();
      expect(logs.any((log) => log.result == 'revoked'), isTrue);
    });

    test('revokeAll 清空全部授权', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      await h.service.revokeAll();

      expect(await h.service.listGrants(), isEmpty);
    });

    test('撤销后立即重新授权可再次静默', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      await h.service.revoke(kTestClientId);
      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );
      h.advance(10);

      final outcome = await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read', silent: true),
      );
      expect(outcome, isA<AuthCompleted>());
    });
  });

  group('存储与日志', () {
    test('授权记录可跨实例读取（走 SharedPreferences 往返）', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'genre.read'),
        confirm: (_) async => true,
      );

      final restored = ThirdPartyAuthService(
        registry: const ClientRegistry(<ThirdPartyClient>[kTestClient]),
        bridge: FakeBridge(),
        codes: AuthCodeService(autoPurge: false),
        server: FakeLoopback(),
        dataProvider: FakeProvider(),
      );
      final grant = await restored.grantOf(kTestClientId);
      expect(grant, isNotNull);
      expect(grant!.scopes, <ThirdPartyScope>{ThirdPartyScope.genreRead});
    });

    test('访问日志只记 clientId / scopes / result / ts，不含任何返回值', () async {
      final h = Harness();
      addTearDown(h.dispose);

      await h.service.handleAuthorizeRequest(
        authorizeUri(scopes: 'account.token'),
        confirm: (_) async => true,
      );

      final logs = await h.service.recentLogs();
      expect(logs, isNotEmpty);
      final json = logs.first.toJson();
      expect(json.keys.toSet(), <String>{'client_id', 'scopes', 'result', 'ts'});
    });

    test('访问日志最多保留 50 条（FIFO）', () async {
      final h = Harness(clock: 1731600000);
      addTearDown(h.dispose);

      // 60 次拒绝 → 60 条 denied，超过上限后淘汰最旧的
      for (var i = 0; i < 60; i++) {
        h.advance(61);
        await h.service.handleAuthorizeRequest(
          authorizeUri(),
          confirm: (_) async => false,
        );
      }

      final logs = await h.service.recentLogs();
      expect(logs.length, ThirdPartyAuthService.maxAccessLogs);
    });
  });

  group('深链分发（DeepLinkService）', () {
    test('非 suchmusic 深链不处理，返回 null', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final deepLink = DeepLinkService(authService: h.service, bridge: h.bridge);
      addTearDown(deepLink.stop);

      final outcome =
          await deepLink.handleUri('https://example.com/oauth/authorize?client_id=x');
      expect(outcome, isNull);
    });

    test('suchmusic 深链交给 AuthService，并回传结果类型', () async {
      final h = Harness();
      addTearDown(h.dispose);

      final deepLink = DeepLinkService(authService: h.service, bridge: h.bridge);
      addTearDown(deepLink.stop);

      final needsUi = await deepLink.handleUri(authorizeUri().toString());
      expect(needsUi, isA<AuthNeedsUi>());

      final completed = await deepLink.handleUri(
        authorizeUri().toString(),
        confirm: (_) async => true,
      );
      expect(completed, isA<AuthCompleted>());
    });

    test('start() 处理冷启动深链（M4 前 confirm 为 null 只打印）', () async {
      final h = Harness(bridge: FakeBridge());
      addTearDown(h.dispose);
      h.bridge.launchUri = authorizeUri().toString();

      final deepLink = DeepLinkService(authService: h.service, bridge: h.bridge);
      addTearDown(deepLink.stop);

      await deepLink.start();
      expect(deepLink.isStarted, isTrue);
      // 冷启动 Uri 已被处理：未授权 → 只出 AuthNeedsUi，不落库
      expect(await h.service.listGrants(), isEmpty);
    });
  });
}

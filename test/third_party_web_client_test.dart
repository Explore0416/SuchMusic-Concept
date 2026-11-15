// Web 客户端接入单测（1.5.3 新增能力）。
//
// 覆盖三件事：
// 1. v2 清单的签名串与平台端 `src/sign.js#canonicalMessageV2` **逐字节一致**
//    ——用 2026-11-15 线上真实响应 + 真实 Ed25519 签名做黄金样本；
// 2. Web 客户端的授权决策：callback 白名单、强制 PKCE、禁止 silent、不发 intent；
// 3. loopback 的 PKCE 校验与 CORS 预检（真实 HttpServer，不 mock 网络）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/third_party/auth_code_service.dart';
import 'package:such_music/services/third_party/client_registry.dart';
import 'package:such_music/services/third_party/loopback_server.dart';
import 'package:such_music/services/third_party/remote_clients.dart';
import 'package:such_music/services/third_party/third_party_auth_service.dart';

import 'support/fake_third_party.dart';

/// 线上 `/api/v2/clients` 的真实响应（2026-11-15 抓取，含 Web 客户端）。
const String kLiveV2Payload = r'''
{
  "version": 2,
  "key_id": "k1",
  "generated_at": 1794756734,
  "clients": [
    {
      "client_id": "sm_5225aa665f570bad",
      "display_name": "SuchMusic 授权演示",
      "app_type": "web",
      "package_name": "",
      "signature_sha256": "",
      "redirect_uris": ["https://demo.lightning-team.top/callback"],
      "scopes": ["genre.read", "url.resolve", "playback.control"]
    },
    {
      "client_id": "sm_77c215cad65b24f2",
      "display_name": "测试应用",
      "app_type": "android",
      "package_name": "com.aaa.bbb",
      "signature_sha256": "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f90123456789abcdef0123456789a",
      "redirect_uris": [],
      "scopes": ["genre.read", "account.token", "url.resolve", "playback.control"]
    }
  ],
  "signature": "majcGul89VWX6eWxf2Rpp1oKw9shm0DSTCrzHEHse3bqUerbNx5u_uRttAVDFpuCsiUbyIJoDQHkFWVbIu9_DQ"
}
''';

/// 平台端按同一份响应算出的签名串（Node 侧 `canonicalMessageV2` 输出）。
///
/// 注意 Web 条目的 package_name / signature_sha256 是空串，因此中间有两行空行。
const String kLiveV2Message = 'suchmusic-clients-v2\n'
    '1794756734\n'
    'sm_5225aa665f570bad\n'
    'web\n'
    '\n'
    '\n'
    'https://demo.lightning-team.top/callback\n'
    'genre.read,playback.control,url.resolve\n'
    '---\n'
    'sm_77c215cad65b24f2\n'
    'android\n'
    'com.aaa.bbb\n'
    '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f90123456789abcdef0123456789a\n'
    '\n'
    'account.token,genre.read,playback.control,url.resolve';

const String kWebClientId = 'web.demo';
const String kWebRedirect = 'https://demo.lightning-team.top/callback';

const ThirdPartyClient kWebClient = ThirdPartyClient(
  clientId: kWebClientId,
  packageName: '',
  signatureSha256: '',
  displayName: '网页演示',
  appType: ThirdPartyAppType.web,
  redirectUris: <String>[kWebRedirect],
);

/// Web 授权深链。
Uri webAuthorizeUri({
  String clientId = kWebClientId,
  String? redirectUri = kWebRedirect,
  String scopes = 'genre.read',
  String state = 'state-web-1',
  String? codeChallenge = 'challenge-abc',
  String? method = 'S256',
  String? package = '',
  bool silent = false,
}) {
  final query = <String, String>{
    'client_id': clientId,
    'scopes': scopes,
    'state': state,
    if (package != null && package.isNotEmpty) 'package': package,
    if (redirectUri != null) 'redirect_uri': redirectUri,
    if (codeChallenge != null) 'code_challenge': codeChallenge,
    if (method != null) 'code_challenge_method': method,
    if (silent) 'silent': '1',
  };
  return Uri.parse('suchmusic://oauth/authorize').replace(queryParameters: query);
}

/// 一条 Web 授权链路（外部依赖全部为替身）。
class WebHarness {
  WebHarness({FakeBridge? bridge})
      : bridge = bridge ?? FakeBridge(),
        now = 1731600000 {
    codes = AuthCodeService(autoPurge: false, now: () => now);
    server = FakeLoopback();
    service = ThirdPartyAuthService(
      registry: const ClientRegistry(<ThirdPartyClient>[kTestClient, kWebClient]),
      bridge: this.bridge,
      codes: codes,
      server: server,
      dataProvider: FakeProvider(),
      now: () => now,
    );
  }

  final FakeBridge bridge;
  late final AuthCodeService codes;
  late final FakeLoopback server;
  late final ThirdPartyAuthService service;
  int now;

  void dispose() => codes.dispose();
}


const String kWebVerifier = 'verifier-1234567890abcdef';

/// 一个 HTTP 响应（状态码 + 小写头 + 原文）。
class RawResponse {
  const RawResponse(this.status, this.body, this.headers);

  final int status;
  final String body;
  final Map<String, String> headers;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;

  String get error => json['error']?.toString() ?? '';

  String? header(String name) => headers[name.toLowerCase()];
}

/// 用裸 Socket 发一次请求。
///
/// 不能用 `HttpClient`：`TestWidgetsFlutterBinding` 会把所有 HttpClient 请求
/// 拦成 400，真实网络请求根本不会发生。
Future<RawResponse> rawRequest(
  int port, {
  String method = 'POST',
  String path = LoopbackServer.exchangePath,
  Map<String, String> headers = const <String, String>{},
  String? authorization,
  String body = '',
}) async {
  final payload = utf8.encode(body);
  final head = StringBuffer()
    ..write('$method $path HTTP/1.1\r\n')
    ..write('Host: 127.0.0.1:$port\r\n')
    ..write('Content-Type: application/json\r\n')
    ..write('Content-Length: ${payload.length}\r\n')
    ..write('Connection: close\r\n');
  headers.forEach((key, value) => head.write('$key: $value\r\n'));
  if (authorization != null) head.write('Authorization: $authorization\r\n');
  head.write('\r\n');

  Socket? socket;
  final chunks = <int>[];
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 5),
    );
    socket.add(utf8.encode(head.toString()));
    socket.add(payload);
    await socket.flush();
    await for (final data in socket) {
      chunks.addAll(data);
    }
  } catch (_) {
    // 端口已关闭 / 服务端强制断连：已收到的数据仍然可用
  } finally {
    socket?.destroy();
  }

  final text = utf8.decode(chunks, allowMalformed: true);
  final split = text.indexOf('\r\n\r\n');
  final headText = split < 0 ? text : text.substring(0, split);
  final bodyText = split < 0 ? '' : text.substring(split + 4);
  final lines = headText.split('\r\n');
  var status = 0;
  final parsedHeaders = <String, String>{};
  if (lines.isNotEmpty) {
    final parts = lines.first.split(' ');
    if (parts.length > 1) status = int.tryParse(parts[1]) ?? 0;
  }
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    parsedHeaders[line.substring(0, colon).trim().toLowerCase()] =
        line.substring(colon + 1).trim();
  }
  return RawResponse(status, bodyText, parsedHeaders);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('v2 清单', () {
    test('签名串与平台端逐字节一致', () {
      final payload = jsonDecode(kLiveV2Payload) as Map<String, dynamic>;
      expect(RemoteClients.buildSigningMessageV2(payload), kLiveV2Message);
    });

    test('真实线上响应能通过内置公钥验签', () {
      final payload = jsonDecode(kLiveV2Payload) as Map<String, dynamic>;
      expect(RemoteClients.verifyPayload(payload), isTrue);
    });

    test('改动未参与 v1 签名的字段会破坏 v2 验签', () {
      final payload = jsonDecode(kLiveV2Payload) as Map<String, dynamic>;
      // app_type 在 v1 里不参与签名，在 v2 里参与；改它必须导致验签失败
      (payload['clients'] as List)[0]['app_type'] = 'android';
      expect(RemoteClients.verifyPayload(payload), isFalse);
    });

    test('篡改 redirect_uris 会被验签拦下', () {
      final payload = jsonDecode(kLiveV2Payload) as Map<String, dynamic>;
      (payload['clients'] as List)[0]['redirect_uris'] = <String>[
        'https://evil.example.com/callback',
      ];
      expect(RemoteClients.verifyPayload(payload), isFalse);
    });

    test('解析出 Web 与 Android 两类客户端', () {
      final payload = jsonDecode(kLiveV2Payload) as Map<String, dynamic>;
      final clients = RemoteClients.parseClients(payload['clients'], version: 2);
      expect(clients.length, 2);

      final web = clients.firstWhere((c) => c.clientId == 'sm_5225aa665f570bad');
      expect(web.isWeb, isTrue);
      expect(web.packageName, isEmpty);
      expect(web.redirectUris, <String>[kWebRedirect]);
      expect(web.redirectOrigins, <String>{'https://demo.lightning-team.top'});

      final android = clients.firstWhere((c) => c.clientId == 'sm_77c215cad65b24f2');
      expect(android.isWeb, isFalse);
      expect(android.packageName, 'com.aaa.bbb');
    });

    test('Web 条目带了包名或非法回调地址时逐条丢弃', () {
      final base = <String, dynamic>{
        'client_id': 'web.bad',
        'app_type': 'web',
        'package_name': '',
        'signature_sha256': '',
        'redirect_uris': <String>[kWebRedirect],
        'scopes': <String>['genre.read'],
      };

      expect(RemoteClients.parseClients(<dynamic>[base], version: 2).length, 1);

      expect(
        RemoteClients.parseClients(<dynamic>[
          <String, dynamic>{...base, 'package_name': 'com.evil.app'},
        ], version: 2),
        isEmpty,
      );
      expect(
        RemoteClients.parseClients(<dynamic>[
          <String, dynamic>{
            ...base,
            'redirect_uris': <String>['http://demo.lightning-team.top/callback'],
          },
        ], version: 2),
        isEmpty,
      );
      expect(
        RemoteClients.parseClients(<dynamic>[
          <String, dynamic>{...base, 'redirect_uris': <String>[]},
        ], version: 2),
        isEmpty,
      );
    });
  });

  group('Web 授权决策', () {
    test('未登记的回调地址 → invalid_redirect_uri，且不写任何记录', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(redirectUri: 'https://evil.example.com/callback'),
        confirm: (_) async => true,
      );

      expect(result, isA<AuthFailed>());
      expect((result as AuthFailed).error, AuthErrors.invalidRedirectUri);
      expect(await h.service.listGrants(), isEmpty);
      expect(h.bridge.openedUrls, isEmpty);
    });

    test('缺 PKCE → pkce_required', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(codeChallenge: null),
        confirm: (_) async => true,
      );

      expect((result as AuthFailed).error, AuthErrors.pkceRequired);
    });

    test('code_challenge_method 必须是 S256', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(method: 'plain'),
        confirm: (_) async => true,
      );

      expect((result as AuthFailed).error, AuthErrors.pkceRequired);
    });

    test('Web 请求带 package → invalid_request', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(package: 'com.example.test'),
        confirm: (_) async => true,
      );

      expect((result as AuthFailed).error, AuthErrors.invalidRequest);
    });

    test('合法请求 → 打开浏览器回跳，不发 intent', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(scopes: 'genre.read,url.resolve'),
        confirm: (_) async => true,
      );

      expect(result, isA<AuthCompleted>());
      // 没有向任何 Android 包投递 intent
      expect(h.bridge.callbacks, isEmpty);
      expect(h.bridge.openedUrls.length, 1);

      final opened = Uri.parse(h.bridge.openedUrls.single);
      expect(opened.scheme, 'https');
      expect(opened.host, 'demo.lightning-team.top');
      expect(opened.path, '/callback');
      // code 必须在 fragment（不进 Referer / 不落服务器日志）
      expect(opened.hasFragment, isTrue);
      expect(opened.query, isEmpty);

      final fragment = Uri.splitQueryString(opened.fragment);
      expect(fragment['state'], 'state-web-1');
      expect(fragment['client_id'], kWebClientId);
      expect(fragment['port'], '45678');
      expect(fragment['scopes'], 'genre.read,url.resolve');
      expect(fragment['code'], isNotEmpty);

      // loopback 拿到了 PKCE challenge 与 CORS 白名单
      expect(h.server.lastCodeChallenge, 'challenge-abc');
      expect(
        h.server.lastAllowedOrigins,
        <String>{'https://demo.lightning-team.top'},
      );
    });

    test('浏览器打不开 → browser_unavailable 且回滚授权记录', () async {
      final bridge = FakeBridge()..browserAvailable = false;
      final h = WebHarness(bridge: bridge);
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(),
        confirm: (_) async => true,
      );

      expect((result as AuthFailed).error, AuthErrors.browserUnavailable);
      expect(await h.service.listGrants(), isEmpty);
    });

    test('用户拒绝 → access_denied，且不写授权记录', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(),
        confirm: (_) async => false,
      );

      expect((result as AuthFailed).error, AuthErrors.accessDenied);
      expect(await h.service.listGrants(), isEmpty);
      expect(h.bridge.openedUrls, isEmpty);
    });

    test('Web 客户端即使带 silent=1 也必须弹确认页', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      // 先授权一次，制造「已授权」状态
      await h.service.handleAuthorizeRequest(
        webAuthorizeUri(),
        confirm: (_) async => true,
      );

      var confirmed = 0;
      final result = await h.service.handleAuthorizeRequest(
        webAuthorizeUri(silent: true),
        confirm: (_) async {
          confirmed++;
          return true;
        },
      );

      expect(result, isA<AuthCompleted>());
      expect(confirmed, 1, reason: '网页应用不允许静默续期');
    });

    test('未传 confirm 时返回 AuthNeedsUi 并携带回调地址', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final result = await h.service.handleAuthorizeRequest(webAuthorizeUri());

      expect(result, isA<AuthNeedsUi>());
      final request = (result as AuthNeedsUi).request;
      expect(request.isWeb, isTrue);
      expect(request.redirectUri, kWebRedirect);
      expect(request.signaturePrefix, isEmpty);
      expect(h.bridge.openedUrls, isEmpty);
    });

    test('Android 客户端带 redirect_uri 一律拒绝（防协议串用）', () async {
      final h = WebHarness();
      addTearDown(h.dispose);

      final uri = Uri.parse('suchmusic://oauth/authorize').replace(
        queryParameters: <String, String>{
          'client_id': kTestClientId,
          'package': kTestPackage,
          'scopes': 'genre.read',
          'state': 's',
          'redirect_uri': kWebRedirect,
        },
      );

      final result = await h.service.handleAuthorizeRequest(uri, confirm: (_) async => true);
      expect((result as AuthFailed).error, AuthErrors.invalidRequest);
    });
  });

  group('loopback：PKCE 与 CORS', () {
    late AuthCodeService codes;
    late LoopbackServer server;

    setUp(() {
      codes = AuthCodeService(autoPurge: false);
      server = LoopbackServer(codes: codes, idleTimeout: const Duration(seconds: 5));
    });

    tearDown(() async {
      await server.stopAll();
      codes.dispose();
    });

    /// 起一个 Web 会话。code 必须真的登记进 AuthCodeService，否则交换必然 401。
    Future<({int port, String code})> startWebSession({
      String verifier = kWebVerifier,
    }) async {
      final challenge = LoopbackServer.pkceChallengeOf(verifier);
      final code = codes.issue(
        clientId: kWebClientId,
        packageName: '',
        scopes: <ThirdPartyScope>{ThirdPartyScope.genreRead},
        port: 0,
        foregroundConfirmed: true,
        codeChallenge: challenge,
      );
      final port = await server.start(
        clientId: kWebClientId,
        code: code,
        scopes: <ThirdPartyScope>{ThirdPartyScope.genreRead},
        provider: FakeProvider(),
        codeChallenge: challenge,
        allowedOrigins: const <String>{'https://demo.lightning-team.top'},
      );
      return (port: port, code: code);
    }

    test('PKCE challenge 计算符合 RFC 7636 的测试向量', () {
      // RFC 7636 附录 B：verifier → S256 challenge
      expect(
        LoopbackServer.pkceChallengeOf('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('带正确 code_verifier → 200 且回 ACAO', () async {
      final session = await startWebSession();
      final res = await rawRequest(
        session.port,
        authorization: 'Bearer ${session.code}',
        headers: const <String, String>{'Origin': 'https://demo.lightning-team.top'},
        body: jsonEncode(<String, Object?>{'code_verifier': kWebVerifier}),
      );

      expect(res.status, 200);
      expect(res.header('access-control-allow-origin'), 'https://demo.lightning-team.top');
      expect(res.body, contains('genre.read'));
    });

    test('缺 code_verifier → 401 pkce_required', () async {
      final session = await startWebSession();
      final res = await rawRequest(
        session.port,
        authorization: 'Bearer ${session.code}',
        body: '{}',
      );

      expect(res.status, 401);
      expect(res.error, AuthErrors.pkceRequired);
    });

    test('code_verifier 不匹配 → 401 invalid_code', () async {
      final session = await startWebSession();
      final res = await rawRequest(
        session.port,
        authorization: 'Bearer ${session.code}',
        body: jsonEncode(<String, Object?>{'code_verifier': 'wrong-verifier'}),
      );

      expect(res.status, 401);
      expect(res.error, AuthErrors.invalidCode);
    });

    test('请求未登记的 scope 且 PKCE 正确 → 403', () async {
      final session = await startWebSession();
      final res = await rawRequest(
        session.port,
        authorization: 'Bearer ${session.code}',
        body: jsonEncode(<String, Object?>{
          'code_verifier': kWebVerifier,
          'request': <String, Object?>{
            'url.resolve': <String, Object?>{'song': <String, Object?>{'id': '1'}},
          },
        }),
      );

      expect(res.status, 403);
      expect(res.error, AuthErrors.scopeNotGranted);
    });

    test('CORS 预检：白名单 origin → 204 且回 ACAO', () async {
      final session = await startWebSession();
      final res = await rawRequest(
        session.port,
        method: 'OPTIONS',
        headers: const <String, String>{
          'Origin': 'https://demo.lightning-team.top',
          'Access-Control-Request-Method': 'POST',
          'Access-Control-Request-Headers': 'authorization, content-type',
        },
      );

      expect(res.status, 204);
      expect(res.header('access-control-allow-origin'), 'https://demo.lightning-team.top');
      expect(res.header('access-control-allow-headers'), 'authorization, content-type');
      expect(res.header('access-control-allow-methods'), contains('POST'));
    });

    test('CORS 预检：未登记 origin → 403 且无 ACAO', () async {
      final session = await startWebSession();
      final res = await rawRequest(
        session.port,
        method: 'OPTIONS',
        headers: const <String, String>{'Origin': 'https://evil.example.com'},
      );

      expect(res.status, 403);
      expect(res.header('access-control-allow-origin'), isNull);
    });

    test('Android 会话不下发任何 CORS 头', () async {
      final code = codes.issue(
        clientId: kTestClientId,
        packageName: kTestPackage,
        scopes: <ThirdPartyScope>{ThirdPartyScope.genreRead},
        port: 0,
      );
      final port = await server.start(
        clientId: kTestClientId,
        code: code,
        scopes: <ThirdPartyScope>{ThirdPartyScope.genreRead},
        provider: FakeProvider(),
        packageName: kTestPackage,
      );
      final res = await rawRequest(
        port,
        authorization: 'Bearer $code',
        headers: const <String, String>{'Origin': 'https://demo.lightning-team.top'},
        body: '{}',
      );

      expect(res.status, 200);
      expect(res.header('access-control-allow-origin'), isNull);
    });
  });
}

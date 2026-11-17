// Loopback 数据交换单测（ARCHITECTURE §6.4 / §6.5 / ADR-002 / T3 / T4）。
//
// 覆盖：签发 code → POST 交换成功、code 一次性、过期、Host 校验、
// 请求体上限、未授权 scope、account.token 前台确认标记。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/third_party/auth_code_service.dart';
import 'package:such_music/services/third_party/loopback_server.dart';
import 'package:such_music/services/third_party/third_party_data_provider.dart';

import 'support/fake_third_party.dart';

const String kClientId = 'test.client';

/// 原始 HTTP 响应（只解析状态码与 body，够用且不依赖 HttpClient 细节）。
class RawResponse {
  const RawResponse(this.status, this.body);

  final int status;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;

  String get error => json['error']?.toString() ?? '';
}

/// 用裸 Socket 发一次请求：便于伪造 Host 头、控制 Content-Length。
Future<RawResponse> rawExchange(
  int port, {
  String path = LoopbackServer.exchangePath,
  String method = 'POST',
  String? host,
  String? authorization,
  String body = '',
}) async {
  final payload = utf8.encode(body);
  final head = StringBuffer()
    ..write('$method $path HTTP/1.1\r\n')
    ..write('Host: ${host ?? '127.0.0.1:$port'}\r\n')
    ..write('Content-Type: application/json\r\n')
    ..write('Content-Length: ${payload.length}\r\n')
    ..write('Connection: close\r\n');
  if (authorization != null) {
    head.write('Authorization: $authorization\r\n');
  }
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
    // 端口已关闭 / 服务端强制断连：已收到的数据仍然可用，status 会是 0
  } finally {
    socket?.destroy();
  }

  final text = utf8.decode(chunks, allowMalformed: true);
  final sep = text.indexOf('\r\n\r\n');
  final headText = sep >= 0 ? text.substring(0, sep) : text;
  final bodyText = sep >= 0 ? text.substring(sep + 4) : '';
  final statusLine = headText.split('\r\n').first.split(' ');
  final status = statusLine.length >= 2 ? int.tryParse(statusLine[1]) ?? 0 : 0;
  return RawResponse(status, bodyText);
}

void main() {
  late int clock;
  late AuthCodeService codes;
  late LoopbackServer server;
  late FakeProvider provider;

  setUp(() {
    clock = 1731600000;
    codes = AuthCodeService(autoPurge: false, now: () => clock);
    server = LoopbackServer(
      codes: codes,
      idleTimeout: const Duration(seconds: 30),
    );
    provider = FakeProvider();
  });

  tearDown(() async {
    await server.stopAll();
    codes.dispose();
  });

  /// 签发 code 并起服，返回 (code, port)。
  Future<({String code, int port})> openSession({
    Set<ThirdPartyScope> scopes = const <ThirdPartyScope>{
      ThirdPartyScope.genreRead,
      ThirdPartyScope.urlResolve,
    },
    bool foregroundConfirmed = false,
  }) async {
    final code = codes.issue(
      clientId: kClientId,
      packageName: 'com.example.test',
      scopes: scopes,
      port: 0,
      foregroundConfirmed: foregroundConfirmed,
    );
    final port = await server.start(
      clientId: kClientId,
      code: code,
      scopes: scopes,
      provider: provider,
      foregroundConfirmed: foregroundConfirmed,
      packageName: 'com.example.test',
    );
    codes.attachPort(code, port);
    return (code: code, port: port);
  }

  test('签发 code → POST 交换成功，返回结构符合 §6.5', () async {
    final session = await openSession();
    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
      body: jsonEncode(<String, Object?>{
        'request': <String, Object?>{
          'genre.read': <String, Object?>{},
          'url.resolve': <String, Object?>{
            'song': <String, Object?>{
              'id': 's1',
              'name': '歌名',
              'source': 'netease',
            },
          },
        },
      }),
    );

    expect(response.status, 200);
    final json = response.json;
    expect(json['client_id'], kClientId);
    expect(json['scopes'], <String>['genre.read', 'url.resolve']);
    expect(json['issued_at'], clock);

    final data = json['data'] as Map<String, dynamic>;
    final genres = data['genre.read'] as Map<String, dynamic>;
    expect(genres['sampleSize'], 3);
    expect((genres['topGenres'] as List).first['tag'], '流行');
    final resolved = data['url.resolve'] as Map<String, dynamic>;
    expect(resolved['url'], 'https://example.com/a.mp3');
    expect(resolved['source'], 'netease');
    expect(resolved['songId'], 's1');

    // 透传给 provider 的 song 对象被完整还原
    expect(provider.paramsSeen[ThirdPartyScope.urlResolve]?['song']['id'], 's1');

    // 成功后立即关服（T3）
    expect(server.isRunning(kClientId), isFalse);
  });

  test('同一 code 第二次交换 → 401 invalid_code', () async {
    final session = await openSession();
    final first = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
    );
    expect(first.status, 200);

    // 即使再用同一 code 起一个新会话，code 已被消费
    final port = await server.start(
      clientId: kClientId,
      code: session.code,
      scopes: <ThirdPartyScope>{ThirdPartyScope.genreRead},
      provider: provider,
    );
    final second = await rawExchange(
      port,
      authorization: 'Bearer ${session.code}',
    );

    expect(second.status, 401);
    expect(second.error, AuthErrors.invalidCode);
  });

  test('过期 code → 401 code_expired', () async {
    final session = await openSession();
    clock += 61; // TTL 60s

    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
    );

    expect(response.status, 401);
    expect(response.error, AuthErrors.codeExpired);
  });

  test('Host 头不正确 → 400', () async {
    final session = await openSession();

    final response = await rawExchange(
      session.port,
      host: 'evil.example.com',
      authorization: 'Bearer ${session.code}',
    );

    expect(response.status, 400);
    expect(response.error, AuthErrors.badRequest);
  });

  test('请求体超 32KB → 413', () async {
    final session = await openSession();
    final huge = jsonEncode(<String, Object?>{
      'request': <String, Object?>{},
      'pad': 'x' * (33 * 1024),
    });

    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
      body: huge,
    );

    expect(response.status, 413);
    expect(response.error, AuthErrors.badRequest);
  });

  test('请求里出现未授权的 scope → 403 scope_not_granted', () async {
    final session = await openSession(
      scopes: <ThirdPartyScope>{ThirdPartyScope.genreRead},
    );

    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
      body: jsonEncode(<String, Object?>{
        'request': <String, Object?>{
          'url.resolve': <String, Object?>{
            'song': <String, Object?>{'id': 's1'},
          },
        },
      }),
    );

    expect(response.status, 403);
    expect(response.error, AuthErrors.scopeNotGranted);
  });

  test('account.token 未带 foregroundConfirmed → 403，不返回令牌', () async {
    final session = await openSession(
      scopes: <ThirdPartyScope>{ThirdPartyScope.accountToken},
      foregroundConfirmed: false,
    );

    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
      body: jsonEncode(<String, Object?>{
        'request': <String, Object?>{
          'account.token': <String, Object?>{},
        },
      }),
    );

    expect(response.status, 403);
    expect(response.error, AuthErrors.scopeNotGranted);
    expect(response.body, isNot(contains('token-value')));
  });

  test('account.token 已前台确认 → 200 并返回令牌字段', () async {
    final session = await openSession(
      scopes: <ThirdPartyScope>{ThirdPartyScope.accountToken},
      foregroundConfirmed: true,
    );

    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
      body: jsonEncode(<String, Object?>{
        'request': <String, Object?>{
          'account.token': <String, Object?>{'platform': 'standard'},
        },
      }),
    );

    expect(response.status, 200);
    final data = response.json['data'] as Map<String, dynamic>;
    final token = data['account.token'] as Map<String, dynamic>;
    expect(token['token'], 'token-value');
    expect(token['userId'], '42');
    expect(provider.paramsSeen[ThirdPartyScope.accountToken]?['platform'],
        'standard');
  });

  test('缺少 Authorization → 401', () async {
    final session = await openSession();
    final response = await rawExchange(session.port);
    expect(response.status, 401);
    expect(response.error, AuthErrors.invalidCode);
  });

  test('Bearer 与本次会话 code 不符 → 401', () async {
    final session = await openSession();
    final response = await rawExchange(session.port, authorization: 'Bearer wrong-code');
    expect(response.status, 401);
  });

  test('GET /v1/exchange → 405', () async {
    final session = await openSession();
    final response = await rawExchange(
      session.port,
      method: 'GET',
      authorization: 'Bearer ${session.code}',
    );
    expect(response.status, 405);
  });

  test('其它路径 → 404', () async {
    final session = await openSession();
    final response = await rawExchange(
      session.port,
      path: '/v1/steal',
      authorization: 'Bearer ${session.code}',
    );
    expect(response.status, 404);
  });

  test('取数失败（not_logged_in）→ 400 + 错误码透传', () async {
    provider.error = const ThirdPartyException('not_logged_in', '尚未登录');
    final session = await openSession(
      scopes: <ThirdPartyScope>{ThirdPartyScope.accountToken},
      foregroundConfirmed: true,
    );

    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
      body: jsonEncode(<String, Object?>{
        'request': <String, Object?>{'account.token': <String, Object?>{}},
      }),
    );

    expect(response.status, 400);
    expect(response.error, 'not_logged_in');
  });

  test('单 scope 失败不拖垮整次交换 → 200 + data + errors', () async {
    // 直链解析失败（通常是「App 没在放歌」），曲风数据必须照常返回
    provider.errors[ThirdPartyScope.urlResolve] = const ThirdPartyException(
      'bad_request',
      '缺少 song 对象：请在 params.song 中指定歌曲',
    );
    final session = await openSession();

    final response = await rawExchange(
      session.port,
      authorization: 'Bearer ${session.code}',
    );

    expect(response.status, 200);
    final data = response.json['data'] as Map<String, dynamic>;
    expect(data.keys, contains('genre.read'));
    expect(data.keys, isNot(contains('url.resolve')));

    final errors = response.json['errors'] as Map<String, dynamic>;
    expect((errors['url.resolve'] as Map)['error'], 'bad_request');

    // code 已消费、服务已关（一次性语义不受部分失败影响）
    expect(codes.consume(session.code), isNull);
  });

  test('新会话替换同一 client 的旧会话', () async {
    final first = await openSession();
    expect(server.isRunning(kClientId), isTrue);

    final second = await openSession();
    expect(server.sessionCount, 1);

    // 旧会话的端口已关闭
    final oldResponse = await rawExchange(
      first.port,
      authorization: 'Bearer ${first.code}',
    );
    expect(oldResponse.status, isNot(200));

    // 新会话可用
    final newResponse = await rawExchange(
      second.port,
      authorization: 'Bearer ${second.code}',
    );
    expect(newResponse.status, 200);
  });
}

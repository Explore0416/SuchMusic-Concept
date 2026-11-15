import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/third_party_auth.dart';
import 'package:such_music/services/third_party/client_registry.dart';
import 'package:such_music/services/third_party/remote_clients.dart';

/// 官方测试向量（任务书给出，必须验签通过）。
const String _vectorClientId = 'sm_0123456789abcdef';
const String _vectorPackage = 'com.example.player';
const String _vectorSha =
    '3a7f1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8';
const int _vectorGeneratedAt = 1794700000;
const String _vectorSignatureB64Url =
    'QmCowoij2l_d1nq45rWf1vjgrwdNfY33Q72mS088A1V8AaETlyK-eP7n6apdbsvLZIRqk_cmXxz8zoGlSquKCQ';
const String _vectorMessage =
    'suchmusic-clients-v1\n$_vectorGeneratedAt\n$_vectorClientId\n$_vectorPackage\n$_vectorSha\ngenre.read,url.resolve';

/// 用测试向量构造一份完整清单响应。
Map<String, dynamic> vectorResponse({
  String keyId = 'k1',
  String signature = _vectorSignatureB64Url,
  String packageName = _vectorPackage,
  String clientId = _vectorClientId,
  String sha = _vectorSha,
  List<String> scopes = const <String>['genre.read', 'url.resolve'],
  int generatedAt = _vectorGeneratedAt,
  String displayName = '示例播放器',
  List<Map<String, dynamic>>? clients,
}) => <String, dynamic>{
  'version': 1,
  'key_id': keyId,
  'generated_at': generatedAt,
  'clients':
      clients ??
      <Map<String, dynamic>>[
        <String, dynamic>{
          'client_id': clientId,
          'display_name': displayName,
          'package_name': packageName,
          'signature_sha256': sha,
          'scopes': scopes,
        },
      ],
  'signature': signature,
};

/// 内存缓存（不碰 shared_preferences 平台通道）。
class _MemoryCache implements RemoteClientsCache {
  String? value;
  int writeCount = 0;
  int clearCount = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String text) async {
    value = text;
    writeCount++;
  }

  @override
  Future<void> clear() async {
    value = null;
    clearCount++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('签名串拼装与验签', () {
    test('签名串与协议规则逐字节一致', () {
      final message = RemoteClients.buildSigningMessage(vectorResponse());
      expect(message, _vectorMessage);
    });

    test('官方测试向量验签通过', () {
      expect(RemoteClients.verifyPayload(vectorResponse()), isTrue);
    });

    test('签名改一位 → 验签失败', () {
      // 只动一个字符，长度不变。
      final tampered = _vectorSignatureB64Url.replaceRange(0, 1, 'R');
      expect(
        RemoteClients.verifyPayload(vectorResponse(signature: tampered)),
        isFalse,
      );
    });

    test('篡改 payload（改 package_name）签名不变 → 验签失败', () {
      expect(
        RemoteClients.verifyPayload(
          vectorResponse(packageName: 'com.example.hacker'),
        ),
        isFalse,
      );
    });

    test('篡改 payload（改 scopes 顺序不影响，改内容影响）', () {
      // 字典序排序后再拼，顺序无关。
      expect(
        RemoteClients.verifyPayload(
          vectorResponse(scopes: const <String>['url.resolve', 'genre.read']),
        ),
        isTrue,
      );
      // 内容变化则失败。
      expect(
        RemoteClients.verifyPayload(
          vectorResponse(scopes: const <String>['genre.read']),
        ),
        isFalse,
      );
    });

    test('未知 key_id → 验签失败', () {
      expect(RemoteClients.verifyPayload(vectorResponse(keyId: 'k2')), isFalse);
    });

    test('结构异常 → 验签失败（不抛异常）', () {
      expect(RemoteClients.verifyPayload(const <String, dynamic>{}), isFalse);
      expect(
        RemoteClients.verifyPayload(<String, dynamic>{
          'version': 1,
          'key_id': 'k1',
          'generated_at': _vectorGeneratedAt,
          'clients': 'not-a-list',
          'signature': _vectorSignatureB64Url,
        }),
        isFalse,
      );
      expect(
        RemoteClients.verifyPayload(<String, dynamic>{
          'version': 1,
          'key_id': 'k1',
          'generated_at': _vectorGeneratedAt,
          'clients': <Object?>[],
          'signature': '!!!not-base64!!!',
        }),
        isFalse,
      );
      // 版本不是 1。
      expect(
        RemoteClients.verifyPayload(<String, dynamic>{
          ...vectorResponse(),
          'version': 2,
        }),
        isFalse,
      );
    });
  });

  group('条目校验', () {
    test('非法条目被逐条丢弃，合法条目保留', () {
      final parsed = RemoteClients.parseClients(<Object?>[
        <String, dynamic>{
          'client_id': _vectorClientId,
          'display_name': '示例播放器',
          'package_name': _vectorPackage,
          'signature_sha256': _vectorSha,
          'scopes': <String>['genre.read', 'url.resolve'],
        },
        // signature_sha256 只有 32 位 → 丢弃
        <String, dynamic>{
          'client_id': 'sm_short_sig',
          'display_name': '短签名',
          'package_name': 'com.example.short',
          'signature_sha256': '3a7f1b2c3d4e5f60718293a4b5c6d7e8',
          'scopes': <String>['genre.read'],
        },
        // scopes 含非法值 → 丢弃
        <String, dynamic>{
          'client_id': 'sm_bad_scope',
          'display_name': '非法 scope',
          'package_name': 'com.example.badscope',
          'signature_sha256': _vectorSha,
          'scopes': <String>['genre.read', 'admin.everything'],
        },
        // 大写 hex → 丢弃
        <String, dynamic>{
          'client_id': 'sm_upper_hex',
          'display_name': '大写',
          'package_name': 'com.example.upper',
          'signature_sha256': _vectorSha.toUpperCase(),
          'scopes': <String>['url.resolve'],
        },
        // package_name 为空 → 丢弃
        <String, dynamic>{
          'client_id': 'sm_empty_pkg',
          'display_name': '空包名',
          'package_name': '   ',
          'signature_sha256': _vectorSha,
          'scopes': <String>['url.resolve'],
        },
        // 结构不是对象 → 丢弃
        'garbage',
      ]);

      expect(parsed.length, 1);
      expect(parsed.single.clientId, _vectorClientId);
      expect(parsed.single.packageName, _vectorPackage);
      expect(parsed.single.signatureSha256, _vectorSha);
      expect(parsed.single.displayName, '示例播放器');
    });

    test('scopes 缺失或非字符串数组被丢弃', () {
      final parsed = RemoteClients.parseClients(<Object?>[
        <String, dynamic>{
          'client_id': 'sm_no_scopes',
          'package_name': 'com.example.a',
          'signature_sha256': _vectorSha,
        },
        <String, dynamic>{
          'client_id': 'sm_bad_scopes_type',
          'package_name': 'com.example.b',
          'signature_sha256': _vectorSha,
          'scopes': 'genre.read',
        },
        <String, dynamic>{
          'client_id': 'sm_scopes_num',
          'package_name': 'com.example.c',
          'signature_sha256': _vectorSha,
          'scopes': <Object?>[1, 2],
        },
      ]);
      expect(parsed, isEmpty);
    });

    test('非数组 clients → 空列表', () {
      expect(RemoteClients.parseClients(null), isEmpty);
      expect(RemoteClients.parseClients('x'), isEmpty);
      expect(RemoteClients.parseClients(<String, dynamic>{}), isEmpty);
    });
  });

  group('合并优先级', () {
    const builtIn = ThirdPartyClient(
      clientId: 'sm_shared',
      packageName: 'com.example.old',
      signatureSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      displayName: '内置旧包名',
    );
    const remote = ThirdPartyClient(
      clientId: 'sm_shared',
      packageName: 'com.example.new',
      signatureSha256:
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      displayName: '远端新包名',
    );
    const onlyBuiltIn = ThirdPartyClient(
      clientId: 'sm_builtin_only',
      packageName: 'com.example.builtin',
      signatureSha256:
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      displayName: '仅内置',
    );

    test('同 client_id 以远端为准', () {
      final merged = mergeClients(
        builtIn: <ThirdPartyClient>[builtIn, onlyBuiltIn],
        remote: <ThirdPartyClient>[remote],
        includeDebugProbe: false,
      );
      expect(merged.length, 2);
      final shared = merged.firstWhere((c) => c.clientId == 'sm_shared');
      expect(shared.packageName, 'com.example.new');
      expect(shared.displayName, '远端新包名');
      expect(
        merged.any((c) => c.clientId == 'sm_builtin_only'),
        isTrue,
        reason: '远端没有的条目应保留内置版本',
      );
    });

    test('debug 探针始终注入且不被远端覆盖', () {
      final merged = mergeClients(
        builtIn: const <ThirdPartyClient>[],
        remote: const <ThirdPartyClient>[
          ThirdPartyClient(
            clientId: 'debug.suchmusic.probe',
            packageName: 'com.evil.probe',
            signatureSha256:
                'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
            displayName: '伪造探针',
          ),
        ],
        includeDebugProbe: true,
      );
      final probe = merged.firstWhere(
        (c) => c.clientId == kDebugProbeClient.clientId,
      );
      expect(probe.packageName, kDebugProbeClient.packageName);
      expect(probe.signatureSha256, isEmpty);
    });

    test('ClientRegistry.standard() 能查到远端条目', () async {
      final cache = _MemoryCache();
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async => jsonEncode(vectorResponse()),
      );
      await remoteClients.refresh(force: true);

      // 直接用注入实例的 clients 校验合并语义（standard() 走全局单例）。
      final merged = mergeClients(
        builtIn: kBuiltInClients,
        remote: remoteClients.clients,
        includeDebugProbe: false,
      );
      final registry = ClientRegistry(merged);
      expect(registry.findById(_vectorClientId)?.packageName, _vectorPackage);
      expect(registry.findByPackage(_vectorPackage)?.clientId, _vectorClientId);
      expect(
        registry.findById('  $_vectorClientId  ')?.clientId,
        _vectorClientId,
      );
      expect(registry.findById(''), isNull);
      expect(registry.findByPackage('com.not.registered'), isNull);
    });
  });

  group('刷新 / 缓存 / 失败回退', () {
    test('成功刷新：写入缓存、记录时间', () async {
      final cache = _MemoryCache();
      final now = DateTime.fromMillisecondsSinceEpoch(1794700100000);
      final remoteClients = RemoteClients(
        cache: cache,
        now: () => now,
        fetcher: (Uri uri) async => jsonEncode(vectorResponse()),
      );

      expect(await remoteClients.refresh(force: true), isTrue);
      expect(remoteClients.clients.length, 1);
      expect(remoteClients.lastSyncedAt, now);
      expect(cache.value, isNotNull);

      final wrapper = jsonDecode(cache.value!) as Map<String, dynamic>;
      expect(wrapper['schema'], RemoteClients.cacheSchemaVersion);
      expect(wrapper['fetched_at'], now.millisecondsSinceEpoch);
      expect(wrapper['payload'], isA<String>());
    });

    test('网络失败：refresh 返回 false 且不清空已有清单', () async {
      final cache = _MemoryCache();
      var shouldThrow = false;
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async {
          if (shouldThrow) throw Exception('boom');
          return jsonEncode(vectorResponse());
        },
      );

      expect(await remoteClients.refresh(force: true), isTrue);
      expect(remoteClients.clients.length, 1);

      shouldThrow = true;
      expect(await remoteClients.refresh(force: true), isFalse);
      expect(remoteClients.clients.length, 1, reason: '失败必须保留上一次有效清单');
      expect(remoteClients.lastSyncedAt, isNotNull);
    });

    test('验签失败：不覆盖已有清单，也不写缓存', () async {
      final cache = _MemoryCache();
      var tamper = false;
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async => jsonEncode(
          tamper
              ? vectorResponse(packageName: 'com.example.hacker')
              : vectorResponse(),
        ),
      );

      expect(await remoteClients.refresh(force: true), isTrue);
      final firstCache = cache.value;

      tamper = true;
      expect(await remoteClients.refresh(force: true), isFalse);
      expect(remoteClients.clients.single.packageName, _vectorPackage);
      expect(cache.value, firstCache, reason: '验签失败不应改写缓存');
    });

    test('缓存恢复：先读缓存生效，再异步刷新', () async {
      final cache = _MemoryCache();
      // 先造一份合法缓存。
      final writer = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async => jsonEncode(vectorResponse()),
      );
      await writer.refresh(force: true);
      final cached = cache.value;

      final readerCache = _MemoryCache()..value = cached;
      final reader = RemoteClients(
        cache: readerCache,
        fetcher: (Uri uri) async => throw Exception('offline'),
      );

      await reader.warmUp();
      expect(reader.clients.length, 1);
      expect(reader.clients.single.clientId, _vectorClientId);
      expect(reader.lastSyncedAt, isNotNull);
    });

    test('缓存被篡改：重新验签不过则丢弃', () async {
      final tamperedPayload = vectorResponse(packageName: 'com.example.hacker');
      final cache = _MemoryCache()
        ..value = jsonEncode(<String, dynamic>{
          'schema': RemoteClients.cacheSchemaVersion,
          'fetched_at': 1794700100000,
          'payload': jsonEncode(tamperedPayload),
        });
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async => throw Exception('offline'),
      );

      await remoteClients.warmUp();
      expect(remoteClients.clients, isEmpty);
      expect(cache.value, isNull, reason: '验签不过的缓存应被清掉');
    });

    test('缓存不是 JSON：丢弃不抛错', () async {
      final cache = _MemoryCache()..value = 'not-json{';
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async => throw Exception('offline'),
      );

      await remoteClients.warmUp();
      expect(remoteClients.clients, isEmpty);
      expect(cache.value, isNull);
    });

    test('并发保护：同时只有一个请求在飞', () async {
      final cache = _MemoryCache();
      var calls = 0;
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return jsonEncode(vectorResponse());
        },
      );

      final results = await Future.wait<bool>(<Future<bool>>[
        remoteClients.refresh(force: true),
        remoteClients.refresh(force: true),
        remoteClients.refresh(force: true),
      ]);
      expect(calls, 1);
      expect(results, <bool>[true, true, true]);
    });

    test('resetForTest 清空内存与缓存', () async {
      final cache = _MemoryCache();
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async => jsonEncode(vectorResponse()),
      );
      await remoteClients.refresh(force: true);
      expect(remoteClients.clients, isNotEmpty);

      await remoteClients.resetForTest();
      expect(remoteClients.clients, isEmpty);
      expect(remoteClients.lastSyncedAt, isNull);
      expect(cache.value, isNull);
    });

    test('非强制刷新在间隔内不发网络请求', () async {
      final cache = _MemoryCache();
      var calls = 0;
      final remoteClients = RemoteClients(
        cache: cache,
        fetcher: (Uri uri) async {
          calls++;
          return jsonEncode(vectorResponse());
        },
      );
      expect(await remoteClients.refresh(), isTrue);
      expect(await remoteClients.refresh(), isTrue);
      expect(calls, 1);
      expect(await remoteClients.refresh(force: true), isTrue);
      expect(calls, 2);
    });
  });
}

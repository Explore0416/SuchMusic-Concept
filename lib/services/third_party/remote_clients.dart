import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/third_party_auth.dart';
import 'ed25519.dart';

/// 拉取原始清单文本的注入点（默认用 dio 打线上接口）。
///
/// 抽成函数类型是为了让单测注入「抛错的假客户端」，**测试不真的发网络请求**。
typedef RemoteClientsFetcher = Future<String> Function(Uri endpoint);

/// 远端清单缓存的读写抽象（默认 `shared_preferences`）。
///
/// 同样为了可注入：单测用内存实现，不碰平台通道。
abstract class RemoteClientsCache {
  /// 读缓存原文；不存在返回 null。
  Future<String?> read();

  /// 覆盖写缓存原文。
  Future<void> write(String value);

  /// 清除缓存（验签失败 / 结构异常时丢弃）。
  Future<void> clear();
}

/// 默认实现：`shared_preferences` 单键存一段 JSON 包装。
class SharedPreferencesRemoteClientsCache implements RemoteClientsCache {
  const SharedPreferencesRemoteClientsCache({
    this.key = RemoteClients.cacheKey,
  });

  /// 存储键。
  final String key;

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}

/// 开放平台第三方白名单清单（ARCHITECTURE §8.3 / §14 v1.3）。
///
/// 1.5.0 之前白名单硬编码在 `client_registry.dart`，每接一个第三方都要发版。
/// 现在改为「内置 ∪ 远端」：
///
/// - 远端清单带 Ed25519 签名，验签通过才生效（信任根 = 内置公钥，key 不轮换即不需发版）；
/// - 拉到的原文带拉取时间落盘；**启动时重新验签**，缓存被改过也不会生效；
/// - 任何一步失败（网络 / 验签 / JSON 结构）都静默保留上一次有效清单，
///   不抛异常、不弹窗、不阻断启动。
///
/// 日志只打「条数 + 时间」，**绝不打印清单全文**（防止把第三方包名/签名刷进日志）。
class RemoteClients {
  /// [fetcher] / [cache] / [now] 均可注入（单测用）。
  RemoteClients({
    RemoteClientsFetcher? fetcher,
    RemoteClientsCache? cache,
    DateTime Function()? now,
    this.minRefreshInterval = const Duration(hours: 6),
  }) : _fetcher = fetcher ?? _defaultFetcher,
       _cache = cache ?? const SharedPreferencesRemoteClientsCache(),
       _now = now ?? DateTime.now;

  /// 全局单例（`main.dart` 启动时 warmUp）。
  static final RemoteClients instance = RemoteClients();

  /// 公开清单接口。
  static const String endpointUrl =
      'https://open.lightning-team.top/api/v1/clients';

  /// 缓存键（1.5.1 起使用）。
  static const String cacheKey = 'third_party.remote_clients.v1';

  /// 签名串第一行（域分隔，防跨用途重放）。
  static const String signatureDomain = 'suchmusic-clients-v1';

  /// 客户端条目之间的分隔符。
  static const String entrySeparator = '\n---\n';

  /// 支持的清单版本。
  static const int supportedVersion = 1;

  /// 缓存包装的 schema 版本。
  static const int cacheSchemaVersion = 1;

  /// 内置公钥白名单：key_id → raw 32 字节 Ed25519 公钥（base64）。
  ///
  /// 新增密钥 = 追加一条 + 发版；未知 key_id 一律视为验签失败。
  static const Map<String, String> trustedPublicKeys = <String, String>{
    'k1': 'us5wih65A/fe2362HvwdcPQaU7AwdUztSccVv22GjrI=',
  };

  /// 允许出现的 scope 集合（清单里出现其它值 → 丢弃该条）。
  static const Set<String> allowedScopes = <String>{
    'genre.read',
    'account.token',
    'url.resolve',
    'playback.control',
  };

  /// `signature_sha256` 的合法形态：64 位小写 hex。
  static final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  /// 非强制刷新时的最小间隔（避免频繁拉取）。
  final Duration minRefreshInterval;

  final RemoteClientsFetcher _fetcher;
  final RemoteClientsCache _cache;
  final DateTime Function() _now;

  /// 当前生效的远端清单（验签通过），未加载时为空。
  List<ThirdPartyClient> _clients = const <ThirdPartyClient>[];

  /// 上次成功拉取（或从缓存恢复）的时间。
  DateTime? _lastSyncedAt;

  /// 正在飞行的刷新请求（并发保护：同一时刻只允许一个）。
  Future<bool>? _inflight;

  /// 是否已做过缓存恢复（warmUp 只读一次缓存）。
  bool _warmedUp = false;

  /// 当前生效的远端清单（验签通过的），未加载时为空。
  List<ThirdPartyClient> get clients =>
      List<ThirdPartyClient>.unmodifiable(_clients);

  /// 上次成功拉取的时间；从未成功过为 null。
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// 当前生效条数（日志用，避免打印全文）。
  int get count => _clients.length;

  /// 启动时调用：先读缓存，再异步刷新（不等网络）。
  ///
  /// 缓存读出即生效（会被**重新验签**），网络刷新在后台跑，
  /// 失败静默；本方法本身不抛异常，可安全 `unawaited`。
  Future<void> warmUp() async {
    if (!_warmedUp) {
      _warmedUp = true;
      try {
        await _restoreFromCache();
      } catch (error) {
        _log('缓存读取失败（忽略）: ${error.runtimeType}');
      }
    }
    unawaited(refresh());
  }

  /// 拉取、验签、缓存。
  ///
  /// [force] 为 false 且距上次成功拉取不足 [minRefreshInterval] 时跳过网络。
  /// 失败静默返回 false，**不抛错**，也不会清空已有清单。
  Future<bool> refresh({bool force = false}) {
    final pending = _inflight;
    if (pending != null) return pending;
    final task = _refreshOnce(force: force);
    _inflight = task;
    return task.whenComplete(() {
      _inflight = null;
    });
  }

  /// 仅测试用：清空内存状态与缓存。
  @visibleForTesting
  Future<void> resetForTest() async {
    _clients = const <ThirdPartyClient>[];
    _lastSyncedAt = null;
    _inflight = null;
    _warmedUp = false;
    try {
      await _cache.clear();
    } catch (_) {
      // 清缓存失败不影响测试语义。
    }
  }

  // ── 内部实现 ───────────────────────────────────────────────────

  Future<bool> _refreshOnce({required bool force}) async {
    final last = _lastSyncedAt;
    if (!force &&
        last != null &&
        _now().difference(last) < minRefreshInterval &&
        _clients.isNotEmpty) {
      // 名单还是新的，跳过网络，保持「有效」语义。
      return true;
    }
    try {
      final raw = await _fetcher(Uri.parse(endpointUrl));
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _log('清单结构异常（非对象），保持现有清单');
        return false;
      }
      final payload = <String, dynamic>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
      if (!verifyPayload(payload)) {
        _log('清单验签失败，丢弃本次响应');
        return false;
      }
      final parsed = parseClients(payload['clients']);
      // 验签通过才落盘：缓存里存的是**原始响应文本** + 拉取时间。
      _apply(parsed, _now());
      await _writeCache(raw, _now());
      _log('清单已更新: ${parsed.length} 条 @ ${_lastSyncedAt?.toIso8601String()}');
      return true;
    } catch (error) {
      // 网络异常 / JSON 解析异常 / 未预期异常：全部静默。
      _log('拉取失败（保持现有清单）: ${error.runtimeType}');
      return false;
    }
  }

  void _apply(List<ThirdPartyClient> parsed, DateTime syncedAt) {
    _clients = List<ThirdPartyClient>.unmodifiable(parsed);
    _lastSyncedAt = syncedAt;
  }

  Future<void> _restoreFromCache() async {
    final raw = await _cache.read();
    if (raw == null || raw.isEmpty) return;
    final Map<String, dynamic> wrapper;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      _log('缓存不是合法 JSON，丢弃');
      await _cache.clear();
      return;
    }
    if (decoded is! Map) {
      _log('缓存结构异常，丢弃');
      await _cache.clear();
      return;
    }
    wrapper = <String, dynamic>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    };
    final payloadText = wrapper['payload'];
    final fetchedAt = wrapper['fetched_at'];
    if (payloadText is! String || payloadText.isEmpty) {
      _log('缓存缺 payload，丢弃');
      await _cache.clear();
      return;
    }
    final Object? payloadRaw;
    try {
      payloadRaw = jsonDecode(payloadText);
    } catch (_) {
      _log('缓存 payload 非法，丢弃');
      await _cache.clear();
      return;
    }
    if (payloadRaw is! Map) {
      _log('缓存 payload 结构异常，丢弃');
      await _cache.clear();
      return;
    }
    final payload = <String, dynamic>{
      for (final entry in payloadRaw.entries) entry.key.toString(): entry.value,
    };
    // 关键：缓存来自磁盘，可能被改过 —— 必须重新验签。
    if (!verifyPayload(payload)) {
      _log('缓存验签失败，丢弃');
      await _cache.clear();
      return;
    }
    final parsed = parseClients(payload['clients']);
    final syncedAt = fetchedAt is num
        ? DateTime.fromMillisecondsSinceEpoch(fetchedAt.toInt())
        : _now();
    _apply(parsed, syncedAt);
    _log('已从缓存恢复: ${parsed.length} 条 @ ${syncedAt.toIso8601String()}');
  }

  Future<void> _writeCache(String payloadText, DateTime fetchedAt) async {
    final wrapper = jsonEncode(<String, dynamic>{
      'schema': cacheSchemaVersion,
      'fetched_at': fetchedAt.millisecondsSinceEpoch,
      'payload': payloadText,
    });
    try {
      await _cache.write(wrapper);
    } catch (error) {
      _log('缓存写入失败（忽略）: ${error.runtimeType}');
    }
  }

  // ── 验签与解析（静态，便于单测直接调用） ────────────────────────

  /// 校验一份清单 JSON：版本 / key_id / 结构 / 签名。
  ///
  /// 全部合法返回 true；任何一项不合法返回 false，**不抛异常**。
  /// 这里只看签名，不看条目内容合法性（条目过滤见 [parseClients]）。
  @visibleForTesting
  static bool verifyPayload(Map<String, dynamic> payload) {
    try {
      final version = payload['version'];
      if (version is! int || version != supportedVersion) return false;

      final keyId = payload['key_id'];
      if (keyId is! String) return false;
      final publicKeyText = trustedPublicKeys[keyId];
      if (publicKeyText == null) return false;

      final generatedAt = payload['generated_at'];
      if (generatedAt is! int) return false;

      final signatureText = payload['signature'];
      if (signatureText is! String || signatureText.isEmpty) return false;

      final message = buildSigningMessage(payload);
      if (message == null) return false;

      final signature = decodeBase64UrlBytes(signatureText);
      final key = Ed25519PublicKey.fromBase64(publicKeyText);
      return key.verify(
        message: Uint8List.fromList(utf8.encode(message)),
        signature: signature,
      );
    } catch (_) {
      // 公钥非法 / base64 非法 / 字段类型异常：一律按验签失败处理。
      return false;
    }
  }

  /// 按 §4.4.1 规则拼签名串；结构不合法返回 null。
  ///
  /// ```text
  /// suchmusic-clients-v1\n
  /// <generated_at>\n
  /// <client_1>\n<package_1>\n<signature_1>\n<scopes_1> ---\n---\n <client_2>...
  /// ```
  /// `display_name` 不参与签名；每条 scopes 按字典序升序、逗号连接。
  @visibleForTesting
  static String? buildSigningMessage(Map<String, dynamic> payload) {
    final generatedAt = payload['generated_at'];
    final clients = payload['clients'];
    if (generatedAt is! int || clients is! List) return null;

    final blocks = <String>[];
    for (final raw in clients) {
      if (raw is! Map) return null;
      final entry = <String, dynamic>{
        for (final e in raw.entries) e.key.toString(): e.value,
      };
      final clientId = entry['client_id'];
      final packageName = entry['package_name'];
      final signatureSha256 = entry['signature_sha256'];
      final scopes = entry['scopes'];
      if (clientId is! String ||
          packageName is! String ||
          signatureSha256 is! String ||
          scopes is! List) {
        return null;
      }
      final scopeCodes = <String>[];
      for (final scope in scopes) {
        if (scope is! String) return null;
        scopeCodes.add(scope);
      }
      scopeCodes.sort();
      blocks.add(
        <String>[
          clientId,
          packageName,
          signatureSha256,
          scopeCodes.join(','),
        ].join('\n'),
      );
    }
    return <String>[
      signatureDomain,
      '$generatedAt',
      blocks.join(entrySeparator),
    ].join('\n');
  }

  /// 把 `clients` 数组解析成 [ThirdPartyClient]，**逐条校验、逐条丢弃**。
  ///
  /// 丢弃条件：`client_id` / `package_name` 为空、`signature_sha256` 不是
  /// 64 位小写 hex、`scopes` 缺失或含四个合法值以外的项。
  /// 单条不合法不影响其它条目（不做整份丢弃）。
  @visibleForTesting
  static List<ThirdPartyClient> parseClients(Object? rawClients) {
    if (rawClients is! List) return const <ThirdPartyClient>[];
    final byId = <String, ThirdPartyClient>{};
    for (final raw in rawClients) {
      if (raw is! Map) continue;
      final entry = <String, dynamic>{
        for (final e in raw.entries) e.key.toString(): e.value,
      };
      final clientId = (entry['client_id'] as Object?)?.toString().trim() ?? '';
      final packageName =
          (entry['package_name'] as Object?)?.toString().trim() ?? '';
      final signatureSha256 =
          (entry['signature_sha256'] as Object?)?.toString().trim() ?? '';
      if (clientId.isEmpty || packageName.isEmpty) continue;
      if (!_sha256Pattern.hasMatch(signatureSha256)) continue;
      if (!_hasOnlyKnownScopes(entry['scopes'])) continue;
      final displayName = (entry['display_name'] as Object?)?.toString() ?? '';
      byId[clientId] = ThirdPartyClient(
        clientId: clientId,
        packageName: packageName,
        signatureSha256: signatureSha256,
        displayName: displayName.isEmpty ? clientId : displayName,
      );
    }
    final list = byId.values.toList();
    list.sort((a, b) => a.clientId.compareTo(b.clientId));
    return List<ThirdPartyClient>.unmodifiable(list);
  }

  /// `scopes` 必须是「全部落在 [allowedScopes] 内」的字符串数组。
  static bool _hasOnlyKnownScopes(Object? scopes) {
    if (scopes is! List) return false;
    for (final scope in scopes) {
      if (scope is! String) return false;
      if (!allowedScopes.contains(scope)) return false;
    }
    return true;
  }

  // ── 默认 HTTP 客户端 ───────────────────────────────────────────

  /// 默认拉取实现：dio + 5 秒超时 + 不跟随重定向 + `accept: application/json`。
  static Future<String> _defaultFetcher(Uri endpoint) async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        sendTimeout: const Duration(seconds: 5),
        // 清单是固定地址的直连资源，任何重定向都视为异常（防被劫持到别处）。
        followRedirects: false,
        headers: const <String, String>{'accept': 'application/json'},
        responseType: ResponseType.plain,
        validateStatus: (int? status) => status == 200,
      ),
    );
    try {
      final response = await dio.get<String>(endpoint.toString());
      final data = response.data;
      if (data is! String || data.isEmpty) {
        throw const FormatException('清单响应为空');
      }
      return data;
    } finally {
      dio.close(force: true);
    }
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[ThirdParty] $message');
  }
}

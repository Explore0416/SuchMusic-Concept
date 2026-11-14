import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../models/third_party_auth.dart';
import 'auth_code_service.dart';
import 'third_party_data_provider.dart';

/// Loopback 交换服端口（抽接口便于授权服务注入假实现做单测）。
abstract class LoopbackPort {
  /// 绑定 127.0.0.1 随机端口并开始等待一次 `POST /v1/exchange`，返回实际端口。
  Future<int> start({
    required String clientId,
    required String code,
    required Set<ThirdPartyScope> scopes,
    required ThirdPartyDataProvider provider,
    bool foregroundConfirmed = false,
    String packageName = '',
  });

  /// 关闭某 client 的会话（撤销 / 失败回滚）。
  Future<void> stop(String clientId);

  /// 关闭全部会话。
  Future<void> stopAll();
}

/// 单次数据交换的 loopback HTTP 服务（ARCHITECTURE §6.5 / ADR-002 / T3 / T4）。
///
/// 安全约束（逐条对应威胁模型）：
/// - 只绑 `127.0.0.1`，端口由系统随机分配（T3）；
/// - 必须持有效 code 才能交换，code 一次性且 60s 过期（T4）；
/// - 校验 `Host` 头，阻断 DNS rebinding 类跨站请求；
/// - 请求体上限 32KB；
/// - 成功后立即 `close(force: true)`，60s 无请求自动关闭；
/// - 每个 client 同时只保留一个会话，新会话替换旧的。
class LoopbackServer implements LoopbackPort {
  LoopbackServer({
    AuthCodeService? codes,
    this.idleTimeout = const Duration(seconds: 60),
  }) : _codes = codes ?? AuthCodeService.instance;

  /// 全局单例（授权链路使用）。
  static final LoopbackServer instance = LoopbackServer();

  /// 请求体上限（32KB）。
  static const int maxBodyBytes = 32 * 1024;

  /// 唯一的交换路径。
  static const String exchangePath = '/v1/exchange';

  /// 无请求自动关服时长（ARCH §6.5：60s）。
  final Duration idleTimeout;

  final AuthCodeService _codes;

  final Map<String, _Session> _sessions = <String, _Session>{};

  /// 是否还有会话在等待请求（诊断 / 测试用）。
  bool isRunning(String clientId) => _sessions.containsKey(clientId);

  /// 当前会话数量。
  int get sessionCount => _sessions.length;

  @override
  Future<int> start({
    required String clientId,
    required String code,
    required Set<ThirdPartyScope> scopes,
    required ThirdPartyDataProvider provider,
    bool foregroundConfirmed = false,
    String packageName = '',
  }) async {
    // 同一 client 只允许一个会话：新请求替换旧的（旧会话连同其 code 一起作废）
    await stop(clientId);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final session = _Session(
      server: server,
      clientId: clientId,
      code: code,
      scopes: Set<ThirdPartyScope>.unmodifiable(scopes),
      provider: provider,
      foregroundConfirmed: foregroundConfirmed,
      packageName: packageName,
    );
    _sessions[clientId] = session;

    // 60s 无请求自动关服（code 本身 60s 过期，双保险）
    session.idleTimer = Timer(idleTimeout, () {
      unawaited(stop(clientId));
    });

    server.listen(
      (HttpRequest request) {
        unawaited(_handle(session, request));
      },
      onError: (Object _) {
        unawaited(stop(clientId));
      },
      cancelOnError: false,
    );

    return server.port;
  }

  @override
  Future<void> stop(String clientId) async {
    final session = _sessions.remove(clientId);
    if (session == null) return;
    session.idleTimer?.cancel();
    session.idleTimer = null;
    try {
      await session.server.close(force: true);
    } catch (_) {
      // 已关闭 / 已异常，忽略
    }
  }

  @override
  Future<void> stopAll() async {
    final ids = _sessions.keys.toList();
    for (final id in ids) {
      await stop(id);
    }
  }

  // ── 请求处理 ─────────────────────────────────────────────────

  Future<void> _handle(_Session session, HttpRequest request) async {
    try {
      await _handleInner(session, request);
    } catch (e) {
      // 只输出异常类型，不输出任何请求 / 响应内容（T8：日志不得泄露令牌）
      debugPrint('[ThirdParty] loopback 处理异常: ${e.runtimeType}');
      try {
        await _respond(request, HttpStatus.badRequest, <String, Object?>{
          'error': AuthErrors.badRequest,
          'message': '请求无法处理',
        });
      } catch (_) {
        // 连接可能已断，忽略
      }
    }
  }

  Future<void> _handleInner(_Session session, HttpRequest request) async {
    // ① 只接受 POST /v1/exchange
    if (request.uri.path != exchangePath) {
      await _respond(request, HttpStatus.notFound, <String, Object?>{
        'error': AuthErrors.badRequest,
        'message': '仅支持 POST $exchangePath',
      });
      return;
    }
    if (request.method != 'POST') {
      await _respond(request, HttpStatus.methodNotAllowed, <String, Object?>{
        'error': AuthErrors.badRequest,
        'message': '仅支持 POST $exchangePath',
      });
      return;
    }

    // ② Host 头必须是 127.0.0.1:<port>
    final host = request.headers.value(HttpHeaders.hostHeader) ?? '';
    final expectedHost = '127.0.0.1:${session.server.port}';
    if (host != expectedHost) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': AuthErrors.badRequest,
        'message': 'Host 头不合法',
      });
      return;
    }

    // ③ 请求体上限 32KB
    final body = await _readBody(request);
    if (body == null) {
      await _respond(request, HttpStatus.requestEntityTooLarge, <String, Object?>{
        'error': AuthErrors.badRequest,
        'message': '请求体超过 32KB 上限',
      });
      await stop(session.clientId);
      return;
    }

    // ④ 取出 Bearer code
    final authorization =
        request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final bearer = _bearerToken(authorization);
    if (bearer.isEmpty || bearer != session.code) {
      await _respond(request, HttpStatus.unauthorized, <String, Object?>{
        'error': AuthErrors.invalidCode,
        'message': '授权码无效',
      });
      return;
    }

    final lookup = _codes.lookup(bearer);
    if (!lookup.found && !lookup.expired) {
      await _respond(request, HttpStatus.unauthorized, <String, Object?>{
        'error': AuthErrors.invalidCode,
        'message': '授权码无效或已被使用',
      });
      return;
    }
    if (lookup.expired) {
      await _respond(request, HttpStatus.unauthorized, <String, Object?>{
        'error': AuthErrors.codeExpired,
        'message': '授权码已过期，请重新发起授权',
      });
      await stop(session.clientId);
      return;
    }
    final entry = lookup.code!;
    if (entry.clientId != session.clientId) {
      await _respond(request, HttpStatus.unauthorized, <String, Object?>{
        'error': AuthErrors.invalidCode,
        'message': '授权码与客户端不匹配',
      });
      return;
    }

    // ⑤ 解析请求体
    final decoded = _decodeBody(body);
    if (decoded == null) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': AuthErrors.badRequest,
        'message': '请求体不是合法 JSON 对象',
      });
      return;
    }

    final rawRequest = decoded['request'];
    final params = <String, Map<String, dynamic>?>{};
    if (rawRequest != null && rawRequest is! Map) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': AuthErrors.badRequest,
        'message': 'request 字段必须是对象',
      });
      return;
    }
    if (rawRequest is Map) {
      for (final entryRaw in rawRequest.entries) {
        final scope = ThirdPartyScope.fromCode(entryRaw.key?.toString());
        if (scope == null) {
          await _respond(request, HttpStatus.badRequest, <String, Object?>{
            'error': AuthErrors.badRequest,
            'message': '未知的 scope: ${entryRaw.key}',
          });
          return;
        }
        if (!session.scopes.contains(scope)) {
          await _respond(request, HttpStatus.forbidden, <String, Object?>{
            'error': AuthErrors.scopeNotGranted,
            'message': '未授权的 scope: ${scope.code}',
          });
          return;
        }
        params[scope.code] = _asStringMap(entryRaw.value);
      }
    }

    // 未指定 request 时按「本枚 code 的全部 scope」返回
    final effective = params.isEmpty
        ? (session.scopes.toList()
          ..sort((a, b) => a.index.compareTo(b.index)))
        : <ThirdPartyScope>[
            for (final scope in ThirdPartyScope.values)
              if (params.containsKey(scope.code)) scope,
          ];

    // ⑥ account.token 必须带 foreground_confirmed（ARCH §6.5 / T5 / ADR-003）
    if (effective.contains(ThirdPartyScope.accountToken) &&
        !(entry.foregroundConfirmed && session.foregroundConfirmed)) {
      await _respond(request, HttpStatus.forbidden, <String, Object?>{
        'error': AuthErrors.scopeNotGranted,
        'message': '账号令牌需要用户在前台确认后才能获取',
      });
      return;
    }

    // ⑦ 一次性消费：通过上述全部校验后立刻作废该 code（T4）
    final consumed = _codes.consume(bearer);
    if (consumed == null) {
      await _respond(request, HttpStatus.unauthorized, <String, Object?>{
        'error': AuthErrors.invalidCode,
        'message': '授权码无效或已被使用',
      });
      return;
    }

    // ⑧ 取数
    final data = <String, Object?>{};
    try {
      for (final scope in effective) {
        data[scope.code] = await session.provider.fetch(scope, params[scope.code]);
      }
    } on ThirdPartyException catch (e) {
      await _respond(request, HttpStatus.badRequest, <String, Object?>{
        'error': e.code,
        'message': e.message.isEmpty ? '取数失败' : e.message,
      });
      await stop(session.clientId);
      return;
    }

    // ⑨ 成功响应
    await _respond(request, HttpStatus.ok, <String, Object?>{
      'client_id': session.clientId,
      'scopes': ThirdPartyScope.codesOf(effective),
      'issued_at': consumed.issuedAt,
      'data': data,
    });

    // ⑩ 交换成功立即关服（T3「单次交换后立即关服」）
    await stop(session.clientId);
  }

  /// 读取请求体；超过 [maxBodyBytes] 返回 null。
  ///
  /// 超限时**继续把剩余数据读掉**（不立即断开），否则客户端可能在读到响应前
  /// 收到 RST；同时设硬上限，避免恶意超大请求把内存吃光。
  Future<List<int>?> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    var tooLarge = false;
    await for (final chunk in request) {
      if (!tooLarge) {
        builder.add(chunk);
        if (builder.length > maxBodyBytes) tooLarge = true;
      }
      if (builder.length > maxBodyBytes * 4) break;
    }
    return tooLarge ? null : builder.takeBytes();
  }

  Map<String, dynamic>? _decodeBody(List<int> bytes) {
    if (bytes.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (decoded is Map) return _asStringMap(decoded) ?? <String, dynamic>{};
      return null;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _asStringMap(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return null;
    final out = <String, dynamic>{};
    raw.forEach((key, value) {
      out[key.toString()] = value;
    });
    return out;
  }

  String _bearerToken(String header) {
    final value = header.trim();
    if (value.isEmpty) return '';
    const prefix = 'Bearer ';
    if (value.length <= prefix.length) return '';
    if (value.substring(0, prefix.length).toLowerCase() != prefix.toLowerCase()) {
      return '';
    }
    return value.substring(prefix.length).trim();
  }

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    final bytes = utf8.encode(jsonEncode(body));
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    // 显式给 contentLength，客户端无需处理 chunked
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }
}

/// 一个等待交换的会话。
class _Session {
  _Session({
    required this.server,
    required this.clientId,
    required this.code,
    required this.scopes,
    required this.provider,
    required this.foregroundConfirmed,
    required this.packageName,
  });

  final HttpServer server;
  final String clientId;
  final String code;
  final Set<ThirdPartyScope> scopes;
  final ThirdPartyDataProvider provider;
  final bool foregroundConfirmed;
  final String packageName;

  Timer? idleTimer;
}

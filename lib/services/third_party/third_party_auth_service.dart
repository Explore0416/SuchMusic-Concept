import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/third_party_auth.dart';
import 'auth_code_service.dart';
import 'client_registry.dart';
import 'loopback_server.dart';
import 'third_party_bridge.dart';
import 'third_party_data_provider.dart';

/// 第三方授权唯一决策点（ARCHITECTURE §5 / §8.1）。
///
/// 所有 scope 判定、静默判定、限流、撤销检查**只在这里**完成；
/// UI（M4）与网络层（LoopbackServer）都不得自行放行或缓存授权结论。
///
/// 一次请求的固定顺序（顺序不可调整，ARCH §6.1）：
/// URI 形状 → 注册表 → 装机 / 签名 → scopes → state → 限流
/// → 静默判定 → UI 确认 → 落库 → 签发 code → 起 loopback → 投递 code。
class ThirdPartyAuthService {
  ThirdPartyAuthService({
    ClientRegistry? registry,
    ThirdPartyBridge? bridge,
    AuthCodeService? codes,
    LoopbackPort? server,
    ThirdPartyDataProvider? dataProvider,
    Future<SharedPreferences> Function()? prefs,
    int Function()? now,
    this.silentDebounce = const Duration(seconds: 5),
    this.rateLimitPerMinute = 10,
  })  : _registry = registry ?? ClientRegistry.standard(),
        _bridge = bridge ?? MethodChannelThirdPartyBridge(),
        _codes = codes ?? AuthCodeService.instance,
        _server = server ?? LoopbackServer.instance,
        _dataProvider = dataProvider ?? ThirdPartyDataProvider(),
        _prefs = prefs ?? SharedPreferences.getInstance,
        _now = now ?? _defaultNow;

  /// 全局单例（App 运行期唯一决策点）。
  static final ThirdPartyAuthService instance = ThirdPartyAuthService();

  /// 授权记录存储键。
  static const String grantsKey = 'third_party_grants_v1';

  /// 访问日志存储键。
  static const String accessLogKey = 'third_party_access_log_v1';

  /// 访问日志上限（FIFO 淘汰）。
  static const int maxAccessLogs = 50;

  /// 深链 scheme。
  static const String scheme = 'suchmusic';

  /// 深链 host。
  static const String authHost = 'oauth';

  /// 深链 path。
  static const String authPath = '/authorize';

  /// state 允许的最大长度（ARCH §6.1）。
  static const int maxStateLength = 128;

  final ClientRegistry _registry;
  final ThirdPartyBridge _bridge;
  final AuthCodeService _codes;
  final LoopbackPort _server;
  final ThirdPartyDataProvider _dataProvider;
  final Future<SharedPreferences> Function() _prefs;
  final int Function() _now;

  /// 静默续期最小间隔（ARCH §6.6 条件 4）。
  final Duration silentDebounce;

  /// 每 client 每分钟最大签发次数（ARCH T7）。
  final int rateLimitPerMinute;

  /// 每 client 的签发时间戳（秒），用于限流（T7）。
  final Map<String, List<int>> _issueHistory = <String, List<int>>{};

  /// 每 client 最近一次静默续期时间（秒），用于 5s 防抖（ARCH §6.6）。
  final Map<String, int> _lastSilentAt = <String, int>{};

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<SharedPreferences> _store() => _prefs();

  // ── 深链入口 ─────────────────────────────────────────────────

  /// 处理一次 `suchmusic://oauth/authorize` 请求。
  ///
  /// [confirm] 为 null 且需要用户确认时返回 [AuthNeedsUi]（M4 接页面后传入真实实现，
  /// 单测传假实现）。返回 [AuthCompleted] 时 code 已投递给目标包，数据只能由
  /// 目标包凭 code 从 loopback 换取。
  Future<AuthOutcome> handleAuthorizeRequest(
    Uri uri, {
    Future<bool> Function(AuthRequest request)? confirm,
  }) async {
    // ① URI 形状：scheme + host + path
    if (uri.scheme != scheme || uri.host != authHost || uri.path != authPath) {
      return const AuthFailed(
        AuthErrors.invalidRequest,
        '深链格式应为 suchmusic://oauth/authorize',
      );
    }

    final params = uri.queryParameters;
    final clientId = (params['client_id'] ?? '').trim();
    final packageName = (params['package'] ?? '').trim();
    final rawScopes = (params['scopes'] ?? '').trim();
    final state = params['state'] ?? '';
    final silent = params['silent'] == '1';
    if (clientId.isEmpty || packageName.isEmpty || rawScopes.isEmpty) {
      return const AuthFailed(
        AuthErrors.invalidRequest,
        '缺少必填参数（client_id / package / scopes）',
      );
    }

    // ② 注册表：client_id 必须存在，且包名一致
    final client = _registry.findById(clientId);
    if (client == null || client.packageName != packageName) {
      // 冒名者拿不到 code，因此这里不写任何记录（T1）
      return const AuthFailed(
        AuthErrors.clientMismatch,
        '调用方身份校验失败：未登记或包名不匹配',
      );
    }

    // ③ 本机安装状态 + 签名指纹（T1）
    final info = await _bridge.getInstalledAppInfo(packageName);
    if (!info.installed) {
      return const AuthFailed(
        AuthErrors.clientMismatch,
        '调用方应用未安装，无法投递授权结果',
      );
    }
    if (!_signatureMatches(client, info)) {
      return const AuthFailed(
        AuthErrors.clientMismatch,
        '调用方签名与应用登记信息不一致',
      );
    }

    // ④ scopes：必须全部合法且非空（自动去重）
    final scopes = _parseScopes(rawScopes);
    if (scopes == null) {
      return _fail(
        client.clientId,
        const <ThirdPartyScope>[],
        AuthErrors.invalidScope,
        '申请的能力列表不合法',
      );
    }

    // ⑤ state：长度 1–128
    if (state.isEmpty || state.length > maxStateLength) {
      return _fail(
        client.clientId,
        scopes,
        AuthErrors.invalidState,
        'state 长度必须在 1–$maxStateLength 之间',
      );
    }

    // ⑥ 限流：每 client 每分钟最多 10 次签发（T7）
    if (!_canIssue(client.clientId)) {
      return _fail(
        client.clientId,
        scopes,
        AuthErrors.rateLimited,
        '请求过于频繁，请稍后再试',
      );
    }

    // ⑦ 静默判定（每次都要回查存储，不缓存授权结论 —— ADR-004）
    final grant = await grantOf(client.clientId);
    final alreadyGranted = grant?.scopes ?? const <ThirdPartyScope>{};
    final sortedScopes = scopes.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final request = AuthRequest(
      client: client,
      scopes: sortedScopes,
      state: state,
      silent: silent,
      alreadyGranted: alreadyGranted,
      // 确认页展示 PackageManager 的真实应用名与签名指纹前 8 位（T10）
      appLabel: info.label.isEmpty ? client.displayName : info.label,
      signaturePrefix: info.signatureSha256.length >= 8
          ? info.signatureSha256.substring(0, 8)
          : info.signatureSha256,
    );

    final canSilent = silent &&
        grant != null &&
        grant.covers(scopes) &&
        !scopes.contains(ThirdPartyScope.accountToken) &&
        _silentDebounceOk(client.clientId);

    // ⑧ 需要 UI 且没有确认回调 → 交给 M4 的页面
    if (!canSilent) {
      if (confirm == null) {
        return AuthNeedsUi(request);
      }
      bool allowed;
      try {
        allowed = await confirm(request);
      } catch (e) {
        // 确认页异常按「拒绝」处理，绝不放行（fail-closed）
        debugPrint('[ThirdParty] 确认回调异常: ${e.runtimeType}');
        allowed = false;
      }
      // ⑨ 用户拒绝：写 denied 日志，不落库
      if (!allowed) {
        await _appendLog(client.clientId, sortedScopes, 'denied');
        return const AuthFailed(AuthErrors.accessDenied, '用户拒绝了本次授权');
      }
    }

    return _grantAndDeliver(
      client: client,
      scopes: scopes,
      state: state,
      previousGrant: grant,
      silent: canSilent,
    );
  }

  // ── 授权落库 + code 投递 ─────────────────────────────────────

  Future<AuthOutcome> _grantAndDeliver({
    required ThirdPartyClient client,
    required Set<ThirdPartyScope> scopes,
    required String state,
    required ThirdPartyGrant? previousGrant,
    required bool silent,
  }) async {
    final sortedScopes = scopes.toList()..sort((a, b) => a.index.compareTo(b.index));

    // ⑩ 写 / 合并 grant（scope 取并集）
    await _upsertGrant(client, scopes);

    // `account.token` 只有在用户前台确认后才允许交换（ADR-003）
    final foregroundConfirmed = scopes.contains(ThirdPartyScope.accountToken);

    String code = '';
    try {
      code = _codes.issue(
        clientId: client.clientId,
        packageName: client.packageName,
        scopes: scopes,
        // 端口此刻尚未绑定，start() 之后回填
        port: 0,
        foregroundConfirmed: foregroundConfirmed,
      );

      final port = await _server.start(
        clientId: client.clientId,
        code: code,
        scopes: scopes,
        provider: _dataProvider,
        foregroundConfirmed: foregroundConfirmed,
        packageName: client.packageName,
      );
      _codes.attachPort(code, port);

      final result = await _bridge.sendClientCallback(
        client.packageName,
        <String, Object?>{
          'code': code,
          'port': port,
          'state': state,
          'client_id': client.clientId,
          'scopes': ThirdPartyScope.codesOf(sortedScopes),
        },
      );

      // ⑪ 目标包没有回调页：回滚授权记录，避免「用户同意了却无处接收」
      if (!result.sent) {
        await _rollback(client.clientId, previousGrant, code);
        await _appendLog(
          client.clientId,
          sortedScopes,
          'error:${AuthErrors.noCallbackActivity}',
        );
        return const AuthFailed(
          AuthErrors.noCallbackActivity,
          '该应用没有可接收授权结果的页面，请升级后再试',
        );
      }
    } catch (e) {
      // 任何异常都回滚，保证不留半成品授权
      debugPrint('[ThirdParty] 授权投递异常: ${e.runtimeType}');
      await _rollback(client.clientId, previousGrant, code);
      await _appendLog(
        client.clientId,
        sortedScopes,
        'error:${AuthErrors.badRequest}',
      );
      return const AuthFailed(AuthErrors.badRequest, '授权流程异常，请重试');
    }

    _recordIssue(client.clientId);
    if (silent) _lastSilentAt[client.clientId] = _now();
    await _appendLog(client.clientId, sortedScopes, 'granted');
    return AuthCompleted(client.clientId, silent: silent);
  }

  /// 回滚：恢复原 grant（无原授权则删除）+ 作废 code + 关服。
  Future<void> _rollback(
    String clientId,
    ThirdPartyGrant? previous,
    String code,
  ) async {
    if (code.isNotEmpty) _codes.dropClient(clientId);
    try {
      await _server.stop(clientId);
    } catch (_) {
      // 关服失败不影响回滚结论
    }
    if (previous == null) {
      final grants = await listGrants()
        ..removeWhere((grant) => grant.clientId == clientId);
      await _writeGrants(grants);
    } else {
      final grants = await listGrants();
      final index = grants.indexWhere((grant) => grant.clientId == clientId);
      if (index >= 0) {
        grants[index] = previous;
        await _writeGrants(grants);
      }
    }
  }

  // ── 授权记录读写 ─────────────────────────────────────────────

  /// 查某 client 的授权记录（每次都从存储读，不缓存）。
  Future<ThirdPartyGrant?> grantOf(String clientId) async {
    final grants = await listGrants();
    for (final grant in grants) {
      if (grant.clientId == clientId) return grant;
    }
    return null;
  }

  /// 全部授权记录（管理页用）。
  Future<List<ThirdPartyGrant>> listGrants() async {
    try {
      final prefs = await _store();
      final raw = prefs.getString(grantsKey);
      if (raw == null || raw.isEmpty) return <ThirdPartyGrant>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <ThirdPartyGrant>[];
      return <ThirdPartyGrant>[
        for (final item in decoded)
          if (item is Map) ThirdPartyGrant.fromJson(_stringMap(item)),
      ];
    } catch (e) {
      debugPrint('[ThirdParty] 读取授权记录失败: ${e.runtimeType}');
      return <ThirdPartyGrant>[];
    }
  }

  /// 撤销单个 client 的授权（立即生效，ARCH §6.7 / T6）。
  Future<void> revoke(String clientId) async {
    final grants = await listGrants();
    final target = grants.where((grant) => grant.clientId == clientId).toList();
    if (target.isEmpty) return;
    grants.removeWhere((grant) => grant.clientId == clientId);
    await _writeGrants(grants);
    // 清该 client 未使用 code + 关进行中的 loopback server
    _codes.dropClient(clientId);
    try {
      await _server.stop(clientId);
    } catch (_) {
      // 忽略关服异常
    }
    _issueHistory.remove(clientId);
    _lastSilentAt.remove(clientId);
    for (final grant in target) {
      await _appendLog(grant.clientId, grant.scopes.toList(), 'revoked');
    }
  }

  /// 撤销全部授权。
  Future<void> revokeAll() async {
    final grants = await listGrants();
    if (grants.isEmpty) return;
    await _writeGrants(<ThirdPartyGrant>[]);
    for (final grant in grants) {
      _codes.dropClient(grant.clientId);
      _issueHistory.remove(grant.clientId);
      _lastSilentAt.remove(grant.clientId);
      try {
        await _server.stop(grant.clientId);
      } catch (_) {
        // 忽略关服异常
      }
      await _appendLog(grant.clientId, grant.scopes.toList(), 'revoked');
    }
  }

  /// 最近访问日志（新的在前）。
  Future<List<ThirdPartyAccessLog>> recentLogs() async {
    try {
      final prefs = await _store();
      final raw = prefs.getString(accessLogKey);
      if (raw == null || raw.isEmpty) return <ThirdPartyAccessLog>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <ThirdPartyAccessLog>[];
      final logs = <ThirdPartyAccessLog>[
        for (final item in decoded)
          if (item is Map) ThirdPartyAccessLog.fromJson(_stringMap(item)),
      ];
      return logs.reversed.toList();
    } catch (e) {
      debugPrint('[ThirdParty] 读取访问日志失败: ${e.runtimeType}');
      return <ThirdPartyAccessLog>[];
    }
  }

  /// 测试与调试注入：清空内存态与持久化记录。
  @visibleForTesting
  Future<void> resetForTest() async {
    _issueHistory.clear();
    _lastSilentAt.clear();
    try {
      final prefs = await _store();
      await prefs.remove(grantsKey);
      await prefs.remove(accessLogKey);
    } catch (_) {
      // 无 SP 环境（如纯 Dart 测试）时忽略
    }
  }

  Future<ThirdPartyGrant> _upsertGrant(
    ThirdPartyClient client,
    Set<ThirdPartyScope> scopes,
  ) async {
    final grants = await listGrants();
    final index = grants.indexWhere((grant) => grant.clientId == client.clientId);
    final now = _now();
    final ThirdPartyGrant merged;
    if (index >= 0) {
      final old = grants[index];
      merged = old.copyWith(
        packageName: client.packageName,
        scopes: <ThirdPartyScope>{...old.scopes, ...scopes},
        lastAccessAt: now,
        callCount: old.callCount + 1,
      );
      grants[index] = merged;
    } else {
      merged = ThirdPartyGrant(
        clientId: client.clientId,
        packageName: client.packageName,
        scopes: <ThirdPartyScope>{...scopes},
        grantedAt: now,
        lastAccessAt: now,
        callCount: 1,
      );
      grants.add(merged);
    }
    await _writeGrants(grants);
    return merged;
  }

  Future<void> _writeGrants(List<ThirdPartyGrant> grants) async {
    final prefs = await _store();
    await prefs.setString(
      grantsKey,
      jsonEncode(<Map<String, dynamic>>[
        for (final grant in grants) grant.toJson(),
      ]),
    );
  }

  /// 追加一条访问日志（只记 clientId / scopes / result / ts，T8）。
  Future<void> _appendLog(
    String clientId,
    List<ThirdPartyScope> scopes,
    String result,
  ) async {
    try {
      final prefs = await _store();
      final raw = prefs.getString(accessLogKey);
      final logs = <Map<String, dynamic>>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) logs.add(_stringMap(item));
          }
        }
      }
      logs.add(<String, dynamic>{
        'client_id': clientId,
        'scopes': ThirdPartyScope.codesOf(scopes),
        'result': result,
        'ts': _now(),
      });
      while (logs.length > maxAccessLogs) {
        logs.removeAt(0);
      }
      await prefs.setString(accessLogKey, jsonEncode(logs));
    } catch (e) {
      debugPrint('[ThirdParty] 写访问日志失败: ${e.runtimeType}');
    }
  }

  // ── 校验辅助 ─────────────────────────────────────────────────

  /// 解析逗号分隔的 scopes；含未知项或去重后为空返回 null。
  Set<ThirdPartyScope>? _parseScopes(String raw) {
    final out = <ThirdPartyScope>{};
    for (final piece in raw.split(',')) {
      final text = piece.trim();
      if (text.isEmpty) continue;
      final scope = ThirdPartyScope.fromCode(text);
      if (scope == null) return null;
      out.add(scope);
    }
    return out.isEmpty ? null : out;
  }

  /// 签名比对。
  ///
  /// 注册表签名留空 = debug 探针：仅在 `kDebugMode` 下放行（ARCH §8.3）。
  bool _signatureMatches(ThirdPartyClient client, InstalledAppInfo info) {
    final expected = client.signatureSha256.trim().toLowerCase();
    if (expected.isEmpty) return kDebugMode;
    final actual = info.signatureSha256.trim().toLowerCase();
    return actual.isNotEmpty && actual == expected;
  }

  bool _canIssue(String clientId) {
    final now = _now();
    final history = _issueHistory.putIfAbsent(clientId, () => <int>[]);
    history.removeWhere((stamp) => now - stamp >= 60);
    return history.length < rateLimitPerMinute;
  }

  void _recordIssue(String clientId) {
    _issueHistory.putIfAbsent(clientId, () => <int>[]).add(_now());
  }

  bool _silentDebounceOk(String clientId) {
    final last = _lastSilentAt[clientId];
    if (last == null) return true;
    return _now() - last >= silentDebounce.inSeconds;
  }

  AuthFailed _fail(
    String clientId,
    Iterable<ThirdPartyScope> scopes,
    String error,
    String message,
  ) {
    // 异步写日志：调用方 await 的是返回结果，日志失败不影响结论
    unawaited(_appendLog(clientId, scopes.toList(), 'error:$error'));
    return AuthFailed(error, message);
  }

  Map<String, dynamic> _stringMap(Map<dynamic, dynamic> raw) {
    final out = <String, dynamic>{};
    raw.forEach((key, value) {
      out[key.toString()] = value;
    });
    return out;
  }
}

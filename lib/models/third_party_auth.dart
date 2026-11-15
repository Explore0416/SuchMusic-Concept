import 'package:flutter/material.dart';

/// 第三方授权 scope 定义（ARCHITECTURE §6.2 / §7）。
///
/// 每个 scope 对应一项可被第三方 App 申请的能力：
/// - [code] 为协议层标识，随深链 / JSON 传输，**不可改名**（改名即破坏协议）；
/// - [label] / [description] 供授权确认页展示（M4 使用）；
/// - [silentAllowed] 表示能否走「静默续期」（ARCH §6.6）；
/// - [icon] 仅为 UI 建议图标，服务层不依赖它做任何判断。
enum ThirdPartyScope {
  genreRead(
    code: 'genre.read',
    label: '曲风画像',
    description: '读取根据你的播放历史推断出的曲风偏好，不含歌曲与歌手名称',
    silentAllowed: true,
    icon: Icons.pie_chart_rounded,
  ),
  accountToken(
    code: 'account.token',
    label: '酷狗账号令牌',
    description: '读取当前登录的酷狗账号令牌，每次都需要你确认',
    silentAllowed: false,
    icon: Icons.vpn_key_rounded,
  ),
  urlResolve(
    code: 'url.resolve',
    label: '歌曲直链',
    description: '为指定歌曲解析播放直链',
    silentAllowed: true,
    icon: Icons.link_rounded,
  ),
  playbackControl(
    code: 'playback.control',
    label: '代播控制',
    description: '让 SuchMusic 播放、暂停或切换歌曲',
    silentAllowed: true,
    icon: Icons.play_circle_rounded,
  );

  const ThirdPartyScope({
    required this.code,
    required this.label,
    required this.description,
    required this.silentAllowed,
    required this.icon,
  });

  /// 协议标识（`genre.read` 等）。
  final String code;

  /// UI 标题。
  final String label;

  /// UI 一句说明。
  final String description;

  /// 是否允许静默续期。
  final bool silentAllowed;

  /// UI 建议图标。
  final IconData icon;

  /// 可静默续期的 scope 集合（ARCH §3「静默 scope」）。
  static const Set<ThirdPartyScope> silentScopes = <ThirdPartyScope>{
    ThirdPartyScope.genreRead,
    ThirdPartyScope.urlResolve,
    ThirdPartyScope.playbackControl,
  };

  /// 敏感 scope（必须每次前台确认）。
  static const Set<ThirdPartyScope> sensitiveScopes = <ThirdPartyScope>{
    ThirdPartyScope.accountToken,
  };

  /// 由协议标识反查；未知标识返回 null。
  static ThirdPartyScope? fromCode(String? code) {
    if (code == null) return null;
    final normalized = code.trim();
    if (normalized.isEmpty) return null;
    for (final scope in ThirdPartyScope.values) {
      if (scope.code == normalized) return scope;
    }
    return null;
  }

  /// 批量转协议标识（保持传入顺序）。
  static List<String> codesOf(Iterable<ThirdPartyScope> scopes) =>
      <String>[for (final scope in scopes) scope.code];

  /// 由协议标识列表还原（未知标识被丢弃，用于容错读旧数据）。
  static Set<ThirdPartyScope> fromCodes(Iterable<Object?> codes) {
    final out = <ThirdPartyScope>{};
    for (final raw in codes) {
      final scope = ThirdPartyScope.fromCode(raw?.toString());
      if (scope != null) out.add(scope);
    }
    return out;
  }
}

/// 客户端形态（ARCHITECTURE §7「客户端类型」）。
///
/// - [android]：用「包名 + 签名指纹」识别，授权结果经 explicit intent 投递；
/// - [web]：没有安装包，用「已登记的回调地址」识别，授权后跳回浏览器，
///   由网页在**本机** loopback 端口上换取数据（数据不出设备）。
enum ThirdPartyAppType {
  android('android'),
  web('web');

  const ThirdPartyAppType(this.code);

  /// 清单里的协议标识。
  final String code;

  static ThirdPartyAppType fromCode(Object? raw) {
    final text = (raw ?? '').toString().trim();
    return text == 'web' ? ThirdPartyAppType.web : ThirdPartyAppType.android;
  }
}

/// 已登记的第三方 Client（ARCHITECTURE §7）。
///
/// 信任根分两种：
/// - Android：注册表里的包名 + 签名 SHA-256 与本机实际安装包同时匹配；
/// - Web：注册表里的回调地址与请求中的 `redirect_uri` **逐字相等**。
class ThirdPartyClient {
  const ThirdPartyClient({
    required this.clientId,
    required this.packageName,
    required this.signatureSha256,
    required this.displayName,
    this.appType = ThirdPartyAppType.android,
    this.redirectUris = const <String>[],
  });

  /// 注册表主键，随深链 `client_id` 传入。
  final String clientId;

  /// 目标包名（仅 Android 应用有值）。
  final String packageName;

  /// 签名证书 SHA-256（小写 hex）；空串 = 不比对签名（仅 debug 探针）。
  final String signatureSha256;

  /// 注册表内的展示名（UI 以 PackageManager 结果优先）。
  final String displayName;

  /// 客户端形态。
  final ThirdPartyAppType appType;

  /// 已登记的回调地址（仅 Web 应用有值，逐字比对，不做前缀匹配）。
  final List<String> redirectUris;

  /// 是否为网页应用。
  bool get isWeb => appType == ThirdPartyAppType.web;

  /// 是否需要比对签名（Web 应用永远不需要）。
  bool get requiresSignature => !isWeb && signatureSha256.trim().isNotEmpty;

  /// 回调地址是否已登记（Web 授权的前置校验）。
  bool allowsRedirect(String uri) => redirectUris.contains(uri);

  /// 已登记回调地址的 origin 集合（loopback CORS 白名单）。
  Set<String> get redirectOrigins {
    final out = <String>{};
    for (final raw in redirectUris) {
      final uri = Uri.tryParse(raw);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) continue;
      out.add('${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}');
    }
    return out;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'client_id': clientId,
        'app_type': appType.code,
        'package': packageName,
        'signature_sha256': signatureSha256,
        'redirect_uris': redirectUris,
        'display_name': displayName,
      };

  factory ThirdPartyClient.fromJson(Map<String, dynamic> json) {
    final rawRedirects = json['redirect_uris'];
    return ThirdPartyClient(
      clientId: (json['client_id'] ?? '').toString(),
      packageName: (json['package'] ?? '').toString(),
      signatureSha256: (json['signature_sha256'] ?? '').toString(),
      displayName: (json['display_name'] ?? '').toString(),
      appType: ThirdPartyAppType.fromCode(json['app_type']),
      redirectUris: rawRedirects is Iterable
          ? <String>[
              for (final item in rawRedirects)
                if (item is String && item.isNotEmpty) item,
            ]
          : const <String>[],
    );
  }

  @override
  String toString() =>
      'ThirdPartyClient($clientId → ${isWeb ? redirectUris.join(",") : packageName})';
}

/// 一条长期授权记录（ARCHITECTURE §7）。
///
/// `grantedAt` 为首次授权时间，合并新 scope 时**保持不变**；
/// `lastAccessAt` / `callCount` 每次成功签发都会更新（供管理页展示）。
class ThirdPartyGrant {
  const ThirdPartyGrant({
    required this.clientId,
    required this.packageName,
    required this.scopes,
    required this.grantedAt,
    required this.lastAccessAt,
    required this.callCount,
  });

  final String clientId;
  final String packageName;
  final Set<ThirdPartyScope> scopes;

  /// 首次授权时间（epoch seconds）。
  final int grantedAt;

  /// 最近一次成功授权/续期时间（epoch seconds）。
  final int lastAccessAt;

  /// 累计成功签发次数。
  final int callCount;

  /// 是否已覆盖 [requested] 中的全部 scope。
  bool covers(Iterable<ThirdPartyScope> requested) =>
      scopes.containsAll(requested);

  ThirdPartyGrant copyWith({
    String? clientId,
    String? packageName,
    Set<ThirdPartyScope>? scopes,
    int? grantedAt,
    int? lastAccessAt,
    int? callCount,
  }) =>
      ThirdPartyGrant(
        clientId: clientId ?? this.clientId,
        packageName: packageName ?? this.packageName,
        scopes: scopes ?? this.scopes,
        grantedAt: grantedAt ?? this.grantedAt,
        lastAccessAt: lastAccessAt ?? this.lastAccessAt,
        callCount: callCount ?? this.callCount,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'client_id': clientId,
        'package': packageName,
        'scopes': ThirdPartyScope.codesOf(scopes),
        'granted_at': grantedAt,
        'last_access_at': lastAccessAt,
        'call_count': callCount,
      };

  factory ThirdPartyGrant.fromJson(Map<String, dynamic> json) {
    final rawScopes = json['scopes'];
    return ThirdPartyGrant(
      clientId: (json['client_id'] ?? '').toString(),
      packageName: (json['package'] ?? '').toString(),
      scopes: rawScopes is Iterable
          ? ThirdPartyScope.fromCodes(rawScopes)
          : <ThirdPartyScope>{},
      grantedAt: _asInt(json['granted_at']),
      lastAccessAt: _asInt(json['last_access_at']),
      callCount: _asInt(json['call_count']),
    );
  }

  @override
  String toString() =>
      'ThirdPartyGrant($clientId, scopes=${ThirdPartyScope.codesOf(scopes)})';
}

/// 一条访问日志（ARCHITECTURE §7 / T8）。
///
/// **只记 clientId / scopes / result / ts，绝不记录任何返回值**，
/// 从结构上保证令牌不会经日志外泄。
class ThirdPartyAccessLog {
  const ThirdPartyAccessLog({
    required this.clientId,
    required this.scopes,
    required this.result,
    required this.ts,
  });

  final String clientId;
  final List<ThirdPartyScope> scopes;

  /// `granted` / `denied` / `exchanged` / `revoked` / `error:<code>`。
  final String result;

  /// epoch seconds。
  final int ts;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'client_id': clientId,
        'scopes': ThirdPartyScope.codesOf(scopes),
        'result': result,
        'ts': ts,
      };

  factory ThirdPartyAccessLog.fromJson(Map<String, dynamic> json) {
    final rawScopes = json['scopes'];
    return ThirdPartyAccessLog(
      clientId: (json['client_id'] ?? '').toString(),
      scopes: rawScopes is Iterable
          ? ThirdPartyScope.fromCodes(rawScopes).toList()
          : <ThirdPartyScope>[],
      result: (json['result'] ?? '').toString(),
      ts: _asInt(json['ts']),
    );
  }

  @override
  String toString() => 'ThirdPartyAccessLog($clientId, $result, $ts)';
}

/// 一次待确认的授权请求（交给 M4 的确认页渲染）。
///
/// [alreadyGranted] 用于把「已授权的 N 项」折叠展示（ARCH §6.6），
/// [scopes] 为本次**申请**的 scope 全集（含已授权部分）。
class AuthRequest {
  const AuthRequest({
    required this.client,
    required this.scopes,
    required this.state,
    required this.silent,
    this.alreadyGranted = const <ThirdPartyScope>{},
    this.appLabel = '',
    this.signaturePrefix = '',
    this.redirectUri,
  });

  /// 已通过注册表 + 安装校验的 Client。
  final ThirdPartyClient client;

  /// 本次申请的 scope（已去重、按枚举顺序排序）。
  final List<ThirdPartyScope> scopes;

  /// 原样回传给第三方的防混淆串。
  final String state;

  /// 深链是否带 `silent=1`。
  final bool silent;

  /// 该 Client 目前已经授权的 scope。
  final Set<ThirdPartyScope> alreadyGranted;

  /// `PackageManager` 取到的真实应用名（空则回退 [ThirdPartyClient.displayName]，T10）。
  final String appLabel;

  /// 签名 SHA-256 前 8 位（确认页展示给用户辨认，T10）。
  final String signaturePrefix;

  /// Web 客户端本次请求的回调地址；Android 客户端为 null。
  ///
  /// 已在服务层校验过「必须逐字命中登记值」，UI 只负责展示，不得再放行判断。
  final String? redirectUri;

  /// 是否为网页应用（确认页据此切换「包名/签名」为「回调域名」）。
  bool get isWeb => client.isWeb;

  /// 调用方包名。
  String get packageName => client.packageName;

  /// 确认页标题用的应用名（真实应用名优先）。
  String get displayName => appLabel.isEmpty ? client.displayName : appLabel;

  /// 本次**新增**的 scope（确认页需要重点展示的部分）。
  List<ThirdPartyScope> get newScopes =>
      <ThirdPartyScope>[for (final s in scopes) if (!alreadyGranted.contains(s)) s];

  /// 是否包含敏感 scope（确认页需高亮警示）。
  bool get hasSensitiveScope =>
      scopes.any(ThirdPartyScope.sensitiveScopes.contains);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'client': client.toJson(),
        'scopes': ThirdPartyScope.codesOf(scopes),
        'state': state,
        'silent': silent,
        'already_granted': ThirdPartyScope.codesOf(alreadyGranted),
        'app_label': appLabel,
        'signature_prefix': signaturePrefix,
        'redirect_uri': redirectUri,
      };

  factory AuthRequest.fromJson(Map<String, dynamic> json) {
    final rawClient = json['client'];
    final client = rawClient is Map
        ? ThirdPartyClient.fromJson(<String, dynamic>{
            for (final entry in rawClient.entries)
              entry.key.toString(): entry.value,
          })
        : const ThirdPartyClient(
            clientId: '',
            packageName: '',
            signatureSha256: '',
            displayName: '',
          );
    final rawScopes = json['scopes'];
    final rawGranted = json['already_granted'];
    return AuthRequest(
      client: client,
      scopes: rawScopes is Iterable
          ? ThirdPartyScope.fromCodes(rawScopes).toList()
          : <ThirdPartyScope>[],
      state: (json['state'] ?? '').toString(),
      silent: json['silent'] == true,
      alreadyGranted:
          rawGranted is Iterable ? ThirdPartyScope.fromCodes(rawGranted) : <ThirdPartyScope>{},
      appLabel: (json['app_label'] ?? '').toString(),
      signaturePrefix: (json['signature_prefix'] ?? '').toString(),
      redirectUri: (json['redirect_uri'] ?? '').toString().isEmpty
          ? null
          : (json['redirect_uri'] ?? '').toString(),
    );
  }
}

/// 深链处理结果（ARCHITECTURE §8.1）。
///
/// 只有 [ThirdPartyAuthService] 能产出它，UI / 网络层不得自行构造「已授权」结论。
sealed class AuthOutcome {
  const AuthOutcome();
}

/// 需要用户确认（M4 的确认页据此弹出）。
final class AuthNeedsUi extends AuthOutcome {
  const AuthNeedsUi(this.request);

  final AuthRequest request;

  @override
  String toString() => 'AuthNeedsUi(${request.client.clientId})';
}

/// 授权通过且 code / 端口已投递（或静默续期完成）。
final class AuthCompleted extends AuthOutcome {
  const AuthCompleted(this.clientId, {this.silent = false});

  final String clientId;

  /// true 表示走的是无 UI 静默续期（M6 据此发通知）。
  final bool silent;

  @override
  String toString() => 'AuthCompleted($clientId, silent=$silent)';
}

/// 授权失败（error 为协议错误码，message 为中文说明）。
final class AuthFailed extends AuthOutcome {
  const AuthFailed(this.error, this.message);

  final String error;
  final String message;

  @override
  String toString() => 'AuthFailed($error: $message)';
}

/// 协议错误码常量（ARCHITECTURE §6.1 / §6.5）。
///
/// 统一放在一处，避免服务层与 UI 各写一份字符串导致对不上。
abstract final class AuthErrors {
  /// 深链缺参数 / 形状不对。
  static const String invalidRequest = 'invalid_request';

  /// clientId 未登记、包名不符、未安装、签名不符（**不写任何记录**）。
  static const String clientMismatch = 'client_mismatch';

  /// scope 缺失 / 含未知项。
  static const String invalidScope = 'invalid_scope';

  /// state 长度不在 1–128。
  static const String invalidState = 'invalid_state';

  /// 用户拒绝。
  static const String accessDenied = 'access_denied';

  /// 目标包没有可接收回调的 Activity。
  static const String noCallbackActivity = 'no_callback_activity';

  /// Web 客户端的 redirect_uri 缺失或未登记。
  static const String invalidRedirectUri = 'invalid_redirect_uri';

  /// Web 客户端缺少 PKCE 参数。
  static const String pkceRequired = 'pkce_required';

  /// 无法唤起浏览器（没有可用浏览器 / 系统拒绝）。
  static const String browserUnavailable = 'browser_unavailable';

  /// 超过每 client 每分钟 10 次签发。
  static const String rateLimited = 'rate_limited';

  /// code 无效（不存在 / 已被使用 / clientId 不匹配）。
  static const String invalidCode = 'invalid_code';

  /// code 已过期。
  static const String codeExpired = 'code_expired';

  /// 请求了未授权的 scope。
  static const String scopeNotGranted = 'scope_not_granted';

  /// 酷狗未登录。
  static const String notLoggedIn = 'not_logged_in';

  /// 直链解析失败。
  static const String resolveFailed = 'resolve_failed';

  /// 请求体不合法。
  static const String badRequest = 'bad_request';
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

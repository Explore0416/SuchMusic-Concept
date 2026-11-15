import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../models/third_party_auth.dart';

/// 一枚已签发的授权码（内存对象，不落盘、不写日志）。
///
/// 结构上**不包含任何用户数据**，只描述「谁、能换什么、换到哪个端口」，
/// 因此即使被 dump 也不泄露音乐/令牌信息。
class AuthCode {
  AuthCode({
    required this.value,
    required this.clientId,
    required this.packageName,
    required this.scopes,
    required this.port,
    required this.issuedAt,
    required this.expiresAt,
    required this.foregroundConfirmed,
    this.codeChallenge,
  });

  /// 32 字节随机数的 base64Url（无 padding，43 字符）。
  final String value;

  final String clientId;
  final String packageName;
  final Set<ThirdPartyScope> scopes;

  /// LoopbackServer 实际端口；签发时端口尚未绑定，由 [AuthCodeService.attachPort] 回填。
  int port;

  /// epoch seconds。
  final int issuedAt;

  /// epoch seconds。
  final int expiresAt;

  /// 是否经过前台确认（`account.token` 必须为 true，ARCH §6.5）。
  final bool foregroundConfirmed;

  /// Web 客户端的 PKCE code_challenge（S256，base64url）；Android 为 null。
  ///
  /// 存在时，loopback 交换必须带上匹配的 `code_verifier`，否则 code 不可用。
  final String? codeChallenge;

  bool isExpiredAt(int nowSeconds) => nowSeconds >= expiresAt;

  @override
  String toString() =>
      'AuthCode($clientId, scopes=${ThirdPartyScope.codesOf(scopes)}, port=$port)';
}

/// [AuthCodeService.lookup] 的结果：区分「不存在」与「已过期」以便给出不同 message。
class AuthCodeLookup {
  const AuthCodeLookup({this.code, this.expired = false});

  /// 命中的 code；null 表示不存在（或刚被消费）。
  final AuthCode? code;

  /// code 是否存在但已过期。
  final bool expired;

  bool get found => code != null;
}

/// 授权码签发 / 消费 / 清理（ARCHITECTURE §6.4 / §6.5 / T4）。
///
/// 设计要点：
/// - 全部状态在**内存**，进程退出即失效，不落盘（避免被同机其他应用读文件）；
/// - code 一次性：`consume` 取走即删；
/// - TTL 60s，另有 30s 周期清理兜底；
/// - 时钟可注入，便于单测构造「已过期」分支。
class AuthCodeService {
  AuthCodeService({
    Random? random,
    int Function()? now,
    this.ttl = const Duration(seconds: 60),
    this.purgeInterval = const Duration(seconds: 30),
    this.autoPurge = true,
  })  : _random = random ?? Random.secure(),
        _now = now ?? _defaultNow;

  /// 全局单例（授权链路使用）。
  static final AuthCodeService instance = AuthCodeService();

  /// code 随机字节数（32 字节 = 256 bit）。
  static const int codeBytes = 32;

  /// 是否启用周期清理（默认开启）。
  ///
  /// 定时器**懒启动**：只有签发过 code 才会真的创建，见 [_ensurePurgeTimer]。
  final bool autoPurge;

  /// code 有效期（ARCH §6.5：60s）。
  final Duration ttl;

  /// 过期清理周期（ARCH §6.5 兜底清理，取 30s）。
  final Duration purgeInterval;

  final Random _random;
  final int Function() _now;

  final Map<String, AuthCode> _codes = <String, AuthCode>{};
  Timer? _purgeTimer;

  /// 未消费的 code 数量（测试与诊断用）。
  int get pendingCount => _codes.length;

  static int _defaultNow() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// 签发一枚 code。
  ///
  /// [foregroundConfirmed] 为 true 表示本次签发经过前台确认
  /// （`account.token` 必须为 true，交换时还会再校验一次）。
  String issue({
    required String clientId,
    required String packageName,
    required Set<ThirdPartyScope> scopes,
    required int port,
    bool foregroundConfirmed = false,
    String? codeChallenge,
  }) {
    final now = _now();
    final value = _newCodeValue();
    _ensurePurgeTimer();
    _codes[value] = AuthCode(
      value: value,
      clientId: clientId,
      packageName: packageName,
      scopes: Set<ThirdPartyScope>.unmodifiable(scopes),
      port: port,
      issuedAt: now,
      expiresAt: now + ttl.inSeconds,
      foregroundConfirmed: foregroundConfirmed,
      codeChallenge: codeChallenge,
    );
    return value;
  }

  /// 不消费地查询（用于区分 invalid_code / code_expired，并做授权前置校验）。
  AuthCodeLookup lookup(String value) {
    final entry = _codes[value];
    if (entry == null) return const AuthCodeLookup();
    if (entry.isExpiredAt(_now())) {
      return AuthCodeLookup(code: entry, expired: true);
    }
    return AuthCodeLookup(code: entry);
  }

  /// 一次性消费：命中且未过期则返回并从内存删除；否则返回 null。
  AuthCode? consume(String value) {
    final entry = _codes.remove(value);
    if (entry == null) return null;
    if (entry.isExpiredAt(_now())) return null;
    return entry;
  }

  /// 绑定端口（签发时端口未知，绑定后回填，供诊断与日志使用）。
  void attachPort(String value, int port) {
    final entry = _codes[value];
    if (entry != null) entry.port = port;
  }

  /// 撤销 / 异常时清空某 client 的全部未使用 code（ARCH T6）。
  void dropClient(String clientId) {
    _codes.removeWhere((_, entry) => entry.clientId == clientId);
  }

  /// 清空全部（撤销全部 / 测试）。
  void clear() => _codes.clear();

  /// 主动清理过期项（周期任务调用，也可在测试里手动调用）。
  void purgeExpired() {
    final now = _now();
    _codes.removeWhere((_, entry) => entry.isExpiredAt(now));
  }

  /// 停止周期清理定时器（测试 / 进程退出）。
  void dispose() {
    _purgeTimer?.cancel();
    _purgeTimer = null;
    _codes.clear();
  }

  /// 懒启动周期清理。
  ///
  /// 构造时不启动：设置页只读一次授权数量也会构造 `ThirdPartyAuthService.instance`，
  /// 那种情形从不签发 code，常驻周期定时器毫无意义，还会让 Widget 测试留下
  /// pending timer。真正签发第一枚 code 后才需要清理过期项。
  void _ensurePurgeTimer() {
    if (!autoPurge) return;
    if (purgeInterval <= Duration.zero) return;
    _purgeTimer ??= Timer.periodic(purgeInterval, (_) => purgeExpired());
  }

  /// 生成 32 字节随机 code（base64Url，去 padding）。
  String _newCodeValue() {
    final bytes = List<int>.generate(codeBytes, (_) => _random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

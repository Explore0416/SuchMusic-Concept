/// SuchMusic 局域网中继 · 安全判定（纯逻辑，无 IO、无平台依赖）。
///
/// 覆盖 `docs/ARCH-手环通信.md` §3.12 / §4.3 的两项硬约束：
/// 1. **配对令牌**：开启中继时生成一次性、可轮换的令牌；客户端首次连接必须携带并通过
///    校验，否则立即断开。比较采用「常量时间」实现，减少时序侧信道；调用方**不得**把
///    令牌写入任何日志（本文件不打印任何内容）。
/// 2. **私网来源限制**：仅接受私网 / 回环 / 链路本地来源，其余一律拒绝——手机端中继
///    只服务局域网，**不监听公网**。
library;

import 'dart:math';

/// 令牌生成、令牌校验、私网判定的纯函数集合。
///
/// 全部为静态方法，无状态、无副作用，便于确定性单测。
class RelaySecurity {
  RelaySecurity._();

  /// 生成一次性配对令牌（默认 16 字节 → 32 位小写 hex）。
  ///
  /// [random] 可注入以便单测确定性；生产环境使用 [Random.secure]（密码学安全随机源）。
  static String generateToken({Random? random, int bytes = 16}) {
    final rnd = random ?? Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  /// 常量时间比较 [expected] 与 [presented]。
  ///
  /// 无论是否相等都会遍历到两者较长者的长度，避免通过「提前返回」泄漏前缀信息。
  static bool tokenEquals(String expected, String presented) {
    final a = expected.codeUnits;
    final b = presented.codeUnits;
    var diff = a.length ^ b.length; // 长度不同 → 必不为 0
    final n = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      diff |= x ^ y;
    }
    return diff == 0;
  }

  /// 校验客户端携带的令牌：缺失（null）/ 空串 / 服务端令牌为空 → 一律失败。
  static bool verifyToken(String expected, String? presented) {
    if (expected.isEmpty) return false;
    if (presented == null || presented.isEmpty) return false;
    return tokenEquals(expected, presented);
  }

  /// 是否为「私网 / 回环 / 链路本地」地址（同时支持 IPv4 与 IPv6）。
  ///
  /// 允许：`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`169.254.0.0/16`、
  /// `127.0.0.0/8`、`::1`、`fe80::/10`、`fc00::/7`，以及 IPv4-mapped IPv6
  /// （`::ffff:192.168.1.5`）。其余（含一切公网地址）一律视为非私网。
  static bool isPrivate(String? ip) {
    if (ip == null || ip.isEmpty) return false;
    var addr = ip;
    // 去掉 IPv6 的 zone id，例如 `fe80::1%wlan0`
    final pct = addr.indexOf('%');
    if (pct >= 0) addr = addr.substring(0, pct);
    if (addr.contains(':')) return _isPrivateV6(addr);
    return _isPrivateV4(addr);
  }

  static bool _isPrivateV4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p);
      if (v == null || v < 0 || v > 255) return false;
      octets.add(v);
    }
    final a = octets[0];
    final b = octets[1];
    if (a == 10) return true; // 10.0.0.0/8
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 192 && b == 168) return true; // 192.168.0.0/16
    if (a == 169 && b == 254) return true; // 169.254.0.0/16（链路本地）
    if (a == 127) return true; // 127.0.0.0/8（回环）
    return false;
  }

  static bool _isPrivateV6(String ip) {
    final lower = ip.toLowerCase();
    if (lower == '::1') return true; // 回环
    // IPv4-mapped：::ffff:192.168.1.5
    if (lower.startsWith('::ffff:')) {
      return _isPrivateV4(lower.substring(7));
    }
    final first = lower.split(':').first;
    final hextet = int.tryParse(first.padLeft(4, '0'), radix: 16);
    if (hextet == null) return false;
    if (hextet >= 0xfe80 && hextet <= 0xfebf) return true; // fe80::/10 链路本地
    if (hextet >= 0xfc00 && hextet <= 0xfdff) return true; // fc00::/7 唯一本地
    return false;
  }

  /// 从 query 参数 / `Authorization` 头中提取令牌（任一路径命中即可）。
  ///
  /// 支持 `?token=<t>` 与 `Authorization: Bearer <t>`（后者亦兼容无 `Bearer ` 前缀的裸值）。
  static String? extractToken({String? queryToken, String? authorization}) {
    final q = queryToken;
    if (q != null && q.isNotEmpty) return q;
    final a = authorization;
    if (a != null && a.isNotEmpty) {
      const prefix = 'Bearer ';
      if (a.length > prefix.length &&
          a.substring(0, prefix.length).toLowerCase() ==
              prefix.toLowerCase()) {
        return a.substring(prefix.length).trim();
      }
      return a.trim();
    }
    return null;
  }
}

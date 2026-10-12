import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/kugou_platform.dart';
import '../utils/app_constants.dart';

/// 单个平台的酷狗凭证。
class _KugouCred {
  String? token;
  String? userId;
  String? nickname;

  bool get isComplete => (token?.isNotEmpty ?? false) && (userId?.isNotEmpty ?? false);

  void clear() {
    token = null;
    userId = null;
    nickname = null;
  }
}

/// 酷狗凭证存取 + 脱敏（REQ-11）。
///
/// token/userid 由用户扫码 / 手填（Q2=A），存 `shared_preferences`，
/// 与网易云 `user_cache.json` 完全隔离；日志 / UI 一律 `前4****后4`。
///
/// **按平台分区**（概念版 lite / 原版 standard）：两平台 token 不通用，
/// 故各自独立存储。概念版沿用历史 key（兼容旧数据），原版使用 `_std` 后缀。
class KugouCredentialService {
  KugouCredentialService._internal();

  static final KugouCredentialService instance = KugouCredentialService._internal();

  final Map<KugouPlatform, _KugouCred> _creds = {
    for (final p in KugouPlatform.values) p: _KugouCred(),
  };

  _KugouCred _of(KugouPlatform p) => _creds[p]!;

  /// prefs key：概念版沿用历史命名，原版加 `_std` 后缀。
  String _tokenKey(KugouPlatform p) => p == KugouPlatform.lite
      ? AppConstants.kugouToken
      : '${AppConstants.kugouToken}_${p.code}';

  String _useridKey(KugouPlatform p) => p == KugouPlatform.lite
      ? AppConstants.kugouUserid
      : '${AppConstants.kugouUserid}_${p.code}';

  String _nicknameKey(KugouPlatform p) => p == KugouPlatform.lite
      ? AppConstants.kugouNickname
      : '${AppConstants.kugouNickname}_${p.code}';

  // ── 兼容 API（默认概念版）────────────────────────────────

  bool get hasCredentials => hasCredentialsFor(KugouPlatform.lite);

  String? get token => tokenOf(KugouPlatform.lite);
  String? get userId => userIdOf(KugouPlatform.lite);
  String? get nickname => nicknameOf(KugouPlatform.lite);

  /// 脱敏 token（前4****后4，默认概念版）
  String? get maskedToken => maskedTokenOf(KugouPlatform.lite);

  // ── 平台维度 API ─────────────────────────────────────────

  bool hasCredentialsFor(KugouPlatform p) => _of(p).isComplete;

  String? tokenOf(KugouPlatform p) => _of(p).token;
  String? userIdOf(KugouPlatform p) => _of(p).userId;
  String? nicknameOf(KugouPlatform p) => _of(p).nickname;

  String? maskedTokenOf(KugouPlatform p) {
    final t = _of(p).token;
    return (t == null || t.isEmpty) ? null : AppConstants.maskToken(t);
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final p in KugouPlatform.values) {
        final c = _of(p);
        c.token = prefs.getString(_tokenKey(p));
        c.userId = prefs.getString(_useridKey(p));
        c.nickname = prefs.getString(_nicknameKey(p));
      }
      debugPrint(
          '🔑 已读取酷狗凭证: 概念版=${AppConstants.maskToken(tokenOf(KugouPlatform.lite))} '
          '原版=${AppConstants.maskToken(tokenOf(KugouPlatform.standard))}');
    } catch (e) {
      debugPrint('⚠️ 读取酷狗凭证失败: $e');
    }
  }

  /// 保存（自动清洗空格 / `token=` 前缀），默认概念版。
  Future<bool> save(String token, String userId) =>
      saveFor(KugouPlatform.lite, token, userId);

  /// 按平台保存凭证。
  Future<bool> saveFor(
      KugouPlatform platform, String token, String userId) async {
    final t = _clean(token, prefix: 'token');
    final u = _clean(userId, prefix: 'userid');
    if (t.isEmpty || u.isEmpty) return false;
    final c = _of(platform);
    c.token = t;
    c.userId = u;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_tokenKey(platform), t);
      await prefs.setString(_useridKey(platform), u);
      debugPrint(
          '💾 已保存酷狗凭证(${platform.label}): token=${AppConstants.maskToken(t)}');
      return true;
    } catch (e) {
      debugPrint('⚠️ 保存酷狗凭证失败: $e');
      return false;
    }
  }

  /// 保存来自扫码登录的凭证（语义同 [saveFor]，仅用于日志区分来源）。
  Future<bool> saveFromLogin(String token, String userId,
      {KugouPlatform platform = KugouPlatform.lite}) async {
    final ok = await saveFor(platform, token, userId);
    if (ok) {
      debugPrint(
          '🔑 酷狗扫码登录凭证已写入(${platform.label}): uid=${AppConstants.maskToken(userId)}');
    }
    return ok;
  }

  Future<void> setNickname(String? nickname,
      {KugouPlatform platform = KugouPlatform.lite}) async {
    final v = (nickname == null || nickname.isEmpty) ? null : nickname;
    _of(platform).nickname = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (v == null) {
        await prefs.remove(_nicknameKey(platform));
      } else {
        await prefs.setString(_nicknameKey(platform), v);
      }
    } catch (_) {}
  }

  /// 清除凭证（默认概念版）。
  Future<void> clear() => clearFor(KugouPlatform.lite);

  /// 按平台清除凭证。
  Future<void> clearFor(KugouPlatform platform) async {
    _of(platform).clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tokenKey(platform));
      await prefs.remove(_useridKey(platform));
      await prefs.remove(_nicknameKey(platform));
      debugPrint('🧹 已清除酷狗凭证(${platform.label})');
    } catch (_) {}
  }

  /// 清除全部平台凭证。
  Future<void> clearAll() async {
    for (final p in KugouPlatform.values) {
      await clearFor(p);
    }
  }

  /// 清洗：去首尾空格、去 `xxx=` 前缀、去中间空白
  String _clean(String raw, {required String prefix}) {
    var v = raw.trim();
    if (v.toLowerCase().startsWith('$prefix=')) {
      v = v.substring(prefix.length + 1).trim();
    }
    return v.replaceAll(RegExp(r'\s+'), '');
  }
}

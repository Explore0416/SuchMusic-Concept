import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/app_constants.dart';

/// 酷狗凭证存取 + 脱敏（REQ-11）。
///
/// token/userid 由用户手填（Q2=A），存 `shared_preferences`，
/// 与网易云 `user_cache.json` 完全隔离；日志 / UI 一律 `前4****后4`。
class KugouCredentialService {
  KugouCredentialService._internal();

  static final KugouCredentialService instance = KugouCredentialService._internal();

  String? _token;
  String? _userId;
  String? _nickname;

  bool get hasCredentials =>
      (_token?.isNotEmpty ?? false) && (_userId?.isNotEmpty ?? false);

  String? get token => _token;
  String? get userId => _userId;
  String? get nickname => _nickname;

  /// 脱敏 token（前4****后4）
  String? get maskedToken =>
      (_token == null || _token!.isEmpty) ? null : AppConstants.maskToken(_token);

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString(AppConstants.kugouToken);
      _userId = prefs.getString(AppConstants.kugouUserid);
      _nickname = prefs.getString(AppConstants.kugouNickname);
      debugPrint('🔑 已读取酷狗凭证: token=${AppConstants.maskToken(_token)}');
    } catch (e) {
      debugPrint('⚠️ 读取酷狗凭证失败: $e');
    }
  }

  /// 保存（自动清洗空格 / `token=` 前缀）
  Future<bool> save(String token, String userId) async {
    final t = _clean(token, prefix: 'token');
    final u = _clean(userId, prefix: 'userid');
    if (t.isEmpty || u.isEmpty) return false;
    _token = t;
    _userId = u;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(AppConstants.kugouToken, t);
      await prefs.setString(AppConstants.kugouUserid, u);
      debugPrint('💾 已保存酷狗凭证: token=${AppConstants.maskToken(t)}');
      return true;
    } catch (e) {
      debugPrint('⚠️ 保存酷狗凭证失败: $e');
      return false;
    }
  }

  /// 保存来自扫码登录的凭证（语义同 [save]，仅用于日志区分来源）。
  Future<bool> saveFromLogin(String token, String userId) async {
    final ok = await save(token, userId);
    if (ok) {
      debugPrint(
          '🔑 酷狗扫码登录凭证已写入: uid=${AppConstants.maskToken(userId)}');
    }
    return ok;
  }

  Future<void> setNickname(String? nickname) async {
    _nickname = (nickname == null || nickname.isEmpty) ? null : nickname;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_nickname == null) {
        await prefs.remove(AppConstants.kugouNickname);
      } else {
        await prefs.setString(AppConstants.kugouNickname, _nickname!);
      }
    } catch (_) {}
  }

  Future<void> clear() async {
    _token = null;
    _userId = null;
    _nickname = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(AppConstants.kugouToken);
      await prefs.remove(AppConstants.kugouUserid);
      await prefs.remove(AppConstants.kugouNickname);
      debugPrint('🧹 已清除酷狗凭证');
    } catch (_) {}
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

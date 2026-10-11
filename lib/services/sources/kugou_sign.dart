import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'kugou_config.dart';

/// 酷狗签名与 key 计算（自实现 MD5，不依赖外部签名服务）。
///
/// 三套签名入口，按**接口归属平台**选用，切勿混用（混用 → `error_code=20006`）：
/// - [webSignature]：Web 端接口 —— 搜索（complexsearch）与登录（login-user）；
/// - [androidSignature]：Android 端接口 —— gateway 取播放地址；
/// - [signature]：底层通用实现（缺省盐值 = [KugouConfig.secret]，等价
///   [androidSecretLite]，保证既有调用**逐字节不变**）。
class KugouSign {
  KugouSign._();

  /// MD5 十六进制小写。
  static String md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// signature = md5(salt + 字典序 "k=v" 直连（无分隔符） + salt)。
  ///
  /// [salt] 缺省 = [KugouConfig.secret]（= [KugouConfig.androidSecretLite]），
  /// 保证既有搜索 / 取地址调用**逐字节不变**。
  ///
  /// 语义化调用请改用 [webSignature] / [androidSignature]，避免盐值混乱。
  static String signature(Map<String, dynamic> params, {String? salt}) {
    final keys = params.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final k in keys) {
      final v = params[k];
      if (v == null) continue;
      buffer.write('$k=$v');
    }
    final s = salt ?? KugouConfig.secret;
    return md5Hex('$s$buffer$s');
  }

  /// Web 端接口签名（盐值 = [KugouConfig.webSecret]）。
  ///
  /// 适用于搜索（`complexsearch`）与登录（`login-user`）等 Web 端接口。
  static String webSignature(Map<String, dynamic> params) =>
      signature(params, salt: KugouConfig.webSecret);

  /// Android 端接口签名（盐值 = [KugouConfig.androidSecretLite]）。
  ///
  /// 适用于概念版 / lite 走 gateway 取播放地址等 Android 端接口。
  static String androidSignature(Map<String, dynamic> params) =>
      signature(params, salt: KugouConfig.androidSecretLite);

  /// 登录专用签名 —— 与 Web 端搜索共用盐值，故等价于 [webSignature]。
  static String loginSignature(Map<String, dynamic> params) =>
      webSignature(params);

  /// 播放地址 key = md5(hash + salt + appid + mid + userid)。
  ///
  /// [salt] 缺省 = [KugouConfig.keySaltStandard]（既有语义不变）；
  /// 概念版（lite）请显式传 [KugouConfig.keySaltLite]。
  static String playKey({
    required String hash,
    required String mid,
    required String userId,
    String? salt,
  }) {
    final s = salt ?? KugouConfig.keySaltStandard;
    return md5Hex('$hash$s${KugouConfig.appid}$mid$userId');
  }
}

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
    return signatureWithBody(params, salt: salt);
  }

  /// = md5(salt + 字典序 "k=v" + [body] + salt)。
  ///
  /// 用于带请求体的接口（如 `register_dev`：Android 端签名会把 body 串拼进签名）。
  static String signatureWithBody(
    Map<String, dynamic> params, {
    String? salt,
    String body = '',
  }) {
    final keys = params.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final k in keys) {
      final v = params[k];
      if (v == null) continue;
      buffer.write('$k=$v');
    }
    final s = salt ?? KugouConfig.secret;
    return md5Hex('$s$buffer$body$s');
  }

  /// Android 端 + 请求体签名（盐值按 [platform] 取，缺省概念版）。
  static String androidSignatureWithBody(
    Map<String, dynamic> params,
    String body, {
    KugouPlatform platform = KugouPlatform.lite,
  }) =>
      signatureWithBody(
          params, salt: KugouConfig.androidSaltOf(platform), body: body);

  /// Web 端接口签名（盐值 = [KugouConfig.webSecret]，两平台共用）。
  ///
  /// 适用于搜索（`complexsearch`）与登录（`login-user`）等 Web 端接口。
  static String webSignature(Map<String, dynamic> params) =>
      signature(params, salt: KugouConfig.webSecret);

  /// Android 端接口签名（盐值按 [platform] 取）。
  ///
  /// 适用于走 gateway 取播放地址 / 每日推荐 / 私人 FM 等 Android 端接口。
  static String androidSignature(
    Map<String, dynamic> params, {
    KugouPlatform platform = KugouPlatform.lite,
  }) =>
      signature(params, salt: KugouConfig.androidSaltOf(platform));

  /// 登录专用签名 —— 与 Web 端搜索共用盐值，故等价于 [webSignature]。
  static String loginSignature(Map<String, dynamic> params) =>
      webSignature(params);

  /// 播放地址 key = md5(hash + salt + appid + mid + userid)。
  ///
  /// 优先按 [platform] 推导 salt 与 appid；显式传入的 [salt] / [appid] 优先。
  /// [salt] 缺省 = [KugouConfig.keySaltStandard]（既有语义不变），
  /// [appid] 缺省 = 概念版（既有语义不变）。
  static String playKey({
    required String hash,
    required String mid,
    required String userId,
    KugouPlatform? platform,
    String? salt,
    int? appid,
  }) {
    final s = salt ??
        (platform != null
            ? KugouConfig.keySaltOf(platform)
            : KugouConfig.keySaltStandard);
    final a = appid ??
        (platform != null ? KugouConfig.appidOf(platform) : KugouConfig.appid);
    return md5Hex('$hash$s$a$mid$userId');
  }

  /// 参数密钥签名 `signParamsKey` = md5(appid + android盐 + clientver + data)。
  ///
  /// 用于私人FM（`/v2/personal_recommend`）等接口的 `key` 参数。
  static String paramsKey(
    Object data, {
    KugouPlatform platform = KugouPlatform.lite,
  }) {
    final appid = KugouConfig.appidOf(platform);
    final salt = KugouConfig.androidSaltOf(platform);
    final clientver = KugouConfig.clientverOf(platform);
    return md5Hex('$appid$salt$clientver$data');
  }
}

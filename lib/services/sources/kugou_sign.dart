import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'kugou_config.dart';

/// 酷狗签名与 key 计算（自实现 MD5，不依赖外部签名服务）。
class KugouSign {
  KugouSign._();

  /// MD5 十六进制小写
  static String md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  /// signature = md5(SECRET + 按 key 字母序拼接的 "k=v" 串 + SECRET)
  static String signature(Map<String, dynamic> params) {
    final keys = params.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final k in keys) {
      final v = params[k];
      if (v == null) continue;
      buffer.write('$k=$v');
    }
    return md5Hex('${KugouConfig.secret}$buffer${KugouConfig.secret}');
  }

  /// 播放地址 key = md5(hash + pidVersionSecret + appid + mid + userid)
  static String playKey({
    required String hash,
    required String mid,
    required String userId,
  }) {
    return md5Hex(
        '$hash${KugouConfig.pidVersionSecret}${KugouConfig.appid}$mid$userId');
  }
}

import 'dart:math';

/// 进程内固定的酷狗设备指纹，搜索 / 取地址 / 扫码登录**共用一套**。
///
/// 登录接口要求 `uuid == mid`（32 位 hex）且 `dfid` 形如 `"0j"` + 20 位
/// Base62；搜索 / 取地址对格式无强约束。统一收敛可降低风控概率。
class KugouDevice {
  KugouDevice._();

  /// 设备 mid（32 位小写 hex，进程内固定）。
  static final String mid = _randomHex(32);

  /// uuid（登录要求与 mid 相同）。
  static final String uuid = mid;

  /// dfid（`"0j"` + 20 位 Base62）。
  static final String dfid = _randomDfid();

  static const String _base62 =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  static String _randomHex(int len) {
    final r = Random();
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.write(r.nextInt(16).toRadixString(16));
    }
    return sb.toString();
  }

  static String _randomDfid() {
    final r = Random();
    final sb = StringBuffer('0j');
    for (var i = 0; i < 20; i++) {
      sb.write(_base62[r.nextInt(_base62.length)]);
    }
    return sb.toString();
  }
}

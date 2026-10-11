import 'dart:math';

import 'package:flutter/foundation.dart';

/// 进程内/跨启动稳定的酷狗设备指纹，搜索 / 取地址 / 扫码登录 / 设备注册**共用一套**。
///
/// 关键约定（实测得出）：
/// - `mid` 必须为**纯数字串**——酷狗「设备注册」接口会拒绝含字母的 mid
///   （返回空 `data`），进而拿不到 `dfid`，取直链被风控（`20028`）；
/// - `uuid == mid`（登录/取码要求一致）；
/// - `dfid` 初始为随机值占位，经 [KugouDeviceService] 注册后替换为**真实 dfid**；
/// - `dfid` 与 `mid` 绑定，二者必须**跨启动持久化**，否则重开 App 后取直链再次失败。
class KugouDevice {
  KugouDevice._();

  static String _guid = _randomGuid();
  static String _mid = _randomDigits(32);
  static String _uuid = _mid;
  static String _dfid = randomDfid();

  /// 设备 GUID（UUID v4，注册时作 `uuid` / `imei`）。
  static String get guid => _guid;

  /// 设备 mid（32 位数字串）。
  static String get mid => _mid;

  /// uuid（登录要求与 mid 相同）。
  static String get uuid => _uuid;

  /// dfid（初始随机；注册成功后为真实 dfid）。
  static String get dfid => _dfid;

  /// 是否已持有注册后的真实 dfid（由 [KugouDeviceService] 维护）。
  static bool get hasRegisteredDfid => _registered;

  static bool _registered = false;

  /// 应用持久化值（启动时调用；missing 字段保持原值）。
  static void applyPersisted({
    String? guid,
    String? mid,
    String? dfid,
  }) {
    if (guid != null && guid.isNotEmpty) _guid = guid;
    if (mid != null && mid.isNotEmpty) {
      _mid = mid;
      _uuid = mid;
    }
    if (dfid != null && dfid.isNotEmpty) {
      _dfid = dfid;
      _registered = true;
    }
  }

  /// 注册成功后写入真实 dfid。
  static void applyRegisteredDfid(String dfid) {
    if (dfid.isEmpty) return;
    _dfid = dfid;
    _registered = true;
  }

  /// 测试专用：重置/覆盖设备状态。
  @visibleForTesting
  static void overrideForTest({
    String? guid,
    String? mid,
    String? dfid,
    bool? registered,
  }) {
    if (guid != null) _guid = guid;
    if (mid != null) {
      _mid = mid;
      _uuid = mid;
    }
    if (dfid != null) _dfid = dfid;
    if (registered != null) _registered = registered;
  }

  static const String _base62 =
      '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

  static String _randomDigits(int len) {
    final r = Random();
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.write(r.nextInt(10));
    }
    return sb.toString();
  }

  /// dfid：`"0j"` + 20 位 Base62。
  @visibleForTesting
  static String randomDfid() {
    final r = Random();
    final sb = StringBuffer('0j');
    for (var i = 0; i < 20; i++) {
      sb.write(_base62[r.nextInt(_base62.length)]);
    }
    return sb.toString();
  }

  static String _randomGuid() {
    final r = Random();
    String hex(int n) {
      final sb = StringBuffer();
      for (var i = 0; i < n; i++) {
        sb.write(r.nextInt(16).toRadixString(16));
      }
      return sb.toString();
    }

    final variant = '89ab'[r.nextInt(4)];
    return '${hex(8)}-${hex(4)}-4${hex(3)}-$variant${hex(3)}-${hex(12)}';
  }
}

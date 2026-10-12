import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/app_constants.dart';
import 'kugou_config.dart';
import 'kugou_crypto.dart';
import 'kugou_device.dart';
import 'kugou_sign.dart';

/// 酷狗设备注册服务（`register_dev`）。
///
/// **为什么需要它**：酷狗取播放直链接口对**未注册设备**返回 `20028 本次请求需要验证`
/// （风控）→ 表现为「一放歌就回退网易云」。必须先经 `register_dev` 拿到真实 `dfid`。
///
/// **按平台注册**：注册请求带 `appid`（概念版 3116 / 原版 1005），返回的 `dfid`
/// 与该 `appid` 绑定 —— 实测用概念版注册的 dfid 请求原版取链接口会被拒，
/// 故两平台**各自注册并分区持久化**。
///
/// 关键点（对齐 KuGouMusicApi `module/register_dev.js`）：
/// - mid 必须**纯数字**，且 mid/dfid 需**持久化**（dfid 与 mid 绑定）；
/// - body 为 AES-CBC/PKCS7 加密的设备信息（Base64），会话串 `p` 为 RSA-PKCS1 加密
///   （RSA 公钥按平台选择）；
/// - 响应为加密字节，需用同一 AES 密钥解密后取 `data.dfid`。
///
/// 服务层**不外抛**：任何异常 → 返回 `false` / `null` + `debugPrint`。
class KugouDeviceService {
  KugouDeviceService._({Dio? dio}) : _dio = dio ?? _defaultDio();

  /// 生产单例。
  static final KugouDeviceService instance = KugouDeviceService._();

  /// 测试专用：注入自定义 [Dio]。
  @visibleForTesting
  factory KugouDeviceService.withDio(Dio dio) => KugouDeviceService._(dio: dio);

  final Dio _dio;

  Future<void>? _initFuture;

  static Dio _defaultDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

  /// dfid 持久化 key：概念版沿用历史命名，原版加 `_standard` 后缀。
  static String _dfidKey(KugouPlatform p) => p == KugouPlatform.lite
      ? AppConstants.kugouDfid
      : '${AppConstants.kugouDfid}_${p.code}';

  /// 启动时调用（幂等，可重复 await）：加载持久化设备标识，必要时注册（概念版）。
  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      var mid = prefs.getString(AppConstants.kugouMid);
      var guid = prefs.getString(AppConstants.kugouGuid);
      // mid 必须为纯数字（否则注册接口拒绝）
      if (mid == null || mid.isEmpty || !RegExp(r'^\d+$').hasMatch(mid)) {
        mid = KugouDevice.mid;
        guid = KugouDevice.guid;
        await prefs.setString(AppConstants.kugouMid, mid);
        await prefs.setString(AppConstants.kugouGuid, guid);
        debugPrint('📱 已生成并持久化酷狗设备 mid=${AppConstants.maskToken(mid)}');
      }

      // 加载两平台已持久化的 dfid
      final persisted = <KugouPlatform, String>{};
      for (final p in KugouPlatform.values) {
        final d = prefs.getString(_dfidKey(p));
        if (d != null && d.isNotEmpty) persisted[p] = d;
      }
      KugouDevice.applyPersisted(guid: guid, mid: mid, dfid: persisted);

      // 概念版缺失则注册（保持既有启动行为）
      if (!persisted.containsKey(KugouPlatform.lite)) {
        await register();
      } else {
        debugPrint(
            '📱 已加载酷狗 dfid: ${AppConstants.maskToken(persisted[KugouPlatform.lite])}');
      }
    } catch (e) {
      debugPrint('⚠️ 酷狗设备初始化失败: $e');
    }
  }

  /// 确保拿到真实 dfid（首次调用会触发注册）。返回 dfid 或 `null`。
  Future<String?> ensureDfid(
      {KugouPlatform platform = KugouPlatform.lite}) async {
    await init();
    if (KugouDevice.hasRegisteredDfidFor(platform)) {
      return KugouDevice.dfidOf(platform);
    }
    final ok = await register(platform: platform);
    return ok ? KugouDevice.dfidOf(platform) : null;
  }

  /// 执行设备注册（含重试）。成功 → 写入并持久化 dfid，返回 `true`。
  ///
  /// 服务端注册为**概率性通过**（同 IP 高频注册会被限流返回空 `data`），
  /// 故此处做有限次重试；真机通常首次即成功。
  Future<bool> register({
    KugouPlatform platform = KugouPlatform.lite,
    int maxAttempts = 5,
  }) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final ok = await _registerOnce(platform);
      if (ok) return true;
      if (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 1200 + attempt * 400));
      }
    }
    debugPrint(
        '❌ 酷狗设备注册(${platform.label})连续 $maxAttempts 次失败（可能被限流，稍后自动重试）');
    return false;
  }

  Future<bool> _registerOnce(KugouPlatform platform) async {
    try {
      final clienttime = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // 1) 设备信息 AES 加密
      final aes = KugouCrypto.playlistAesEncrypt(_deviceInfo());
      // 2) 会话串 RSA 加密（按平台选公钥）
      final p = KugouCrypto.rsaPkcs1EncryptHex(
        {'aes': aes.key, 'uid': 0, 'token': ''},
        KugouConfig.rsaPublicKeyOf(platform),
      );

      final params = <String, dynamic>{
        'dfid': '-',
        'mid': KugouDevice.mid,
        'uuid': '-',
        'appid': KugouConfig.appidOf(platform),
        'clientver': KugouConfig.loginClientverOf(platform),
        'clienttime': clienttime,
        'part': 1,
        'platid': 1,
        'p': p,
      };
      // Android 端签名会把 body 串拼进签名（盐值按平台）
      final signature = KugouSign.androidSignatureWithBody(params, aes.str,
          platform: platform);

      final res = await _dio.post(
        '${KugouConfig.registerHost}${KugouConfig.registerPath}',
        data: aes.str,
        queryParameters: {...params, 'signature': signature},
        options: Options(
          responseType: ResponseType.bytes,
          contentType: 'application/x-www-form-urlencoded',
          headers: {
            'User-Agent': KugouConfig.androidUserAgent,
            'dfid': '-',
            'clienttime': clienttime,
            'mid': KugouDevice.mid,
            ...KugouConfig.androidCommonHeaders,
          },
        ),
      );

      final raw = res.data;
      final bytes = raw is Uint8List
          ? raw
          : Uint8List.fromList((raw as List).cast<int>());
      final decoded = KugouCrypto.playlistAesDecrypt(bytes, aes.key);
      if (decoded is! Map) {
        debugPrint('❌ 酷狗设备注册响应异常（非对象）');
        return false;
      }
      final status = decoded['status'];
      final data = decoded['data'];
      final dfid = (data is Map) ? data['dfid']?.toString() : null;
      if (status?.toString() != '1' || dfid == null || dfid.isEmpty) {
        debugPrint('❌ 酷狗设备注册(${platform.label})失败 status=$status');
        return false;
      }

      KugouDevice.applyRegisteredDfidFor(platform, dfid);
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_dfidKey(platform), dfid);
      } catch (_) {}
      debugPrint(
          '📱 酷狗设备注册成功(${platform.label}) dfid=${AppConstants.maskToken(dfid)}');
      return true;
    } catch (e) {
      debugPrint('❌ 酷狗设备注册(${platform.label})异常: $e');
      return false;
    }
  }

  /// 对齐上游 `register_dev.js` 的设备信息（默认值同上游，Redmi/marble）。
  Map<String, dynamic> _deviceInfo() => {
        'availableRamSize': 4983533568,
        'availableRomSize': 48114719,
        'availableSDSize': 48114717,
        'basebandVer': '',
        'batteryLevel': 100,
        'batteryStatus': 3,
        'brand': 'Redmi',
        'buildSerial': 'unknown',
        'device': 'marble',
        'imei': KugouDevice.guid,
        'imsi': '',
        'manufacturer': 'Xiaomi',
        'uuid': KugouDevice.guid,
        'accelerometer': false,
        'accelerometerValue': '',
        'gravity': false,
        'gravityValue': '',
        'gyroscope': false,
        'gyroscopeValue': '',
        'light': false,
        'lightValue': '',
        'magnetic': false,
        'magneticValue': '',
        'orientation': false,
        'orientationValue': '',
        'pressure': false,
        'pressureValue': '',
        'step_counter': false,
        'step_counterValue': '',
        'temperature': false,
        'temperatureValue': '',
      };
}

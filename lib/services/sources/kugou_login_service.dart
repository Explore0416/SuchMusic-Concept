import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../utils/app_constants.dart';
import 'kugou_config.dart';
import 'kugou_device.dart';
import 'kugou_login_models.dart';
import 'kugou_sign.dart';

/// 酷狗概念版扫码登录服务（ARCH-酷狗登录 §2.2）。
///
/// - 单飞顺序轮询（非 `Timer.periodic` 并发），从根本上避免重复请求；
/// - 过期 / 本地 TTL 到期自动换码；连续错误 / 超时停止（不无限刷风控）；
/// - `cancel()` 幂等，取消在飞 Dio 请求 + 关闭流；
/// - 服务层**不外抛**：任何异常 → `null` / `failed` 态 + `debugPrint`。
class KugouLoginService {
  /// 带参构造：便于单测注入假 Dio / 假时钟 / 缩短轮询参数。
  KugouLoginService({
    Dio? dio,
    DateTime Function()? now,
    this.pollInterval = const Duration(seconds: 2),
    this.sessionTtl = const Duration(seconds: 120),
    this.maxWait = const Duration(minutes: 3),
    this.maxConsecutiveErrors = 5,
  })  : _dio = dio ?? _defaultDio(),
        _now = now ?? DateTime.now;

  /// 生产单例（App 使用）。
  static final KugouLoginService instance = KugouLoginService();

  final Dio _dio;
  final DateTime Function() _now;

  /// 轮询间隔（默认 2s）。
  final Duration pollInterval;

  /// 单码有效期（默认 120s）。
  final Duration sessionTtl;

  /// 整体等待上限（默认 3min）。
  final Duration maxWait;

  /// 连续网络错误上限（默认 5）。
  final int maxConsecutiveErrors;

  CancelToken? _inflight;
  StreamController<KugouQrPollResult>? _controller;
  bool _cancelled = true;
  int _generation = 0;

  static Dio _defaultDio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

  /// 取二维码。成功 → [KugouQrSession]；失败 / 异常 → `null`（不外抛）。
  Future<KugouQrSession?> createQr() async {
    final token = CancelToken();
    _inflight = token;
    try {
      final params = <String, dynamic>{
        'appid': KugouConfig.appid,
        'srcappid': KugouConfig.srcappid,
        'clientver': KugouConfig.loginClientver,
        'clienttime': _now().millisecondsSinceEpoch.toString(),
        'mid': KugouDevice.mid,
        'uuid': KugouDevice.uuid,
        'dfid': KugouDevice.dfid,
        'type': KugouConfig.qrcodeType,
        'plat': KugouConfig.platWeb,
        'qrcode_txt': KugouConfig.qrTxt,
      };
      final signature = KugouSign.loginSignature(params);
      final res = await _dio.get(
        '${KugouConfig.loginHost}${KugouConfig.loginQrPath}',
        queryParameters: {...params, 'signature': signature},
        cancelToken: token,
        options: Options(headers: {
          'Referer': KugouConfig.loginReferer,
          'Origin': KugouConfig.loginOrigin,
          'User-Agent': KugouConfig.userAgent,
        }),
      );
      final data = res.data;
      if (data is! Map) {
        debugPrint('❌ 酷狗取二维码失败（响应非对象）');
        return null;
      }
      final d = data['data'];
      if (d is! Map) {
        debugPrint('❌ 酷狗取二维码失败（缺少 data）');
        return null;
      }
      final key = d['qrcode']?.toString() ?? '';
      if (key.isEmpty) {
        debugPrint('❌ 酷狗取二维码失败（缺少 qrcode key）');
        return null;
      }
      final image = d['qrcode_img']?.toString() ?? '';
      return KugouQrSession(
        key: key,
        imageDataUri: image,
        expiresAt: _now().add(sessionTtl),
      );
    } catch (e) {
      debugPrint('❌ 酷狗取二维码失败: $e');
      return null;
    }
  }

  /// 单次轮询。成功 → [KugouQrPollResult]；网络异常 → `null`（本轮跳过）。
  Future<KugouQrPollResult?> pollStatus(String key) async {
    final token = CancelToken();
    _inflight = token;
    try {
      final params = <String, dynamic>{
        'plat': KugouConfig.platWeb,
        'appid': KugouConfig.appid,
        'srcappid': KugouConfig.srcappid,
        'qrcode': key,
        'clientver': KugouConfig.loginClientver,
        'clienttime': _now().millisecondsSinceEpoch.toString(),
        'mid': KugouDevice.mid,
        'uuid': KugouDevice.uuid,
        'dfid': KugouDevice.dfid,
      };
      final signature = KugouSign.loginSignature(params);
      final res = await _dio.get(
        '${KugouConfig.loginHost}${KugouConfig.loginStatusPath}',
        queryParameters: {...params, 'signature': signature},
        cancelToken: token,
        options: Options(headers: {
          'Referer': KugouConfig.loginReferer,
          'Origin': KugouConfig.loginOrigin,
          'User-Agent': KugouConfig.userAgent,
        }),
      );
      final data = res.data;
      if (data is! Map || data['data'] is! Map) {
        debugPrint('⚠️ 酷狗轮询响应异常（容错为等待扫码）');
        return const KugouQrPollResult(state: QrLoginState.waiting);
      }
      final d = data['data'] as Map;
      final status = int.tryParse(d['status']?.toString() ?? '') ?? 1;
      switch (status) {
        case 0:
          return const KugouQrPollResult(state: QrLoginState.expired);
        case 2:
          return const KugouQrPollResult(state: QrLoginState.scanned);
        case 3:
          return const KugouQrPollResult(state: QrLoginState.confirmed);
        case 4:
          return KugouQrPollResult(
            state: QrLoginState.success,
            token: d['token']?.toString(),
            userId: d['userid']?.toString(),
          );
        default:
          return const KugouQrPollResult(state: QrLoginState.waiting);
      }
    } catch (e) {
      debugPrint('⚠️ 酷狗轮询异常: $e');
      return null;
    }
  }

  /// 取码 → 轮询（默认 2s）→ 过期自动换码 → 成功 / 失败结束。
  ///
  /// 返回**单订阅**流；调用方必须在 dispose / 离开页面时 [cancel]。
  Stream<KugouQrPollResult> startAutoLogin() {
    cancel();
    final controller = StreamController<KugouQrPollResult>();
    _controller = controller;
    _cancelled = false;
    final gen = ++_generation;
    _runLoop(controller, gen);
    return controller.stream;
  }

  /// 取消定时器 + 取消在飞 Dio 请求（**幂等**，可重复调用）。
  void cancel() {
    _cancelled = true;
    _generation++;
    try {
      _inflight?.cancel('cancelled');
    } catch (_) {}
    _inflight = null;
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) {
      c.close();
    }
  }

  /// 释放（内部调 [cancel]）。
  void dispose() => cancel();

  // ── 内部：轮询循环 ────────────────────────────────────────

  bool _stopped(int gen, StreamController c) =>
      _cancelled || gen != _generation || c.isClosed;

  void _emit(StreamController<KugouQrPollResult> c, KugouQrPollResult r) {
    if (!c.isClosed) c.add(r);
  }

  Future<void> _runLoop(
      StreamController<KugouQrPollResult> c, int gen) async {
    final startedAt = _now();
    var errors = 0;

    final created = await createQr();
    if (_stopped(gen, c)) return;
    if (created == null) {
      _emit(c, KugouQrPollResult.failed('获取二维码失败，请重试'));
      if (!c.isClosed) await c.close();
      return;
    }
    KugouQrSession session = created;
    _emit(c, KugouQrPollResult(state: QrLoginState.waiting, session: session));

    while (true) {
      if (_stopped(gen, c)) return;

      // 整体超时
      if (_now().difference(startedAt) > maxWait) {
        debugPrint('⚠️ 酷狗登录超时');
        _emit(c, KugouQrPollResult.failed('登录超时，请重试'));
        if (!c.isClosed) await c.close();
        return;
      }

      // 本地 TTL 到期 → 自动换码
      if (session.isExpiredAt(_now())) {
        final fresh = await createQr();
        if (_stopped(gen, c)) return;
        if (fresh == null) {
          _emit(c, KugouQrPollResult.failed('二维码刷新失败，请重试'));
          if (!c.isClosed) await c.close();
          return;
        }
        session = fresh;
        _emit(c, KugouQrPollResult.expired(session));
        await _delay();
        continue;
      }

      final result = await pollStatus(session.key);
      if (_stopped(gen, c)) return;

      if (result == null) {
        errors++;
        debugPrint('⚠️ 酷狗轮询错误第 $errors 次');
        if (errors > maxConsecutiveErrors) {
          _emit(c, KugouQrPollResult.failed('网络异常，请重试'));
          if (!c.isClosed) await c.close();
          return;
        }
        await _delay();
        continue;
      }
      errors = 0;

      switch (result.state) {
        case QrLoginState.success:
          debugPrint(
              '🔑 酷狗扫码登录成功 uid=${AppConstants.maskToken(result.userId)}');
          _emit(c, result);
          if (!c.isClosed) await c.close();
          return;
        case QrLoginState.expired:
          final fresh = await createQr();
          if (_stopped(gen, c)) return;
          if (fresh == null) {
            _emit(c, KugouQrPollResult.failed('二维码刷新失败，请重试'));
            if (!c.isClosed) await c.close();
            return;
          }
          session = fresh;
          _emit(c, KugouQrPollResult.expired(session));
        default:
          _emit(c, KugouQrPollResult(state: result.state, session: session));
      }

      await _delay();
    }
  }

  Future<void> _delay() async {
    if (pollInterval > Duration.zero) {
      await Future<void>.delayed(pollInterval);
    } else {
      await Future<void>.value();
    }
  }
}

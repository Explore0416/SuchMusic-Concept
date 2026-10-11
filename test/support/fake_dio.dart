import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 可注入的 Dio 替身（供 service 层单测使用，**不进生产代码**）。
///
/// - 记录所有出站请求（[log]）以便断言 URL / 参数 / 签名；
/// - 统计并发峰值（[maxActive]）以验证「单飞无并发」；
/// - 支持通过 `cancelFuture` 模拟在飞请求被取消。
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  /// 出站请求日志（按调用顺序）。
  final List<RequestOptions> log = <RequestOptions>[];

  int _active = 0;

  /// 同时未完成的请求峰值。
  int maxActive = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    log.add(options);
    _active++;
    if (_active > maxActive) maxActive = _active;

    final completer = Completer<ResponseBody>();
    if (cancelFuture != null) {
      cancelFuture.whenComplete(() {
        if (!completer.isCompleted) {
          completer.completeError(
            DioException.requestCancelled(
              requestOptions: options,
              reason: 'cancelled',
            ),
          );
        }
      });
    }
    Future<void>.microtask(() async {
      try {
        final r = await handler(options);
        if (!completer.isCompleted) completer.complete(r);
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(
            e is DioException
                ? e
                : DioException(requestOptions: options, error: e),
          );
        }
      } finally {
        _active--;
      }
    });
    return completer.future;
  }

  @override
  void close({bool force = false}) {}
}

/// 用给定 handler 构造一个 Dio（测试专用）。
Dio fakeDio(FakeAdapter adapter) {
  final dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 5),
    validateStatus: (s) => s != null && s < 500,
  ));
  dio.httpClientAdapter = adapter;
  return dio;
}

/// 构造 JSON 响应体。
ResponseBody jsonResponse(Object data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// 构造「内容类型为 text/html 的 JSON 字符串」响应体。
///
/// 复现酷狗 complexsearch 部分 CDN 节点返回 `text/html` 的场景：此时 Dio 不会
/// 自动 JSON 解码，`Response.data` 为原始 String —— 用于验证上层手动解码兜底。
ResponseBody htmlJsonResponse(Object data, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );

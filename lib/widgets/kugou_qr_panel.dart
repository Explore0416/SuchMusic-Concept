import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/sources/kugou_login_models.dart';

/// 二维码展示 + 状态提示（纯展示组件，无网络逻辑，便于 widget 测试）。
///
/// 渲染优先级：`session.imageDataUri`（接口直返 base64 data-URI）→ 失败则
/// 用 `qr_flutter` 渲染 [KugouQrSession.placeholderUrl]；`session == null`
/// 时显示占位骨架。`imageDataUri` 解析失败**不得崩溃**。
class KugouQrPanel extends StatelessWidget {
  const KugouQrPanel({
    super.key,
    required this.state,
    this.session,
    this.size = 220,
    this.onRefresh,
  });

  final QrLoginState state;
  final KugouQrSession? session;
  final double size;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildQr(),
        const SizedBox(height: 12),
        _buildStatus(context),
      ],
    );
  }

  Widget _buildQr() {
    final s = session;
    if (s == null) return _placeholder();
    final uri = s.imageDataUri;
    if (uri.startsWith('data:image')) {
      final bytes = _tryDecode(uri);
      if (bytes != null) {
        return SizedBox(
          width: size,
          height: size,
          child: Image.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.contain,
            // 解码失败 → 回退 qr_flutter（不崩溃）
            errorBuilder: (_, _, _) => _qrFallback(s),
          ),
        );
      }
    }
    return _qrFallback(s);
  }

  Widget _qrFallback(KugouQrSession s) {
    return Container(
      width: size,
      height: size,
      color: Colors.white,
      alignment: Alignment.center,
      child: QrImageView(
        data: s.placeholderUrl,
        size: size,
        backgroundColor: Colors.white,
      ),
    );
  }

  Widget _placeholder() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F2F4),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: const Text('获取二维码中…',
          style: TextStyle(color: Color(0xFF838383), fontSize: 14)),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final info = _statusInfo();
    final canRefresh = state == QrLoginState.expired ||
        state == QrLoginState.failed;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          info.$1,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 14,
            color: info.$2,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (canRefresh && onRefresh != null) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: onRefresh,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: const Color(0xFF2F84FE),
            ),
            child: const Text('刷新二维码'),
          ),
        ],
      ],
    );
  }

  /// (文案, 颜色)
  (String, Color) _statusInfo() {
    switch (state) {
      case QrLoginState.waiting:
        return ('请使用酷狗概念版 App 扫码', Colors.black87);
      case QrLoginState.scanned:
        return ('已扫码，请在手机上确认', const Color(0xFF2F84FE));
      case QrLoginState.confirmed:
        return ('已确认，正在登录…', const Color(0xFF2F84FE));
      case QrLoginState.expired:
        return ('二维码已过期，正在刷新…', const Color(0xFFE53935));
      case QrLoginState.success:
        return ('登录成功', const Color(0xFF2F84FE));
      case QrLoginState.failed:
        return ('获取失败，点击重试', const Color(0xFFE53935));
    }
  }

  /// base64 data-URI 解码；失败返回 `null`（交给上层回退）。
  Uint8List? _tryDecode(String dataUri) {
    try {
      final idx = dataUri.indexOf(',');
      final b64 = idx >= 0 ? dataUri.substring(idx + 1) : dataUri;
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }
}

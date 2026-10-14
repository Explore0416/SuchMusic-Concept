import 'dart:async';

import 'package:flutter/material.dart';

import '../models/kugou_platform.dart';
import '../services/kugou_credential_service.dart';
import '../services/sources/kugou_credential_parser.dart';
import '../services/sources/kugou_login_models.dart';
import '../services/sources/kugou_login_service.dart';
import 'design_dialog.dart';
import 'kugou_qr_panel.dart';

/// 弹出「酷狗扫码登录」弹窗，形态与网易云扫码弹窗**保持一致**
/// （网易云 / 酷狗概念版 / 酷狗音乐三处登录 UI 统一）。
///
/// 流程：取码 → 轮询 → 授权成功 → 写入该平台凭证。
/// 扫码不可用时提供「手动输入凭证」兜底入口（粘贴 cookie / JSON）。
///
/// 返回值：`true` 表示登录成功且凭证已保存；取消 / 失败返回 `false`。
Future<bool> showKugouLoginDialog(
  BuildContext context, {
  required KugouPlatform platform,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 25),
      child: _KugouLoginSheet(platform: platform),
    ),
  );
  return result ?? false;
}

class _KugouLoginSheet extends StatefulWidget {
  const _KugouLoginSheet({required this.platform});

  final KugouPlatform platform;

  @override
  State<_KugouLoginSheet> createState() => _KugouLoginSheetState();
}

class _KugouLoginSheetState extends State<_KugouLoginSheet> {
  final KugouCredentialService _credential = KugouCredentialService.instance;
  late final KugouLoginService _loginService =
      KugouLoginService.forPlatform(widget.platform);

  StreamSubscription<KugouQrPollResult>? _qrSub;
  QrLoginState _state = QrLoginState.waiting;
  KugouQrSession? _session;

  /// 防止 success 事件重复触发保存 / 重复 pop。
  bool _handlingSuccess = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // 退出弹窗：退订 + 取消在飞请求与轮询（防离页后仍写凭证 / 泄漏）
    _qrSub?.cancel();
    _loginService.cancel();
    super.dispose();
  }

  void _start() {
    _qrSub?.cancel();
    setState(() {
      _state = QrLoginState.waiting;
      _session = null;
    });
    _qrSub = _loginService.startAutoLogin().listen(
      _onQrUpdate,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  Future<void> _onQrUpdate(KugouQrPollResult result) async {
    if (!mounted) return;
    setState(() {
      _state = result.state;
      if (result.session != null) _session = result.session;
    });
    if (result.state != QrLoginState.success || _handlingSuccess) return;
    _handlingSuccess = true;

    final ok = await _credential.saveFromLogin(
      result.token ?? '',
      result.userId ?? '',
      platform: widget.platform,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      _handlingSuccess = false;
      setState(() => _state = QrLoginState.failed);
    }
  }

  /// 手动输入凭证（扫码不可用时的兜底入口）。
  Future<void> _manualInput() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动输入凭证'),
        content: TextField(
          controller: controller,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: '粘贴整段 cookie 或 JSON，例如 token=...; userid=...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('解析并保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || !mounted) return;

    final parsed = parseCredentialText(raw);
    if (parsed.token == null || parsed.userId == null) {
      DesignToast.show(context, '未识别到完整凭证（需同时包含 token 与 userid）');
      return;
    }
    final ok = await _credential.saveFor(
      widget.platform,
      parsed.token!,
      parsed.userId!,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      DesignToast.show(context, '凭证保存失败，请检查格式');
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = kugouQrStatusInfo(
      _state,
      scanHint: '请使用「${widget.platform.label}」App 扫码授权',
    );
    final canRefresh =
        _state == QrLoginState.expired || _state == QrLoginState.failed;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '扫码登录',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: 200,
            height: 200,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFEEEEEE)),
            ),
            child: KugouQrPanel(
              state: _state,
              session: _session,
              size: 176,
              showStatus: false,
            ),
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 16),
          if (canRefresh)
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: _start,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2F84FE),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('刷新二维码', style: TextStyle(fontSize: 15)),
              ),
            )
          else
            TextButton(
              onPressed: _manualInput,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF838383),
              ),
              child: const Text(
                '扫码不成功？手动输入凭证',
                style: TextStyle(fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }
}

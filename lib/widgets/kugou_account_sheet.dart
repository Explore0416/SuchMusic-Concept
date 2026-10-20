import 'package:flutter/material.dart';

import '../models/kugou_platform.dart';
import '../services/kugou_credential_service.dart';
import 'kugou_login_dialog.dart';

/// 酷狗账号聚合弹窗。
///
/// 「我的」页只保留**一个**酷狗入口，点开后在这里分别管理
/// 概念版（appid=3116）与原版（appid=1005）。
///
/// 为什么不能做成「一次扫码登录两个平台」：
/// 酷狗按 **appid** 签发 token，两个平台的 clientver / 设备标识也不同，
/// 服务端不提供跨 appid 的凭证兑换。所以这里保留两次授权，
/// 但把入口收成一个，不再让列表里并排挂两行酷狗。
Future<void> showKugouAccountSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final bottom = MediaQuery.of(ctx).viewInsets.bottom;
      final mediaBottom = MediaQuery.of(ctx).padding.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: bottom + mediaBottom),
        child: const _KugouAccountBody(),
      );
    },
  );
}

class _KugouAccountBody extends StatefulWidget {
  const _KugouAccountBody();

  @override
  State<_KugouAccountBody> createState() => _KugouAccountBodyState();
}

class _KugouAccountBodyState extends State<_KugouAccountBody> {
  static const Color _accent = Color(0xFF3080FF);
  static const Color _sub = Color(0xFF838383);
  static const Color _divider = Color(0xFFEEEEEE);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '酷狗音乐',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  behavior: HitTestBehavior.opaque,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.close, color: Colors.black54, size: 22),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _divider),
          for (final platform in KugouPlatform.values) ...[
            if (platform != KugouPlatform.values.first)
              const Divider(height: 1, indent: 16, endIndent: 16, color: _divider),
            _buildRow(platform),
          ],
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Text(
              '两个版本共用同一个酷狗账号，但按 appid 分别签发凭证，需要各扫一次码；'
              '登录凭据仅保存在本机。',
              style: TextStyle(color: _sub, fontSize: 11, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(KugouPlatform platform) {
    final cred = KugouCredentialService.instance;
    final logged = cred.hasCredentialsFor(platform);
    final uid = logged ? '（${_maskUid(cred.userIdOf(platform))}）' : '';

    return InkWell(
      onTap: () => _login(platform),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            const Icon(Icons.library_music_outlined, size: 22, color: _accent),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    platform.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    logged ? '已登录$uid' : '未登录 · 扫码后可用对应音质与权益',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _sub),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                logged ? '重新登录' : '扫码登录',
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _maskUid(String? uid) {
    if (uid == null || uid.isEmpty) return '';
    if (uid.length <= 6) return uid;
    return '${uid.substring(0, 3)}***${uid.substring(uid.length - 3)}';
  }

  Future<void> _login(KugouPlatform platform) async {
    await showKugouLoginDialog(context, platform: platform);
    if (!mounted) return;
    setState(() {});
  }
}

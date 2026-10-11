import 'dart:async';

import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/kugou_credential_service.dart';
import '../services/sources/kugou_credential_parser.dart';
import '../services/sources/kugou_login_models.dart';
import '../services/sources/kugou_login_service.dart';
import '../services/sources/source_manager.dart';
import '../utils/app_constants.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';
import '../widgets/kugou_qr_panel.dart';

/// 酷狗概念版凭证页（REQ-11 + 增量「扫码登录」）。
///
/// - **扫码登录**（新增）：取码 → 轮询 → 拿 token/userid → 写入凭证；
///   页面退出 / 销毁**必须**取消在飞请求与轮询；
/// - **粘贴凭证**（新增兜底）：从整段 cookie / JSON 提取 token/userid；
/// - 手工填写（既有，保留为高级 / 兜底）；
/// - 与网易云 `user_cache.json` 隔离存储；全页脱敏展示。
class KugouCredentialPage extends StatefulWidget {
  const KugouCredentialPage({super.key});

  @override
  State<KugouCredentialPage> createState() => _KugouCredentialPageState();
}

class _KugouCredentialPageState extends State<KugouCredentialPage> {
  final _tokenController = TextEditingController();
  final _userIdController = TextEditingController();
  final _nicknameController = TextEditingController();

  final _credential = KugouCredentialService.instance;
  final _loginService = KugouLoginService.instance;

  bool _configured = false;

  // ── 扫码登录状态 ──────────────────────────────────────────
  StreamSubscription<KugouQrPollResult>? _qrSub;
  bool _scanning = false;
  QrLoginState? _qrState;
  KugouQrSession? _qrSession;

  @override
  void initState() {
    super.initState();
    _configured = _credential.hasCredentials;
    _nicknameController.text = _credential.nickname ?? '';
  }

  @override
  void dispose() {
    // 退出页面：退订 + 取消在飞请求与定时器（防离页后仍写凭证 / 泄漏）
    _qrSub?.cancel();
    _loginService.cancel();
    _tokenController.dispose();
    _userIdController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  // ── 扫码登录 ──────────────────────────────────────────────

  void _startScanLogin() {
    _qrSub?.cancel();
    setState(() {
      _scanning = true;
      _qrState = QrLoginState.waiting;
      _qrSession = null;
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
      _qrState = result.state;
      if (result.session != null) _qrSession = result.session;
    });
    if (result.state == QrLoginState.success) {
      await _persistLogin(result.token ?? '', result.userId ?? '');
    }
  }

  Future<void> _persistLogin(String token, String userId) async {
    final ok = await _credential.saveFromLogin(token, userId);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _configured = true;
        _scanning = false;
      });
      DesignToast.show(
        context,
        '登录成功：已登录(${AppConstants.maskToken(userId)})',
      );
    } else {
      DesignToast.show(context, '凭证保存失败，请改用粘贴 / 手填');
    }
  }

  void _stopScan() {
    _qrSub?.cancel();
    _qrSub = null;
    _loginService.cancel();
    setState(() {
      _scanning = false;
      _qrState = null;
      _qrSession = null;
    });
  }

  // ── 粘贴凭证（兜底）──────────────────────────────────────

  Future<void> _showPasteDialog() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴凭证'),
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
    if (parsed.token == null && parsed.userId == null) {
      DesignToast.show(context, '未识别到凭证，请检查粘贴内容');
      return;
    }
    if (parsed.token != null) _tokenController.text = parsed.token!;
    if (parsed.userId != null) _userIdController.text = parsed.userId!;
    await _save();
  }

  // ── 手工保存 / 清除（既有）────────────────────────────────

  Future<void> _save() async {
    final token = _tokenController.text;
    final userId = _userIdController.text;
    if (token.trim().isEmpty || userId.trim().isEmpty) {
      DesignToast.show(context, 'token 与 userid 均不能为空');
      return;
    }
    final ok = await _credential.save(token, userId);
    if (!mounted) return;
    if (!ok) {
      DesignToast.show(context, '凭证保存失败，请检查格式');
      return;
    }
    await _credential.setNickname(_nicknameController.text.trim());
    if (!mounted) return;
    setState(() {
      _configured = true;
      _tokenController.clear();
      _userIdController.clear();
    });
    DesignToast.show(context, '酷狗凭证已保存');
  }

  void _confirmClear() {
    DesignDialog.showConfirm(
      context,
      titleText: '退出登录',
      contentText: '退出后酷狗音源将不可用，并自动回退网易云，确定继续？',
      onConfirm: () async {
        _stopScan();
        await _credential.clear();
        await SourceManager().switchTo(SongSource.netease);
        if (!mounted) return;
        setState(() {
          _configured = false;
          _nicknameController.clear();
        });
        DesignToast.show(context, '已退出登录，已回退网易云');
      },
    );
  }

  // ── 构建 ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final s = Responsive.uiScale(size);
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      body: Column(
        children: [
          Container(
            padding: EdgeInsets.only(top: topPadding),
            color: Colors.white,
            child: SizedBox(
              height: 44 * s,
              child: Stack(
                children: [
                  Positioned(
                    left: 12 * s,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          const Icon(Icons.arrow_back_ios_new,
                              size: 20, color: Colors.black),
                          SizedBox(width: 8 * s - 3),
                          Text('返回',
                              style: TextStyle(
                                  color: Colors.black, fontSize: 14 * s)),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      '酷狗凭证',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 17.5 * s,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ResponsiveContent(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 15),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(height: 17 * s),
                    _buildSectionHeader('扫码登录', s),
                    SizedBox(height: 10 * s),
                    _buildScanCard(s),
                    SizedBox(height: 16 * s),
                    _buildSectionHeader('凭证配置', s),
                    SizedBox(height: 10 * s),
                    _buildCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Token',
                              style: TextStyle(
                                  fontSize: 13 * s,
                                  color: const Color(0xFF838383))),
                          TextField(
                            controller: _tokenController,
                            decoration: InputDecoration(
                              hintText: '酷狗概念版 token',
                              border: InputBorder.none,
                              hintStyle: TextStyle(
                                  fontSize: 14 * s, color: Colors.black38),
                            ),
                            style: TextStyle(fontSize: 14 * s),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 10 * s),
                    _buildCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('UserID',
                              style: TextStyle(
                                  fontSize: 13 * s,
                                  color: const Color(0xFF838383))),
                          TextField(
                            controller: _userIdController,
                            decoration: InputDecoration(
                              hintText: '酷狗用户 userid',
                              border: InputBorder.none,
                              hintStyle: TextStyle(
                                  fontSize: 14 * s, color: Colors.black38),
                            ),
                            style: TextStyle(fontSize: 14 * s),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 10 * s),
                    _buildCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('昵称（可选，仅用于展示）',
                              style: TextStyle(
                                  fontSize: 13 * s,
                                  color: const Color(0xFF838383))),
                          TextField(
                            controller: _nicknameController,
                            decoration: InputDecoration(
                              hintText: '昵称',
                              border: InputBorder.none,
                              hintStyle: TextStyle(
                                  fontSize: 14 * s, color: Colors.black38),
                            ),
                            style: TextStyle(fontSize: 14 * s),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 16 * s),
                    _buildPrimaryButton('保存凭证', _save, s),
                    SizedBox(height: 10 * s),
                    _buildOutlineButton('粘贴凭证（从 cookie / JSON 提取）',
                        _showPasteDialog, s),
                    SizedBox(height: 24 * s),
                    _buildSectionHeader('当前状态', s),
                    SizedBox(height: 10 * s),
                    _buildStatusCard(s),
                    SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanCard(double s) {
    return _buildCard(
      child: Column(
        children: [
          if (!_scanning)
            _buildPrimaryButton('扫码登录', _startScanLogin, s)
          else ...[
            KugouQrPanel(
              state: _qrState ?? QrLoginState.waiting,
              session: _qrSession,
              size: (Responsive.contentWidth(MediaQuery.of(context).size) - 60)
                  .clamp(160.0, 220.0),
              onRefresh: _startScanLogin,
            ),
            const SizedBox(height: 12),
            _buildOutlineButton('取消扫码', _stopScan, s),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, double s) {
    return SizedBox(
      height: 20 * s,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(title,
            style: TextStyle(
                color: const Color(0xFF838383), fontSize: 15.5 * s)),
      ),
    );
  }

  Widget _buildPrimaryButton(String text, VoidCallback onTap, double s) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF2F84FE),
          borderRadius: BorderRadius.circular(10 * s),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
      ),
    );
  }

  Widget _buildOutlineButton(String text, VoidCallback onTap, double s) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10 * s),
          border: Border.all(color: const Color(0xFF2F84FE)),
        ),
        child: Text(text,
            style: const TextStyle(color: Color(0xFF2F84FE), fontSize: 15)),
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }

  Widget _buildStatusCard(double s) {
    final masked = _credential.maskedToken;
    final maskedUid = AppConstants.maskToken(_credential.userId);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _configured ? Icons.check_circle : Icons.error_outline,
                size: 18,
                color: _configured
                    ? const Color(0xFF2F84FE)
                    : const Color(0xFFC4C4C4),
              ),
              const SizedBox(width: 6),
              Text(
                _configured ? '已登录($maskedUid)' : '未配置凭证',
                style: TextStyle(
                  fontSize: 15 * s,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('Token：${_configured ? masked : '—'}',
              style: TextStyle(fontSize: 13 * s, color: Colors.black54)),
          const SizedBox(height: 4),
          Text('UserID：${_configured ? maskedUid : '—'}',
              style: TextStyle(fontSize: 13 * s, color: Colors.black54)),
          if (_configured &&
              _credential.nickname != null &&
              _credential.nickname!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('昵称：${_credential.nickname}',
                style: TextStyle(fontSize: 13 * s, color: Colors.black54)),
          ],
          if (_configured) ...[
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _confirmClear,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: double.infinity,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10 * s),
                  border: Border.all(color: const Color(0xFFE53935)),
                ),
                child: const Text('退出登录',
                    style: TextStyle(color: Color(0xFFE53935), fontSize: 15)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

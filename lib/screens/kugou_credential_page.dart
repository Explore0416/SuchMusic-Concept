import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/kugou_credential_service.dart';
import '../services/sources/source_manager.dart';
import '../utils/app_constants.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';

/// 酷狗概念版凭证录入 / 清除页（REQ-11）。
///
/// - token / userid 手动填写（Q2=A），与网易云 `user_cache.json` 隔离存储。
/// - 全页脱敏展示；清除后音源自动回退网易云。
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

  bool _configured = false;

  @override
  void initState() {
    super.initState();
    _configured = _credential.hasCredentials;
    _nicknameController.text = _credential.nickname ?? '';
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _userIdController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

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
      titleText: '清除酷狗凭证',
      contentText: '清除后酷狗音源将不可用，并自动回退网易云，确定继续？',
      onConfirm: () async {
        await _credential.clear();
        await SourceManager().switchTo(SongSource.netease);
        if (!mounted) return;
        setState(() {
          _configured = false;
          _nicknameController.clear();
        });
        DesignToast.show(context, '凭证已清除，已回退网易云');
      },
    );
  }

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
                    GestureDetector(
                      onTap: _save,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: double.infinity,
                        height: 48,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2F84FE),
                          borderRadius: BorderRadius.circular(10 * s),
                        ),
                        child: const Text('保存凭证',
                            style:
                                TextStyle(color: Colors.white, fontSize: 16)),
                      ),
                    ),
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
                _configured ? '凭证已配置' : '未配置凭证',
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
          Text(
            'UserID：${_configured ? AppConstants.maskToken(_credential.userId) : '—'}',
            style: TextStyle(fontSize: 13 * s, color: Colors.black54),
          ),
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
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10 * s),
                  border: Border.all(color: const Color(0xFFE53935)),
                ),
                child: const Text('清除凭证',
                    style: TextStyle(color: Color(0xFFE53935), fontSize: 15)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

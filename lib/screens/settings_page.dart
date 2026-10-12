import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/kugou_platform.dart';
import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/kugou_credential_service.dart';
import '../services/notification_lyric_service.dart';
import '../services/sources/source_manager.dart';
import '../utils/app_constants.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';
import 'about_page.dart';
import 'kugou_credential_page.dart';

/// 设置页面
/// 布局参考 cankao/1.txt 设计稿（430x932）：
/// 白色导航栏 + "播放设置"分组（与其他应用同时播放开关）+ "其他"分组（清理缓存/关于）
class SettingsPage extends StatefulWidget {
  final Future<void> Function()? onLogout;

  const SettingsPage({super.key, this.onLogout});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _allowMixWithOthers = false;
  bool _notifyLyric = AppConstants.defaultNotifyLyricEnabled;

  // 音源相关
  SongSource _source = SongSource.netease;
  bool _fallback = AppConstants.defaultKugouFallbackEnabled;
  bool _kugouConfigured = false;

  @override
  void initState() {
    super.initState();
    _loadMixSetting();
    _loadLyricSetting();
    _loadSourceSetting();
  }

  void _loadSourceSetting() {
    final manager = SourceManager();
    _source = manager.currentSource;
    _fallback = manager.fallbackEnabled;
    _kugouConfigured = KugouCredentialService.instance.hasCredentials;
  }

  /// 音源选择：未配置酷狗凭证时先引导配置（REQ-07 边界）
  Future<void> _selectSource() async {
    final selected = await showDialog<SongSource>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择音源'),
        children: [
          for (final kind in SongSource.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, kind),
              child: Row(
                children: [
                  Icon(
                    kind == _source
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: kind == _source
                        ? const Color(0xFF2F84FE)
                        : const Color(0xFFC4C4C4),
                  ),
                  const SizedBox(width: 12),
                  Text(kind.label,
                      style: const TextStyle(fontSize: 15, color: Colors.black)),
                ],
              ),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (selected == null || selected == _source) return;

    // 酷狗家族（概念版 / 原版）按平台校验凭证
    final platform = selected.kugouPlatform;
    if (platform != null &&
        !KugouCredentialService.instance.hasCredentialsFor(platform)) {
      DesignToast.show(context, '请先配置${selected.label}凭证');
      await _openCredentialPage(platform);
      if (!mounted) return;
      if (!KugouCredentialService.instance.hasCredentialsFor(platform)) return;
    }

    await SourceManager().switchTo(selected);
    if (!mounted) return;
    setState(() => _source = selected);
    DesignToast.show(context, '已切换音源：${selected.label}');
  }

  Future<void> _toggleFallback(bool value) async {
    setState(() => _fallback = value);
    await SourceManager().setFallbackEnabled(value);
  }

  Future<void> _openCredentialPage([KugouPlatform? platform]) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => KugouCredentialPage(
          platform: platform ?? KugouPlatform.lite,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      _kugouConfigured = KugouCredentialService.instance.hasCredentials;
    });
    // 清除凭证后若当前为酷狗，自动回退网易云
    final cur = _source.kugouPlatform;
    if (cur != null &&
        !KugouCredentialService.instance.hasCredentialsFor(cur)) {
      await SourceManager().switchTo(SongSource.netease);
      if (mounted) setState(() => _source = SourceManager().currentSource);
    }
  }

  Future<void> _loadMixSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _allowMixWithOthers =
            prefs.getBool(AppConstants.allowMixWithOthers) ?? false;
      });
    } catch (_) {}
  }

  Future<void> _loadLyricSetting() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _notifyLyric = prefs.getBool(AppConstants.notifyLyricEnabled) ??
            AppConstants.defaultNotifyLyricEnabled;
      });
    } catch (_) {}
  }

  /// 切换「通知栏/灵动岛歌词」：只改内存标志 + 写 prefs，不打断播放
  void _toggleNotifyLyric(bool value) {
    setState(() => _notifyLyric = value);
    NotificationLyricService.instance.setEnabled(value);
  }

  Future<void> _toggleMix(bool value) async {
    setState(() => _allowMixWithOthers = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(AppConstants.allowMixWithOthers, value);
    } catch (_) {}
    await AudioPlayerService.applyMixWithOthers(value);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final s = Responsive.uiScale(size); // 设计稿等比缩放系数（夹取 [0.7,1.15]）
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      body: Column(
        children: [
          // 白色导航栏：返回 + 居中标题
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
                          const Icon(
                            Icons.arrow_back_ios_new,
                            size: 20,
                            color: Colors.black,
                          ),
                          SizedBox(width: 8 * s - 3), // 返回文字左移 3px
                          Text(
                            '返回',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 14 * s, // 12 + 2
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      '设置',
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
            child: SingleChildScrollView(
              // 卡片左右距屏幕各 15px
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 严格按设计稿纵向坐标（430x932）：导航栏底 49 → 标题 66 间距 17
                  SizedBox(height: 17 * s),
                  _buildSectionHeader('播放设置', s),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: () => _toggleMix(!_allowMixWithOthers),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '与其他应用同时播放',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 16 * s,
                            ),
                          ),
                        ),
                        _buildSwitch(s, _allowMixWithOthers,
                            () => _toggleMix(!_allowMixWithOthers)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: () => _toggleNotifyLyric(!_notifyLyric),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '通知栏 / 灵动岛显示歌词',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16 * s,
                                ),
                              ),
                              SizedBox(height: 2 * s),
                              Text(
                                '需系统通知权限；关闭后仅显示歌名/歌手',
                                style: TextStyle(
                                  color: const Color(0xFF838383),
                                  fontSize: 11 * s,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildSwitch(s, _notifyLyric,
                            () => _toggleNotifyLyric(!_notifyLyric)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildSectionHeader('音源', s),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: _selectSource,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '当前音源',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 16 * s,
                            ),
                          ),
                        ),
                        Text(
                          _source.label,
                          style: TextStyle(
                            color: const Color(0xFF2F84FE),
                            fontSize: 15 * s,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right,
                            size: 20, color: Color(0xFFCCCCCC)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: () => _toggleFallback(!_fallback),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '失败自动回退网易云',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16 * s,
                                ),
                              ),
                              SizedBox(height: 2 * s),
                              Text(
                                '酷狗请求失败时自动改用网易云取源',
                                style: TextStyle(
                                  color: const Color(0xFF838383),
                                  fontSize: 11 * s,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildSwitch(s, _fallback,
                            () => _toggleFallback(!_fallback)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: _openCredentialPage,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '酷狗概念版凭证',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16 * s,
                                ),
                              ),
                              SizedBox(height: 2 * s),
                              Text(
                                '支持扫码登录 / 粘贴凭证',
                                style: TextStyle(
                                  color: const Color(0xFF838383),
                                  fontSize: 11 * s,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          _kugouConfigured ? '已配置' : '未配置',
                          style: TextStyle(
                            color: _kugouConfigured
                                ? const Color(0xFF2F84FE)
                                : const Color(0xFF838383),
                            fontSize: 14 * s,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right,
                            size: 20, color: Color(0xFFCCCCCC)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildSectionHeader('其他', s),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: _showClearCacheDialog,
                    child: Text(
                      '清理缓存',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16 * s,
                      ),
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (context) => const AboutPage()),
                      );
                    },
                    child: Text(
                      '关于 Such Music',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16 * s,
                      ),
                    ),
                  ),
                  // 退出登录（仅登录状态显示）
                  if (widget.onLogout != null) ...[
                    SizedBox(height: 26 * s),
                    _buildCard(
                      s: s,
                      onTap: _showLogoutDialog,
                      child: const Center(
                        child: Text(
                          '退出登录',
                          style: TextStyle(
                            color: Color(0xFFE53935),
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组标题：设计稿中为 20 高的文本块（如 66→86）
  Widget _buildSectionHeader(String title, double s) {
    return SizedBox(
      height: 20 * s,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          title,
          style: TextStyle(
            color: const Color(0xFF838383),
            fontSize: 15.5 * s,
          ),
        ),
      ),
    );
  }

  /// 白色圆角条目卡片（设计稿 388x44 圆角 10，卡片高度 52px）
  Widget _buildCard({
    required double s,
    required Widget child,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        height: 52,
        padding: EdgeInsets.symmetric(horizontal: 9 * s),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10 * s),
        ),
        alignment: Alignment.centerLeft,
        child: child,
      ),
    );
  }

  /// 设计稿样式开关：灰色轨道白色圆钮（关）/ 主题蓝轨道右侧圆钮（开）
  Widget _buildSwitch(double s, bool value, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: 53 * s + 6, // 整体缩小 2px：59x31
        height: 25 * s + 6,
        padding: EdgeInsets.all(4 * s), // 内边距 1 + 1 + 2
        decoration: BoxDecoration(
          color: value ? const Color(0xFF2F84FE) : const Color(0xFFC4C4C4),
          borderRadius: BorderRadius.circular(84),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 23 * s, // 圆钮随轨道缩小 2px
            height: 23 * s,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }

  /// 清理缓存：确认后清理并提示结果（条数 + 释放空间）
  void _showClearCacheDialog() {
    DesignDialog.showConfirm(
      context,
      titleText: '确认清除',
      contentText: '确定要清除所有缓存数据吗？',
      onConfirm: () async {
        final (count, bytes) = await AudioPlayerService.clearCoverCache();
        if (!context.mounted) return;
        final sizeText = bytes >= 1024 * 1024
            ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(bytes / 1024).toStringAsFixed(0)} KB';
        DesignToast.show(
          context,
          bytes > 0 ? '已清理 $count 项缓存，释放 $sizeText' : '暂无缓存需要清理',
        );
      },
    );
  }

  void _showLogoutDialog() {
    DesignDialog.showConfirm(
      context,
      titleText: '退出登录',
      contentText: '确定要退出登录吗？',
      onConfirm: () {
        widget.onLogout?.call();
        Navigator.pop(context);
      },
    );
  }
}

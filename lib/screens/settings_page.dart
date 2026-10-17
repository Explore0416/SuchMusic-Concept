import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/kugou_platform.dart';
import '../models/song_model.dart';
import '../services/audio_player_service.dart';
import '../services/crash_log_service.dart';
import '../services/kugou_credential_service.dart';
import '../services/notification_lyric_service.dart';
import '../services/settings_backup_service.dart';
import '../services/play_history_service.dart';
import '../services/sources/source_manager.dart';
import '../utils/app_constants.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';
import 'about_page.dart';
import 'band_page.dart';
import '../widgets/kugou_login_dialog.dart';
import '../widgets/sound_effect_sheet.dart';

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
    _kugouConfigured = _anyKugouConfigured();
  }

  /// 任意酷狗平台（概念版 / 原版）是否已登录。
  bool _anyKugouConfigured() {
    final credential = KugouCredentialService.instance;
    return KugouPlatform.values.any(credential.hasCredentialsFor);
  }

  /// 音源选择：未配置酷狗凭证时先引导配置（REQ-07 边界）
  Future<void> _selectSource() async {
    final selected = await showDialog<SongSource>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择音源'),
        children: [
          for (final kind in SongSource.selectable)
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
      await _manageKugouAccount(platform);
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

  /// 打开酷狗扫码登录弹窗（与网易云登录 UI 形态一致）。
  Future<void> _openKugouLogin(KugouPlatform platform) async {
    await showKugouLoginDialog(context, platform: platform);
    if (!mounted) return;
    setState(() {
      _kugouConfigured = _anyKugouConfigured();
    });
    // 若当前音源的酷狗凭证已失效（如被清除），自动回退网易云
    final cur = _source.kugouPlatform;
    if (cur != null &&
        !KugouCredentialService.instance.hasCredentialsFor(cur)) {
      await SourceManager().switchTo(SongSource.netease);
      if (mounted) setState(() => _source = SourceManager().currentSource);
    }
  }

  /// 酷狗账号管理：未登录直接拉起扫码弹窗；已登录提供「重新登录 / 退出登录」。
  Future<void> _manageKugouAccount(KugouPlatform platform) async {
    final credential = KugouCredentialService.instance;
    if (!credential.hasCredentialsFor(platform)) {
      return _openKugouLogin(platform);
    }
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('${platform.label}账号'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'relogin'),
            child: const Text('重新扫码登录'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'logout'),
            child: const Text('退出登录'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'relogin') {
      await _openKugouLogin(platform);
      return;
    }
    await credential.clearFor(platform);
    if (!mounted) return;
    setState(() => _kugouConfigured = _anyKugouConfigured());
    if (_source.kugouPlatform == platform) {
      await SourceManager().switchTo(SongSource.netease);
      if (mounted) setState(() => _source = SourceManager().currentSource);
    }
    if (mounted) DesignToast.show(context, '已退出登录');
  }

  // ── 音效 / 配置备份 ──────────────────────────────────────

  Future<void> _openSoundEffect() async {
    // 面板返回值为「预设 code / off / null」，而设置页并不展示当前音效，
    // 因此**无需**为返回值重建整页。原实现无条件 `setState(() {})` 是一次多余的
    // 全页重建，且其触发时刻恰好与历史上「关闭面板后整屏灰屏」重合，已移除。
    // 若日后需要在设置页展示当前音效，请在此按返回值按需刷新。
    await showSoundEffectSheet(context);
  }

  /// 手环：进入绑定与音乐控制设置页。
  void _openBand() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const BandPage()),
    );
  }

  /// 只读查看最近全局异常日志（仅本机存储，绝不上传）。
  Future<void> _openErrorLog() async {
    final raw = await CrashLogService.instance.readAll();
    if (!mounted) return;
    final content = raw.trim().isEmpty ? '暂无异常记录' : raw.trim();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('错误日志（只读）'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: const TextStyle(fontSize: 11, height: 1.4),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              Navigator.of(ctx).pop();
              if (mounted) DesignToast.show(context, '已复制错误日志');
            },
            child: const Text('复制'),
          ),
        ],
      ),
    );
  }

  Future<void> _openBackupDialog() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('配置备份'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'export'),
            child: const Text('导出配置到文件'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'import'),
            child: const Text('从内容导入配置'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'export') {
      await _exportSettings();
    } else {
      await _importSettings();
    }
  }

  /// 导出：写成 JSON 文件到应用文档目录并尝试用系统方式打开。
  Future<void> _exportSettings() async {
    try {
      final json = await SettingsBackupService().exportToJson();
      final name = await SettingsBackupService().defaultExportFileName();
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsString(json);
      await OpenFilex.open(file.path);
      if (!mounted) return;
      DesignToast.show(context, '已导出配置：${file.path}');
    } catch (e) {
      if (mounted) DesignToast.show(context, '导出失败：$e');
    }
  }

  /// 导入：粘贴此前导出的 JSON 恢复（不含登录凭证，凭证需重新登录）。
  Future<void> _importSettings() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入配置'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: '粘贴此前导出的配置 JSON 内容',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (raw == null || !mounted) return;
    try {
      final n = await SettingsBackupService().importFromJson(raw);
      if (!mounted) return;
      DesignToast.show(context, '已恢复 $n 项配置');
      setState(_loadSourceSetting);
    } on FormatException catch (e) {
      if (mounted) DesignToast.show(context, '配置格式不正确：${e.message}');
    } catch (e) {
      if (mounted) DesignToast.show(context, '导入失败：$e');
    }
  }

  /// 设置页「酷狗账号」入口：先选平台，再进入扫码 / 管理。
  Future<void> _openKugouAccountPicker() async {
    final credential = KugouCredentialService.instance;
    final platform = await showDialog<KugouPlatform>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('酷狗账号'),
        children: [
          for (final p in KugouPlatform.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(
                credential.hasCredentialsFor(p) ? '${p.label}（已登录）' : p.label,
              ),
            ),
        ],
      ),
    );
    if (!mounted || platform == null) return;
    await _manageKugouAccount(platform);
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
                    onTap: _openKugouAccountPicker,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '酷狗账号',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16 * s,
                                ),
                              ),
                              SizedBox(height: 2 * s),
                              Text(
                                '扫码登录（与网易云一致），可粘贴凭证兜底',
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
                  _buildCard(
                    s: s,
                    onTap: _openSoundEffect,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('音效',
                                  style: TextStyle(
                                      color: Colors.black, fontSize: 16 * s)),
                              SizedBox(height: 2 * s),
                              Text('均衡器预设：流行 / 人声 / 重低音 / 环绕',
                                  style: TextStyle(
                                      color: const Color(0xFF838383),
                                      fontSize: 11 * s)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 20, color: Color(0xFFCCCCCC)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: _openBand,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('手环',
                                  style: TextStyle(
                                      color: Colors.black, fontSize: 16 * s)),
                              SizedBox(height: 2 * s),
                              Text('小米手环：绑定与音乐控制（仅本机链路）',
                                  style: TextStyle(
                                      color: const Color(0xFF838383),
                                      fontSize: 11 * s)),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 20, color: Color(0xFFCCCCCC)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: _openBackupDialog,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('配置备份',
                                  style: TextStyle(
                                      color: Colors.black, fontSize: 16 * s)),
                              SizedBox(height: 2 * s),
                              Text('导出个性化设置，清除数据后可导入恢复',
                                  style: TextStyle(
                                      color: const Color(0xFF838383),
                                      fontSize: 11 * s)),
                            ],
                          ),
                        ),
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
                    onTap: () => _showStorageCleanupSheet(s),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '清理数据',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16 * s,
                                ),
                              ),
                              SizedBox(height: 2 * s),
                              Text(
                                '缓存 / 播放历史与推荐数据（均仅存本机）',
                                style: TextStyle(
                                  color: const Color(0xFF838383),
                                  fontSize: 11 * s,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 20, color: Color(0xFFCCCCCC)),
                      ],
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
                      '关于 SuchMusic概念版',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 16 * s,
                      ),
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _buildCard(
                    s: s,
                    onTap: _openErrorLog,
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '错误日志',
                                style: TextStyle(
                                  color: Colors.black,
                                  fontSize: 16 * s,
                                ),
                              ),
                              SizedBox(height: 2 * s),
                              Text(
                                '查看最近异常记录（仅本机，不上传）',
                                style: TextStyle(
                                  color: const Color(0xFF838383),
                                  fontSize: 11 * s,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right,
                            size: 20, color: Color(0xFFCCCCCC)),
                      ],
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

  /// 统一清理入口：把原先并列的「清理缓存」「清除本地推荐数据」两张卡片合并为一项，
  /// 避免同一分组里出现两个语义相近的清除操作。面板内再分两条，各自沿用原有确认流程。
  void _showStorageCleanupSheet(double s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36 * s,
              height: 4 * s,
              margin: EdgeInsets.only(top: 10 * s, bottom: 12 * s),
              decoration: BoxDecoration(
                color: const Color(0xFFE5E5E5),
                borderRadius: BorderRadius.circular(2 * s),
              ),
            ),
            Text('清理数据',
                style: TextStyle(
                    fontSize: 17 * s, fontWeight: FontWeight.w600)),
            SizedBox(height: 4 * s),
            Text('以下数据均仅保存在本机，清理后不可恢复',
                style: TextStyle(
                    fontSize: 11 * s, color: const Color(0xFF838383))),
            SizedBox(height: 8 * s),
            _cleanupRow(s, '清理缓存', '封面等临时文件，不影响使用记录', () {
              Navigator.pop(ctx);
              _showClearCacheDialog();
            }),
            _cleanupRow(s, '清除本地推荐数据', '播放历史、时段分布、曲风推断结果', () {
              Navigator.pop(ctx);
              _showClearRecommendationDialog();
            }),
            SizedBox(height: 12 * s),
          ],
        ),
      ),
    );
  }

  Widget _cleanupRow(
      double s, String title, String subtitle, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 20 * s, vertical: 12 * s),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 15 * s, color: Colors.black)),
                  SizedBox(height: 2 * s),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11 * s, color: const Color(0xFF838383))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                size: 18, color: Color(0xFFCCCCCC)),
          ],
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

  /// 清除本地推荐数据：播放历史 + 曲风档案 + 来源上下文（**仅本机、不上传**）。
  void _showClearRecommendationDialog() {
    DesignDialog.showConfirm(
      context,
      titleText: '确认清除',
      contentText: '确定要清除本地推荐数据吗？\n（含播放历史、时段分布、完成度/跳过、曲风推断结果，'
          '仅保存在本机，清除后不可恢复）',
      onConfirm: () async {
        await PlayHistoryService().clear();
        if (!mounted) return;
        DesignToast.show(context, '已清除本地推荐数据');
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

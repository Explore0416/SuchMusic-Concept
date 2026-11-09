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
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/app_ui.dart';
import '../services/karaoke_service.dart';
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
                  // 单选选中态：唯一的彩色出现在这里，其余一律墨阶
                  Icon(
                    kind == _source
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: kind == _source
                        ? AppColors.brand
                        : AppColors.inkDisabled,
                  ),
                  const SizedBox(width: 12),
                  Text(kind.label, style: AppType.body),
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
              style: const TextStyle(fontSize: 12, height: 1.4),
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
          decoration: const InputDecoration(hintText: '粘贴此前导出的配置 JSON 内容'),
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
        _notifyLyric =
            prefs.getBool(AppConstants.notifyLyricEnabled) ??
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
  // ─────────────────────────── 页面骨架 ───────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        bottom: false,
        child: ResponsiveContent(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: AppSpace.xxxl),
                  children: [
                    _buildGroupLabel('播放', first: true),
                    _buildGroup(
                      children: [
                        _switchRow(
                          icon: Icons.graphic_eq_rounded,
                          title: '与其他应用同时播放',
                          value: _allowMixWithOthers,
                          onChanged: _toggleMix,
                        ),
                        _switchRow(
                          icon: Icons.notifications_active_rounded,
                          title: '通知栏 / 灵动岛显示歌词',
                          value: _notifyLyric,
                          onChanged: _toggleNotifyLyric,
                        ),
                      ],
                    ),
                    _buildGroupLabel('音源'),
                    _buildGroup(
                      children: [
                        AppListTile(
                          icon: Icons.swap_horiz_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '当前音源',
                          trailing: AppTag(
                            text: _source.label,
                            color: AppColors.brand,
                            background: AppColors.brandSoft,
                          ),
                          onTap: _selectSource,
                        ),
                        _switchRow(
                          icon: Icons.cloud_sync_rounded,
                          title: '失败自动回退网易云',
                          value: _fallback,
                          onChanged: _toggleFallback,
                        ),
                        // 「已登录 / 未登录」是状态，但登录态不是「成功 / 失败」，
                        // 用墨阶表达就够，避免整页多出一种绿色。
                        AppListTile(
                          icon: Icons.person_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '酷狗账号',
                          trailing: AppTag(
                            text: _kugouConfigured ? '已登录' : '未登录',
                            color: _kugouConfigured
                                ? AppColors.ink
                                : AppColors.inkTertiary,
                            background: AppColors.surfaceMuted,
                          ),
                          onTap: _openKugouAccountPicker,
                        ),
                        AppListTile(
                          icon: Icons.equalizer_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '音效',
                          onTap: _openSoundEffect,
                        ),
                        AppListTile(
                          icon: Icons.watch_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '手环',
                          onTap: _openBand,
                        ),
                      ],
                    ),
                    _buildGroupLabel('数据'),
                    _buildGroup(
                      children: [
                        AppListTile(
                          icon: Icons.save_alt_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '配置备份',
                          onTap: _openBackupDialog,
                        ),
                        AppListTile(
                          icon: Icons.cleaning_services_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '清理数据',
                          onTap: _showStorageCleanupSheet,
                        ),
                        AppListTile(
                          icon: Icons.bug_report_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '错误日志',
                          onTap: _openErrorLog,
                        ),
                      ],
                    ),
                    _buildGroupLabel('关于'),
                    _buildGroup(
                      children: [
                        AppListTile(
                          icon: Icons.info_rounded,
                          iconBackground: AppColors.surfaceMuted,
                          iconColor: AppColors.inkSecondary,
                          dense: true,
                          title: '关于 SuchMusic 概念版',
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => const AboutPage(),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    if (widget.onLogout != null) ...[
                      const SizedBox(height: AppSpace.xxl),
                      _buildGroup(
                        children: [
                          AppListTile(
                            title: '退出登录',
                            icon: Icons.logout_rounded,
                            iconBackground: AppColors.surfaceMuted,
                            iconColor: AppColors.inkSecondary,
                            dense: true,
                            showChevron: false,
                            onTap: _showLogoutDialog,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶部条：返回 + 大标题（二级页不用居中导航栏，标题左对齐更好扫读）
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.sm,
        AppSpace.sm,
        AppSpace.page,
        AppSpace.xs,
      ),
      child: Row(
        children: [
          AppIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            iconSize: 18,
            tooltip: '返回',
            onTap: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: AppSpace.xs),
          const Text('设置', style: AppType.display),
        ],
      ),
    );
  }

  Widget _buildGroupLabel(String text, {bool first = false}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpace.page + 4,
        first ? AppSpace.sm : AppSpace.xxl,
        AppSpace.page,
        AppSpace.sm,
      ),
      child: Text(
        text,
        style: AppType.captionStrong.copyWith(
          color: AppColors.inkTertiary,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  /// 一张卡装一整组：行与行之间用发丝线分隔，不再是一行一张卡的碎片感
  Widget _buildGroup({required List<Widget> children}) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          const AppHairline(indent: AppSpace.lg, endIndent: AppSpace.lg),
        );
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }

  /// 开关行：整行可点，开关本体也可点，两条路径都能切换。
  ///
  /// 一行只有「图标 + 主文字 + 开关」：标题已经说清了功能，
  /// 再加一句解释只是把同一件事说两遍。
  Widget _switchRow({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return AppListTile(
      icon: icon,
      iconBackground: AppColors.surfaceMuted,
      iconColor: AppColors.inkSecondary,
      dense: true,
      title: title,
      showChevron: false,
      onTap: () => onChanged(!value),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: Colors.white,
      ),
    );
  }

  /// 统一清理入口：把原先并列的「清理缓存」「清除本地推荐数据」合并为一项，
  /// 避免同一分组里出现两个语义相近的清除操作。面板内再分两条，各自沿用原有确认流程。
  void _showStorageCleanupSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  AppSpace.page,
                  0,
                  AppSpace.page,
                  AppSpace.xs,
                ),
                child: Text('清理数据', style: AppType.title),
              ),
              // 高风险提示：清理不可恢复，这一句必须留（属于规则允许的三种情况之一）
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.page,
                  0,
                  AppSpace.page,
                  AppSpace.md,
                ),
                child: Text('以下数据都只存在本机，清理后不可恢复', style: AppType.caption),
              ),
              AppListTile(
                icon: Icons.image_rounded,
                iconBackground: AppColors.surfaceMuted,
                iconColor: AppColors.inkSecondary,
                dense: true,
                title: '清理缓存',
                onTap: () {
                  Navigator.pop(ctx);
                  _showClearCacheDialog();
                },
              ),
              const AppHairline(indent: AppSpace.lg, endIndent: AppSpace.lg),
              AppListTile(
                icon: Icons.insights_rounded,
                iconBackground: AppColors.surfaceMuted,
                iconColor: AppColors.inkSecondary,
                dense: true,
                title: '清除本地推荐数据',
                onTap: () {
                  Navigator.pop(ctx);
                  _showClearRecommendationDialog();
                },
              ),
            ],
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
        // 逐字歌词缓存（含临时音频/PCM 文件）一并清理
        final karaokeCount = await KaraokeService.clearCache();
        final total = count + karaokeCount;
        if (!mounted) return;
        final sizeText = bytes >= 1024 * 1024
            ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(bytes / 1024).toStringAsFixed(0)} KB';
        DesignToast.show(
          context,
          total > 0 ? '已清理 $total 项缓存，释放 $sizeText' : '暂无缓存需要清理',
        );
      },
    );
  }

  /// 清除本地推荐数据：播放历史 + 曲风档案 + 来源上下文（**仅本机、不上传**）。
  void _showClearRecommendationDialog() {
    DesignDialog.showConfirm(
      context,
      titleText: '确认清除',
      contentText:
          '确定要清除本地推荐数据吗？\n（含播放历史、时段分布、完成度/跳过、曲风推断结果，'
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

import 'package:flutter/material.dart';

import '../models/third_party_auth.dart';
import '../services/third_party/client_registry.dart';
import '../services/third_party/third_party_auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/design_dialog.dart';

/// 撤销单个应用的二次确认按钮（测试用）。
const String kThirdPartyRevokeConfirmLabel = '撤销授权';

/// 第三方授权管理页（ARCHITECTURE §6.7）。
///
/// 只做三件事：读 `ThirdPartyAuthService.listGrants()`、展示、调 `revoke` /
/// `revokeAll`。撤销判定与清理（code / loopback server / 日志）全在内核里完成，
/// 本页不重复实现（单一决策点原则，ARCH §5）。
class ThirdPartyAuthListPage extends StatefulWidget {
  const ThirdPartyAuthListPage({super.key, this.service, this.registry});

  /// 授权服务；为 null 时用全局单例。测试注入替身用。
  final ThirdPartyAuthService? service;

  /// 应用名查询用的注册表；为 null 时用内置注册表。
  final ClientRegistry? registry;

  @override
  State<ThirdPartyAuthListPage> createState() => _ThirdPartyAuthListPageState();
}

class _ThirdPartyAuthListPageState extends State<ThirdPartyAuthListPage> {
  late final ThirdPartyAuthService _service =
      widget.service ?? ThirdPartyAuthService.instance;
  late final ClientRegistry _registry =
      widget.registry ?? ClientRegistry.standard();

  List<ThirdPartyGrant> _grants = const <ThirdPartyGrant>[];

  /// 首帧前不渲染空态，避免「空态一闪再出列表」。
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final grants = await _service.listGrants();
    if (!mounted) return;
    final sorted = grants.toList()
      ..sort((a, b) => b.lastAccessAt.compareTo(a.lastAccessAt));
    setState(() {
      _grants = sorted;
      _loaded = true;
    });
  }

  /// 应用名：注册表展示名优先，取不到退回包名（列表不空留一行）。
  String _nameOf(ThirdPartyGrant grant) {
    final client = _registry.findById(grant.clientId);
    final name = (client?.displayName ?? '').trim();
    return name.isEmpty ? grant.packageName : name;
  }

  /// 已授权 scope 摘要，形如「曲风画像、歌曲直链」。
  String _scopeSummaryOf(ThirdPartyGrant grant) {
    final scopes = grant.scopes.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (scopes.isEmpty) return '未授予任何能力';
    return <String>[for (final scope in scopes) scope.label].join('、');
  }

  /// 最近访问时间：只到分钟，够辨认即可。
  String _lastAccessTextOf(ThirdPartyGrant grant) {
    if (grant.lastAccessAt <= 0) return '最近访问 未知';
    final time = DateTime.fromMillisecondsSinceEpoch(grant.lastAccessAt * 1000);
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '最近访问 ${time.month}月${time.day}日 $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.canvas,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: !_loaded
                  // 本地读取通常在 1 帧内完成，按规范不做骨架屏闪烁
                  ? const SizedBox.shrink()
                  : _grants.isEmpty
                      ? _buildEmpty()
                      : _buildList(),
            ),
            if (_loaded && _grants.isNotEmpty) _buildBottomBar(),
          ],
        ),
      ),
    );
  }

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
          const Expanded(child: Text('第三方授权', style: AppType.display)),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return const AppEmptyState(
      icon: Icons.verified_user_rounded,
      title: '还没有应用获得授权',
      message: '第三方应用拉起 SuchMusic 申请数据时会出现在这里',
    );
  }

  Widget _buildList() {
    final rows = <Widget>[];
    for (var i = 0; i < _grants.length; i++) {
      if (i > 0) {
        rows.add(const AppHairline(indent: AppSpace.lg, endIndent: AppSpace.lg));
      }
      rows.add(_buildTile(_grants[i]));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.sm,
        AppSpace.page,
        AppSpace.xxl,
      ),
      children: [
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(mainAxisSize: MainAxisSize.min, children: rows),
        ),
      ],
    );
  }

  /// 一行授权记录：应用名 / scope 摘要 / 最近访问时间 + 右侧「撤销」。
  Widget _buildTile(ThirdPartyGrant grant) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.sm,
        AppSpace.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _nameOf(grant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body,
                ),
                const SizedBox(height: 2),
                Text(
                  _scopeSummaryOf(grant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption,
                ),
                const SizedBox(height: 2),
                Text(
                  _lastAccessTextOf(grant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.caption.copyWith(color: AppColors.inkTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpace.sm),
          _TextAction(
            label: '撤销',
            onTap: () => _confirmRevoke(grant),
          ),
        ],
      ),
    );
  }

  /// 底部「全部撤销」：次级文字按钮，不做主色实心。
  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.sm),
        child: Center(
          child: _TextAction(label: '全部撤销', onTap: _confirmRevokeAll),
        ),
      ),
    );
  }

  void _confirmRevoke(ThirdPartyGrant grant) {
    final name = _nameOf(grant);
    DesignDialog.showConfirm(
      context,
      titleText: '撤销「$name」的授权',
      contentText: '撤销后该应用再次读取数据时需要你重新确认，已获取的数据不受影响。',
      confirmLabel: kThirdPartyRevokeConfirmLabel,
      onConfirm: () async {
        await _service.revoke(grant.clientId);
        await _load();
        if (!mounted) return;
        DesignToast.show(context, '已撤销');
      },
    );
  }

  void _confirmRevokeAll() {
    final count = _grants.length;
    if (count == 0) return;
    DesignDialog.showConfirm(
      context,
      titleText: '撤销全部授权',
      contentText: '将清除 $count 个应用的授权记录，它们再次读取数据时需要你重新确认。',
      confirmLabel: kThirdPartyRevokeConfirmLabel,
      onConfirm: () async {
        await _service.revokeAll();
        await _load();
        if (!mounted) return;
        DesignToast.show(context, '已全部撤销');
      },
    );
  }
}

/// 列表内文字按钮：15 号、墨阶次级色，热区高 44。
class _TextAction extends StatelessWidget {
  const _TextAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.row),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          child: Text(
            label,
            style: AppType.body.copyWith(color: AppColors.inkSecondary),
          ),
        ),
      ),
    );
  }
}

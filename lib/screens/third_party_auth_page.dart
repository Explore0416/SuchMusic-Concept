import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/third_party_auth.dart';
import '../services/third_party/third_party_bridge.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

/// 「拒绝」按钮容器（测试据此断言按钮底色不是主色实心）。
const Key thirdPartyAuthDenyKey = Key('third-party-auth-deny');

/// 「允许」按钮容器。
const Key thirdPartyAuthAllowKey = Key('third-party-auth-allow');

/// 已授权 scope 折叠行。
const Key thirdPartyAuthFoldKey = Key('third-party-auth-fold');

/// 敏感 scope（`account.token`）的额外警示文案。
///
/// 按设计规范 §5.3 与红线 3：说明文字不得用红 / 橙等彩色，这里用墨色常规字重。
const String kThirdPartyTokenWarning = '该令牌可代表你调用酷狗接口，请确认你信任此应用';

/// 第三方授权确认页（ARCHITECTURE §6.3 / 设计规范 §6.8）。
///
/// 责任边界：本页**只收集用户意愿**，`Navigator.pop(<bool>)` 把决定交回
/// `ThirdPartyAuthService`；落库、合并 scope、签发 code 全在内核里完成，
/// 页面不得自行放行（ARCH §5 单一决策点原则）。
///
/// 视觉约束（规范 §6.8）：「拒绝」「允许」同为次级样式，双方都不使用主色实心，
/// 不制造「同意」的视觉诱导；返回键等同「拒绝」。
class ThirdPartyAuthPage extends StatefulWidget {
  const ThirdPartyAuthPage({super.key, required this.request, this.bridge});

  /// 待确认的授权请求（由 `ThirdPartyAuthService` 产出）。
  final AuthRequest request;

  /// 取应用图标用的原生桥；为 null 时使用真实 MethodChannel 实现。
  ///
  /// 抽成参数只为让 Widget 测试注入假实现，避免单测触发 MethodChannel。
  final ThirdPartyBridge? bridge;

  @override
  State<ThirdPartyAuthPage> createState() => _ThirdPartyAuthPageState();
}

class _ThirdPartyAuthPageState extends State<ThirdPartyAuthPage> {
  /// 应用图标（PNG 字节）；为空时退回「首字 + surfaceMuted 底」。
  Uint8List? _icon;

  /// 「已授权的 N 项」是否展开。
  bool _foldExpanded = false;

  /// 是否已把决定交回上一页（防连点导致二次 pop）。
  bool _decided = false;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  Future<void> _loadIcon() async {
    try {
      final bridge = widget.bridge ?? MethodChannelThirdPartyBridge();
      final bytes = await bridge.getAppIcon(widget.request.packageName);
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) return;
      setState(() => _icon = bytes);
    } catch (e) {
      // 取不到图标不影响授权判断，静默退回首字占位
      debugPrint('[ThirdParty] 读取应用图标失败: ${e.runtimeType}');
    }
  }

  /// 交回用户决定。[allow] 为 false 即「拒绝」（返回键同此路径）。
  void _decide(bool allow) {
    if (_decided || !mounted) return;
    _decided = true;
    Navigator.of(context).pop(allow);
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final visible = _visibleScopes(request);
    final folded = _foldedScopes(request);
    return PopScope(
      // 授权页不可通过返回键跳过：返回 = 拒绝（ARCH §6.3）
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _decide(false);
      },
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpace.page,
                    AppSpace.xxxl,
                    AppSpace.page,
                    AppSpace.xxl,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(child: _buildAppAvatar(request)),
                      const SizedBox(height: AppSpace.lg),
                      Center(
                        child: Text(
                          request.displayName,
                          textAlign: TextAlign.center,
                          style: AppType.title.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpace.xs),
                      Center(
                        child: Text(
                          request.packageName,
                          textAlign: TextAlign.center,
                          style: AppType.caption.copyWith(
                            color: AppColors.inkTertiary,
                          ),
                        ),
                      ),
                      if (request.signaturePrefix.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Center(
                          child: Text(
                            '签名 ${request.signaturePrefix}',
                            textAlign: TextAlign.center,
                            style: AppType.caption.copyWith(
                              color: AppColors.inkTertiary,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpace.xxl),
                      Text(
                        '申请访问以下内容',
                        style: AppType.body.copyWith(
                          color: AppColors.inkSecondary,
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      _buildScopeCard(visible, folded),
                    ],
                  ),
                ),
              ),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// 需要展开详述的 scope：本次新增的，以及所有敏感 scope
  /// （`account.token` 每次都必须完整呈现，ARCH T5 / §6.6）。
  List<ThirdPartyScope> _visibleScopes(AuthRequest request) => <ThirdPartyScope>[
        for (final scope in request.scopes)
          if (!request.alreadyGranted.contains(scope) ||
              ThirdPartyScope.sensitiveScopes.contains(scope))
            scope,
      ];

  /// 折叠展示的 scope：已授权、本次未新增且不敏感的部分。
  List<ThirdPartyScope> _foldedScopes(AuthRequest request) => <ThirdPartyScope>[
        for (final scope in request.scopes)
          if (request.alreadyGranted.contains(scope) &&
              !ThirdPartyScope.sensitiveScopes.contains(scope))
            scope,
      ];

  /// 应用图标：64×64、圆角 16；图标取不到时用首字占位。
  Widget _buildAppAvatar(AuthRequest request) {
    final icon = _icon;
    final child = icon != null
        ? Image.memory(
            icon,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          )
        : Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            color: AppColors.surfaceMuted,
            child: Text(_initialOf(request.displayName), style: AppType.title),
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(width: 64, height: 64, child: child),
    );
  }

  /// 应用名首字（空名退回「?」，避免渲染空白方块）。
  String _initialOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    // 用 runes 取首个码位，避免把 emoji / 代理对截成半个字符
    return String.fromCharCode(trimmed.runes.first);
  }

  Widget _buildScopeCard(
    List<ThirdPartyScope> visible,
    List<ThirdPartyScope> folded,
  ) {
    final rows = <Widget>[];
    for (var i = 0; i < visible.length; i++) {
      if (i > 0) {
        rows.add(const AppHairline(indent: AppSpace.lg, endIndent: AppSpace.lg));
      }
      rows.add(_ScopeTile(scope: visible[i]));
    }
    if (folded.isNotEmpty) {
      if (rows.isNotEmpty) {
        rows.add(const AppHairline(indent: AppSpace.lg, endIndent: AppSpace.lg));
      }
      rows.add(_buildFoldRow(folded));
      if (_foldExpanded) {
        for (final scope in folded) {
          rows.add(
            const AppHairline(indent: AppSpace.lg, endIndent: AppSpace.lg),
          );
          rows.add(_ScopeTile(scope: scope, compact: true));
        }
      }
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: rows),
    );
  }

  /// 「已授权的 N 项」折叠行：整行可点，热区高 48。
  Widget _buildFoldRow(List<ThirdPartyScope> folded) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: thirdPartyAuthFoldKey,
        onTap: () => setState(() => _foldExpanded = !_foldExpanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: 14,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已授权的 ${folded.length} 项',
                  style: AppType.body.copyWith(color: AppColors.inkSecondary),
                ),
              ),
              Icon(
                _foldExpanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 20,
                color: AppColors.inkTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部固定区：两个按钮并排、各占一半，均为次级样式。
  Widget _buildBottomBar() {
    return Container(
      color: AppColors.canvas,
      padding: const EdgeInsets.fromLTRB(
        AppSpace.page,
        AppSpace.md,
        AppSpace.page,
        AppSpace.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: _AuthButton(
                  buttonKey: thirdPartyAuthDenyKey,
                  label: '拒绝',
                  background: AppColors.surfaceMuted,
                  outline: false,
                  onTap: () => _decide(false),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: _AuthButton(
                  buttonKey: thirdPartyAuthAllowKey,
                  label: '允许',
                  background: AppColors.surface,
                  outline: true,
                  onTap: () => _decide(true),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            '授权后可随时在 设置 → 第三方授权 中撤销',
            textAlign: TextAlign.center,
            style: AppType.caption.copyWith(color: AppColors.inkTertiary),
          ),
        ],
      ),
    );
  }
}

/// 单个 scope 条目：40×40 浅底图标块 + 标题 + 一句说明。
///
/// [compact] 供「已授权」折叠区使用：只改次要文字色，不新增字号。
class _ScopeTile extends StatelessWidget {
  const _ScopeTile({required this.scope, this.compact = false});

  final ThirdPartyScope scope;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final sensitive = ThirdPartyScope.sensitiveScopes.contains(scope);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(scope.icon, size: 20, color: AppColors.inkSecondary),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        scope.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.body.copyWith(
                          color: compact ? AppColors.inkSecondary : AppColors.ink,
                        ),
                      ),
                    ),
                    if (sensitive) ...[
                      const SizedBox(width: AppSpace.sm),
                      const AppTag(text: '敏感'),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpace.xs),
                Text(scope.description, style: AppType.caption),
                if (sensitive) ...[
                  const SizedBox(height: AppSpace.sm),
                  // 规范禁止用彩色说明文字：这里用墨色常规字重，靠文案表达风险
                  Text(
                    kThirdPartyTokenWarning,
                    style: AppType.caption.copyWith(
                      color: AppColors.ink,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 授权页按钮：高 48、圆角 14，两种形态都不使用主色实心（规范 §6.8）。
class _AuthButton extends StatelessWidget {
  const _AuthButton({
    required this.buttonKey,
    required this.label,
    required this.background,
    required this.outline,
    required this.onTap,
  });

  final Key buttonKey;
  final String label;
  final Color background;
  final bool outline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 底色画在 Container 上、水波画在它内部的 Material 上：
    // 若把底色交给 Material 的 ink 层，页面画布色（Container）会把它盖住。
    return Container(
      key: buttonKey,
      height: 48,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.row),
        border: outline ? Border.all(color: AppColors.hairline, width: 0.7) : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.row),
          child: Center(
            child: Text(
              label,
              style: AppType.body.copyWith(
                color: AppColors.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

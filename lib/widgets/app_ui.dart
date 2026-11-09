import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 发丝分割线：0.7px 暖灰，替代 1px 深灰硬线。
class AppHairline extends StatelessWidget {
  const AppHairline({super.key, this.indent = 0, this.endIndent = 0});

  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent, right: endIndent),
      child: const SizedBox(
        height: 0.7,
        width: double.infinity,
        child: ColoredBox(color: AppColors.hairline),
      ),
    );
  }
}

/// 区块标题：标题 + 可选右侧文字操作（不使用隐藏手势承载唯一入口）。
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpace.page,
      0,
      AppSpace.page,
      AppSpace.md,
    ),
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppType.title),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: AppType.caption),
                ],
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            _TextAction(label: actionLabel!, onTap: onAction!),
        ],
      ),
    );
  }
}

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
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppType.captionStrong.copyWith(color: AppColors.brand),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: AppColors.brand,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 44×44 图标按钮：满足移动端最小触控热区，图标视觉尺寸 22。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 44,
    this.iconSize = 22,
    this.filled = false,
    this.background,
    this.foreground,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;
  final double size;
  final double iconSize;

  /// 是否带圆形底色（用于搜索等次级入口）
  final bool filled;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: filled ? (background ?? AppColors.surface) : Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Icon(
            icon,
            size: iconSize,
            color: onTap == null
                ? AppColors.inkDisabled
                : (foreground ?? AppColors.ink),
          ),
        ),
      ),
    );
    if (filled) {
      return Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.hairline, width: 0.7),
        ),
        child: button,
      );
    }
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 白色卡面：发丝描边 + 20 圆角，不用重阴影。
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = AppRadius.card,
    this.color = AppColors.surface,
    this.border = true,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color color;
  final bool border;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: border
            ? Border.all(color: AppColors.hairline, width: 0.7)
            : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius - (border ? 0.35 : 0)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
    return card;
  }
}

/// 语义标签：浅底深字，必须带文案，不靠颜色单独表意。
class AppTag extends StatelessWidget {
  const AppTag({
    super.key,
    required this.text,
    this.color = AppColors.inkSecondary,
    this.background = AppColors.surfaceMuted,
    this.icon,
  });

  final String text;
  final Color color;
  final Color background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用列表行：左图标块 / 标题 / 副标题 / 右侧箭头。
class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor = AppColors.brand,
    this.iconBackground = AppColors.brandSoft,
    this.leading,
    this.trailing,
    this.showChevron = true,
    this.onTap,
    this.padding,
    this.dense = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color iconColor;
  final Color iconBackground;
  final Widget? leading;
  final Widget? trailing;
  final bool showChevron;
  final VoidCallback? onTap;

  /// 行内边距；为 null 时按 [dense] 取默认值（常规 14 / 紧凑 10）
  final EdgeInsetsGeometry? padding;

  /// 紧凑模式：图标块 38 → 32、竖向边距 14 → 10（行高 66 → 52）。
  ///
  /// 只给「设置」这类长列表页用：同样的屏高能多看到几项，
  /// 默认关闭，不影响其它页面的现有观感。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final iconSide = dense ? 32.0 : 38.0;
    final effectivePadding =
        padding ??
        EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: dense ? 10 : 14,
        );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: effectivePadding,
          child: Row(
            children: [
              if (leading != null)
                leading!
              else if (icon != null)
                Container(
                  width: iconSide,
                  height: iconSide,
                  decoration: BoxDecoration(
                    color: iconBackground,
                    borderRadius: BorderRadius.circular(dense ? 10 : 12),
                  ),
                  child: Icon(icon, size: dense ? 18 : 20, color: iconColor),
                ),
              if (leading != null || icon != null) const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.caption,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ] else if (showChevron) ...[
                const SizedBox(width: 4),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: AppColors.inkDisabled,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 空状态：说清为什么空 + 给一个出口。
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpace.xxl,
          vertical: compact ? AppSpace.xxl : AppSpace.xxxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: AppColors.surfaceMuted,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 24, color: AppColors.inkTertiary),
            ),
            const SizedBox(height: AppSpace.lg),
            Text(title, style: AppType.body, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: AppSpace.xs),
              Text(
                message!,
                style: AppType.caption,
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: AppSpace.lg),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 骨架占位：中性浅灰块，由宿主控制尺寸与扫光。
class AppSkeleton extends StatelessWidget {
  const AppSkeleton({
    super.key,
    required this.width,
    required this.height,
    this.radius = 8,
    this.color = const Color(0xFFEDEDE9),
  });

  final double width;
  final double height;
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// 页面大标题区：标题 + 说明 + 右侧操作，统一顶部留白。
class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpace.page,
      AppSpace.sm,
      AppSpace.sm,
      AppSpace.lg,
    ),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppType.display),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle!, style: AppType.caption),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

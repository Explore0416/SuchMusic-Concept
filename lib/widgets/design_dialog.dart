import 'dart:async';

import 'package:flutter/material.dart';

import '../utils/responsive.dart';

/// 设计稿风格弹窗组件（参照 cankao/1.txt，430 宽画布）
/// 白底圆角 15 卡片（宽 353/430 屏宽）、蓝色确认按钮（高 36、圆角 8、#3080FF、
/// 宽度随文字自适应）、取消为灰字文本（#8A8A8A）
/// 全 App 通用：更新弹窗、设置页确认弹窗等均使用本组件
class DesignDialog {
  DesignDialog._();

  static const Color confirmBlue = Color(0xFF3080FF); // 确认按钮蓝
  static const Color cancelGray = Color(0xFF8A8A8A); // 取消文字灰
  static const Color titleDark = Color(0xFF333333);
  static const Color contentGray = Color(0xFF666666);

  /// 设计稿比例：统一走响应式单一真源（夹取 [0.8, 1.0]）
  static double s(BuildContext context) =>
      Responsive.dialogScale(MediaQuery.of(context).size);

  /// 透明底 Dialog 包装（去掉默认灰白底和默认边距，卡片宽度按设计稿控制）
  static Widget shell(
    BuildContext context, {
    required Widget child,
  }) {
    final k = s(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: 38 * k, vertical: 24),
      child: child,
    );
  }

  /// 白底圆角卡片容器
  static Widget card(
    BuildContext context, {
    required List<Widget> children,
  }) {
    final k = s(context);
    // 卡片宽上限 400，避免超宽屏弹窗过宽
    final cardWidth = (353 * k).clamp(0.0, 400.0);
    return Container(
      width: cardWidth,
      padding: EdgeInsets.fromLTRB(24 * k, 26 * k, 24 * k, 18 * k),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15 * k),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  /// 弹窗标题
  static Widget title(BuildContext context, String text) {
    final k = s(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 18 * k,
        fontWeight: FontWeight.w600,
        color: titleDark,
        height: 1.3,
      ),
    );
  }

  /// 弹窗正文
  static Widget body(BuildContext context, String text) {
    final k = s(context);
    return Text(
      text,
      style: TextStyle(
        fontSize: 14.5 * k,
        color: contentGray,
        height: 1.6,
      ),
    );
  }

  /// 蓝底白字确认按钮（高 34、圆角 8、宽度随文字自适应）
  /// [enabled] 为 false 时置灰且不可点击
  static Widget confirmButton(
    BuildContext context,
    String text,
    VoidCallback? onTap, {
    bool enabled = true,
  }) {
    final k = s(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34 * k,
        padding: EdgeInsets.symmetric(horizontal: 17 * k),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? confirmBlue : const Color(0xFFB9D0F5),
          borderRadius: BorderRadius.circular(8 * k),
        ),
        child: Text(
          text,
          style: TextStyle(color: Colors.white, fontSize: 15.6 * k),
        ),
      ),
    );
  }

  /// 灰字取消按钮（设计稿为纯文本）
  static Widget cancelText(
    BuildContext context,
    String text,
    VoidCallback onTap,
  ) {
    final k = s(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 8 * k, vertical: 7 * k),
        child: Text(
          text,
          style: TextStyle(color: cancelGray, fontSize: 13.6 * k),
        ),
      ),
    );
  }

  /// 通用确认弹窗：标题 + 正文 + 右下角〔取消灰字〕〔确定蓝按钮〕
  /// 点空白区域不可关闭（与设计稿弹窗交互一致）
  static void showConfirm(
    BuildContext context, {
    required String titleText,
    required String contentText,
    String confirmLabel = '确定',
    String cancelLabel = '取消',
    bool showCancel = true,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final k = s(ctx);
        return shell(
          ctx,
          child: card(
            ctx,
            children: [
              DesignDialog.title(ctx, titleText),
              SizedBox(height: 12 * k),
              DesignDialog.body(ctx, contentText),
              SizedBox(height: 26 * k),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (showCancel) ...[
                    DesignDialog.cancelText(ctx, cancelLabel, () {
                      Navigator.of(ctx).pop();
                      onCancel?.call();
                    }),
                    SizedBox(width: 12 * k),
                  ],
                  DesignDialog.confirmButton(ctx, confirmLabel, () {
                    Navigator.of(ctx).pop();
                    onConfirm?.call();
                  }),
                ],
              ),
            ],
          ),
        );
    });
  }
}

/// 设计稿风格轻提示（参照 cankao/1.txt：白底黑字圆角提示条，屏幕居中偏下）
/// 宽 ≤ 屏宽 * 0.86、高 36、圆角 8、白底 + 轻投影、黑字 15.6 号，2 秒后自动消失。
///
/// **实现要点（健壮性，勿随意回退）**：
/// - 使用**单个可复用的 [OverlayEntry]**：任意时刻最多一条全屏 layer，新提示到来时
///   复用同一条目并复位 2 秒定时器，避免多条全屏 layer 叠加。
/// - 条目内容**绝不引用调用方的 `BuildContext`**，只使用条目自身的 context。
///   （历史教训：旧实现把调用方 context 闭包进 builder，调用方——如音效底部弹窗——
///   被销毁后，条目在随后任意一次根 Overlay 重建时仍会执行
///   `MediaQuery.of(已卸载 context)`，抛 `Null check operator used on a null value`，
///   在 release 下表现为**整屏灰框 RenderErrorBox（0xF0C0C0C0）并自动恢复**。）
/// - 移除操作**幂等**：定时器 / 手动关闭竞争、重复调用均安全。
/// - 整体 try/catch 兜底 —— 该根 Overlay 条目在任何情况下都不得成为异常源。
class DesignToast {
  DesignToast._();

  /// 复用的条目（任意时刻至多一条）
  static OverlayEntry? _entry;

  /// 受管定时器（新提示到来时取消旧的，避免旧定时器提前移除新提示）
  static Timer? _timer;

  /// 复用的数据载体：条目通过 [ValueListenableBuilder] 监听其变化并刷新内容。
  static final ValueNotifier<_ToastData?> _data =
      ValueNotifier<_ToastData?>(null);

  /// 显示一条轻提示（2 秒后自动消失；重复调用只刷新内容，不叠加）。
  static void show(BuildContext context, String text) {
    try {
      final overlay = Overlay.of(context, rootOverlay: true);
      // 调用方 context 此刻仍有效，仅取一次缩放系数（数字），不把 context 带进 builder。
      final k = DesignDialog.s(context);
      _data.value = _ToastData(text: text, k: k);

      final entry = _entry;
      if (entry == null) {
        // 首次或上次已移除：新建条目并插入（全屏 Positioned.fill 作为条目根节点）。
        // 注意：不要用 `!entry.mounted` 作为判断——insert 之后到首帧构建前，
        // `OverlayEntry.mounted` 仍为 false，会导致同帧重复插入多条全屏 layer。
        // `_dismiss()` 是唯一的移除点，且一定会把 `_entry` 置空，故 `_entry == null`
        // 即代表「当前没有在屏条目」，可直接作为插入条件。
        final created = OverlayEntry(
          builder: (_) => Positioned.fill(
            child: _DesignToastOverlay(data: _data),
          ),
        );
        _entry = created;
        overlay.insert(created);
      } else {
        // 复用同一条目：内容通过 ValueListenableBuilder 刷新，无需重新插入。
        entry.markNeedsBuild();
      }
      // 复位定时器
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 2), _dismiss);
    } catch (_) {
      // 任何异常（如 context 已失效）都不得外溢：提示失败不影响主流程。
    }
  }

  /// 幂等移除：可被定时器 / 外部安全地重复调用。
  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _entry;
    _entry = null;
    if (entry == null) return;
    try {
      // 直接 remove：即便条目尚未完成首帧构建（mounted 仍为 false）也能正确移除，
      // 避免「条目残留在 Overlay 中 + _entry 被置空」导致下次 show 叠加第二条 layer。
      entry.remove();
    } catch (_) {
      // 条目已被移除 / 所在 Overlay 已销毁：忽略。
    }
  }

  /// 测试专用：清空内部静态状态，避免用例之间相互影响。
  @visibleForTesting
  static void debugReset() {
    _dismiss();
    _data.value = null;
  }
}

/// Toast 数据快照（值对象，避免把调用方 context 带进条目 builder）。
class _ToastData {
  const _ToastData({required this.text, required this.k});

  final String text;

  /// 缩放系数（显示时确定一次）
  final double k;
}

/// Toast 内容层。**只使用自身 context**（根 Overlay 的 context，生命周期与条目一致），
/// 因此不会因调用方被销毁而访问失效 context。
class _DesignToastOverlay extends StatelessWidget {
  const _DesignToastOverlay({required this.data});

  final ValueNotifier<_ToastData?> data;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ToastData?>(
      valueListenable: data,
      builder: (context, value, _) {
        if (value == null) return const SizedBox.shrink();
        final k = value.k;
        return IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 80 * k),
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.sizeOf(context).width * 0.86,
                  ),
                  child: Container(
                    height: 36 * k,
                    padding: EdgeInsets.symmetric(horizontal: 8 * k),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8 * k),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 10 * k,
                          offset: Offset(0, 2 * k),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        value.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 15.6 * k,
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

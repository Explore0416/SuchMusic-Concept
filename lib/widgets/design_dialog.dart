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

/// 设计稿风格轻提示（参照 cankao/1.txt：黑底白字圆角提示条，屏幕居中）
/// 宽 261/430 屏宽、高 36、圆角 8、纯黑底、白字 15.6 号，2 秒后自动消失
class DesignToast {
  DesignToast._();

  static void show(BuildContext context, String text) {
    final k = DesignDialog.s(context);
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 80 * k),
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.86,
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
                        text,
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
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
    });
  }
}

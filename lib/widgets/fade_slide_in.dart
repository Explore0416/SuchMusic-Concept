import 'package:flutter/material.dart';

/// 列表/区块的**入场动画**：淡入 + 轻微上滑，按 [index] 递增延迟形成"逐条浮现"。
///
/// 用法：
/// ```dart
/// FadeSlideIn(index: i, child: ListTile(...))
/// ```
///
/// - 首屏一次性播放（进入即播，不遮断交互）；
/// - [delayStep] 控制每条间隔，[maxDelay] 防止长列表末尾等待过久；
/// - 尊重系统「减弱动态效果」（`MediaQuery.disableAnimations`）→ 直接静态显示。
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.delayStep = const Duration(milliseconds: 35),
    this.maxDelay = const Duration(milliseconds: 280),
    this.duration = const Duration(milliseconds: 320),
    this.offset = 16,
  });

  final Widget child;
  final int index;
  final Duration delayStep;
  final Duration maxDelay;
  final Duration duration;

  /// 起始纵向位移（px）。
  final double offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    final curve = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _fade = curve;
    _slide = Tween<Offset>(
      begin: Offset(0, widget.offset / 100),
      end: Offset.zero,
    ).animate(curve);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // 尊重「减弱动态效果」
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = 1;
      return;
    }
    final base = (widget.index * widget.delayStep.inMilliseconds).toDouble();
    final delay = base.clamp(0, widget.maxDelay.inMilliseconds.toDouble());
    Future<void>.delayed(Duration(milliseconds: delay.round()), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// 统一的**淡入 + 右滑**页面转场（比默认 Material 转场更柔和）。
Route<T> fadeSlideRoute<T>(Widget page) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.04, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

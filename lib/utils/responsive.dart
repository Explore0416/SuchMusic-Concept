import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 断点枚举，与 PRD §4.1 / ARCH §2.1 的 B1~B5 一一对应。
enum AppBreakpoint {
  /// 320–599dp 且 高>宽
  b1PhonePortrait,

  /// 宽 >= 600 且 宽>高 且最短边 < 600
  b2PhoneLandscape,

  /// 最短边 >= 600 且 宽 600–899 且竖屏
  b3TabletPortrait,

  /// 最短边 >= 600 且 宽 900–1199 且横屏
  b4TabletLandscape,

  /// 宽 >= 1200
  b5UltraWide,
}

/// 响应式「单一真源」：所有尺寸 / 断点 / 夹取集中于此。
///
/// 改造原则（ARCH §1.3）：只把原硬编码魔法数字替换为这里的方法调用，
/// 视觉风格与配色一律不变，保证竖屏基线不回归。
class Responsive {
  Responsive._();

  // ── 常量（全 App 唯一来源）────────────────────────────────
  static const double contentMaxWidth = 960; // 超宽屏内容上限（Q5）
  static const double coverMaxSide = 420; // 封面边长上限
  static const double minTouchTarget = 48; // 最小热区
  static const double lyricFontMax = 34; // 歌词字号上限（原 30/24）
  static const double railMinWidth = 72; // NavigationRail 最小宽
  static const double railMaxWidth = 96; // NavigationRail 最大宽
  static const double designWidth = 430; // 原设计稿基准宽
  static const double textScaleMin = 0.85;
  static const double textScaleMax = 1.3;

  // ── 断点判定 ──────────────────────────────────────────────

  /// 以最短边判定平板形态（而非设备型号）
  static bool isTablet(Size size) => size.shortestSide >= 600;

  static AppBreakpoint of(Size size) {
    final shortestSide = size.shortestSide;
    if (shortestSide < 600) {
      // 手机：宽 < 600 为竖屏，否则横屏
      return size.width < 600
          ? AppBreakpoint.b1PhonePortrait
          : AppBreakpoint.b2PhoneLandscape;
    }
    if (size.width < 900) return AppBreakpoint.b3TabletPortrait;
    if (size.width < 1200) return AppBreakpoint.b4TabletLandscape;
    return AppBreakpoint.b5UltraWide;
  }

  static AppBreakpoint ofContext(BuildContext context) =>
      of(MediaQuery.sizeOf(context));

  // ── 尺寸取值（替换原魔法数字）─────────────────────────────

  /// 内容区宽度上限（超宽屏居中后不超过 960）
  static double contentWidth(Size size) =>
      math.min(size.width, contentMaxWidth);

  /// 封面边长。
  ///
  /// - 手机竖屏：保持改造前观感「屏宽 - 50」。
  /// - 其余形态：同时受可用宽与可用高约束，封顶 [coverMaxSide]、下限 200。
  static double coverSize(Size size, AppBreakpoint bp) {
    if (bp == AppBreakpoint.b1PhonePortrait) {
      return size.width - 50;
    }

    double availW;
    double availH;
    switch (bp) {
      case AppBreakpoint.b2PhoneLandscape:
        // 左右分栏：左栏宽
        availW = (size.width - 40 - 24) / 2;
        // 手机横屏高度小，竖向预算取屏高的一半
        availH = size.height * 0.50;
        break;
      case AppBreakpoint.b3TabletPortrait:
        availW = math.min(size.width, contentMaxWidth) - 80;
        availH = size.height * 0.45;
        break;
      case AppBreakpoint.b4TabletLandscape:
      case AppBreakpoint.b5UltraWide:
        // 左右两栏：单栏宽（含间隙 24）
        availW = (math.min(size.width, contentMaxWidth) - 24) / 2 - 40;
        availH = size.height * 0.55;
        break;
      default:
        // 兜底（B1 已在上方 return，此处仅保证 switch 穷尽）：与 B1 同值
        availW = size.width - 50;
        availH = size.height;
        break;
    }

    return math.min(availW, availH).clamp(200.0, coverMaxSide);
  }

  /// 底部悬浮胶囊栏宽度（加 560 上限）
  static double bottomBarWidth(Size size) =>
      math.min(size.width * 0.85 - 44, 560);

  /// 全局 UI 缩放系数（沿用原 430 设计稿基准，夹取 [0.7, 1.15]）
  static double uiScale(Size size) => (math.min(size.width, contentMaxWidth) /
          designWidth)
      .clamp(0.7, 1.15);

  /// 弹窗缩放系数（夹取 [0.8, 1.0]，避免超宽屏弹窗过宽）
  static double dialogScale(Size size) =>
      (math.min(size.width, 480) / designWidth).clamp(0.8, 1.0);

  /// 装饰渐变高度（个人页顶部），clamp [240, 520]
  static double gradientHeight(Size size) =>
      (size.height * 0.533).clamp(240.0, 520.0);

  /// 歌词字号封顶（不随窗口宽度线性放大）
  static double clampLyricFont(double base) => math.min(base, lyricFontMax);

  // ── 安全区 / 字体缩放 ─────────────────────────────────────

  /// 安全区：取 padding 与 viewPadding 各边较大者
  static EdgeInsets safeArea(BuildContext context) {
    final mq = MediaQuery.of(context);
    final p = mq.padding;
    final v = mq.viewPadding;
    return EdgeInsets.fromLTRB(
      math.max(p.left, v.left),
      math.max(p.top, v.top),
      math.max(p.right, v.right),
      math.max(p.bottom, v.bottom),
    );
  }

  /// 夹取系统字体缩放至 [textScaleMin, textScaleMax]
  static TextScaler clampTextScaler(BuildContext context) =>
      MediaQuery.textScalerOf(context).clamp(
        minScaleFactor: textScaleMin,
        maxScaleFactor: textScaleMax,
      );

  // ── 形态开关（各屏据此选择布局分支）───────────────────────

  /// 平板形态使用左侧 NavigationRail
  /// 是否使用 PC 风格布局（左侧边栏 + 底部全宽常驻播放条）。
  ///
  /// **仅横屏大屏**（B4 平板横屏 / B5 超宽屏）启用；竖屏（B1 手机竖屏 /
  /// B3 平板竖屏）一律沿用上游原版的底部悬浮胶囊栏，保证竖屏底部控制栏
  /// 与原版体验一致。
  static bool showRail(AppBreakpoint bp) =>
      bp == AppBreakpoint.b4TabletLandscape ||
      bp == AppBreakpoint.b5UltraWide;

  /// 播放页左右分栏形态（B2/B4/B5）
  static bool isPlayerSplit(AppBreakpoint bp) =>
      bp == AppBreakpoint.b2PhoneLandscape ||
      bp == AppBreakpoint.b4TabletLandscape ||
      bp == AppBreakpoint.b5UltraWide;

  /// 首页是否使用网格（平板形态）
  static bool isGridHome(AppBreakpoint bp) =>
      bp == AppBreakpoint.b3TabletPortrait ||
      bp == AppBreakpoint.b4TabletLandscape ||
      bp == AppBreakpoint.b5UltraWide;

  /// 首页网格列数：非平板 1 列；平板（最短边≥600dp）一律 ≥2 列：
  /// 宽 <900 → 2 列，宽 ≥900 → 3 列（满足 PRD REQ-03 平板双列要求）。
  static int homeGridColumns(Size size) {
    if (!isTablet(size)) return 1;
    return size.width >= 900 ? 3 : 2;
  }
}

/// 内容居中容器：把任意页面内容夹到 [Responsive.contentMaxWidth] 并水平居中。
class ResponsiveContent extends StatelessWidget {
  const ResponsiveContent({
    super.key,
    required this.child,
    this.padding,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    Widget content = child;
    if (padding != null) {
      content = Padding(padding: padding!, child: content);
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: Responsive.contentMaxWidth,
        ),
        child: content,
      ),
    );
  }
}

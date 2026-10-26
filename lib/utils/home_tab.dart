import 'package:flutter/foundation.dart';

/// 首页内容标签（首页 / 本地 / 歌单）的当前选中项。
///
/// 窄屏由首页顶部的标签行切换，宽屏（平板 / 横屏）由左侧导航切换。
/// 两处共用这一份状态，避免「侧栏高亮的是本地、右侧内容还停在首页」。
class HomeTab {
  HomeTab._();

  static const int home = 0;
  static const int local = 1;
  static const int playlists = 2;

  /// 侧栏（左侧导航）断点：达到该宽度后，首页 / 本地 / 歌单 从顶部标签行
  /// 移到左侧导航，底部悬浮播放胶囊也随之取消。与 MainShell 共用同一个值，
  /// 避免两处断点漂移导致「一侧有导航、另一侧还留着标签行」。
  static const double sideNavBreakpoint = 720;

  static bool useSideNav(double width) => width >= sideNavBreakpoint;

  /// 全局唯一当前标签（[home] / [local] / [playlists]）。
  static final ValueNotifier<int> index = ValueNotifier<int>(home);

  /// 切到指定标签；值未变化时不发通知，避免无谓重建。
  static void select(int value) {
    if (index.value == value) return;
    index.value = value;
  }
}

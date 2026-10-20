import 'package:flutter/material.dart';

/// 全局导航键。
///
/// 后台下载这类「不依赖某个页面存活」的流程需要它：
/// 页面可能已经被用户切走，但下载完成时仍要能弹出安装确认。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

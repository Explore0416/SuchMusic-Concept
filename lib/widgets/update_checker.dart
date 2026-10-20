import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_keys.dart';
import '../services/update_service.dart';
import 'design_dialog.dart';

/// 应用更新检查器：请求远端版本信息 → 比对 → 更新弹窗 → 下载 → 调起安装
/// 关于页手动检查与启动时自动检查共用本组件
/// 弹窗样式使用 DesignDialog（cankao/1.txt 设计稿风格）
///
/// 强制更新（update.json 的 force 字段为 true）时：
/// 启动即自动弹窗、无「以后再说」、按返回键无法关闭、下载不可取消，
/// 必须完成更新才能继续使用
class UpdateChecker {
  UpdateChecker._();

  /// 检查更新
  /// [silent] 为 true 时静默检查（启动时用）：无 loading、失败不打扰用户
  /// 为 false 时手动检查（关于页用）：有 loading 和结果提示弹窗
  static Future<void> check(
    BuildContext context, {
    bool silent = false,
  }) async {
    if (!silent) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: CircularProgressIndicator(color: DesignDialog.confirmBlue),
        ),
      );
    }

    AppUpdateInfo? remote;
    try {
      remote = await UpdateService.fetchRemoteInfo();
    } catch (_) {
      remote = null;
    }

    if (!context.mounted) return;
    if (!silent) Navigator.of(context).pop(); // 关闭 loading

    if (remote == null || remote.downloadUrls.isEmpty) {
      if (!silent) _showTip(context, '检查更新', '检查失败，请稍后重试');
      return;
    }

    final localCode = await UpdateService.localVersionCode();
    if (!context.mounted) return;

    if (remote.versionCode <= localCode) {
      if (!silent) {
        final pkg = await PackageInfo.fromPlatform();
        if (!context.mounted) return;
        _showTip(context, '检查更新', '当前已是最新版本 v${pkg.version}');
      }
      return;
    }

    _showUpdateDialog(context, remote);
  }

  // ---------------- 各弹窗 ----------------

  /// 发现新版本弹窗：展示更新日志
  /// 点空白区域一律不可关闭（barrierDismissible: false）
  /// 非强制：有「以后再说」，可按返回键关闭
  /// 强制：无跳过按钮，PopScope 拦截返回键，只能完成更新
  static void _showUpdateDialog(BuildContext context, AppUpdateInfo info) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final s = DesignDialog.s(ctx);
        return PopScope(
          canPop: !info.force,
          child: DesignDialog.shell(
            ctx,
            child: DesignDialog.card(
              ctx,
              children: [
                DesignDialog.title(ctx, '发现新版本 v${info.versionName}'),
                if (info.force) ...[
                  SizedBox(height: 10 * s),
                  Text(
                    '本次为强制更新，需完成更新后才能继续使用',
                    style: TextStyle(
                      fontSize: 12.5 * s,
                      color: const Color(0xFFE02020),
                    ),
                  ),
                ],
                SizedBox(height: 12 * s),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 220 * s),
                  child: SingleChildScrollView(
                    child: DesignDialog.body(
                      ctx,
                      info.changelog.isEmpty
                          ? '修复已知问题，优化使用体验'
                          : info.changelog,
                    ),
                  ),
                ),
                SizedBox(height: 26 * s),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (!info.force) ...[
                      DesignDialog.cancelText(
                        ctx,
                        '以后再说',
                        () => Navigator.of(ctx).pop(),
                      ),
                      SizedBox(width: 12 * s),
                    ],
                    DesignDialog.confirmButton(ctx, '立即更新', () {
                      Navigator.of(ctx).pop();
                      _downloadAndInstall(context, info);
                    }),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 后台下载中标记：避免重复进入下载流程。
  static bool _downloading = false;

  /// 下载 APK（进度弹窗），完成后调起系统安装器。
  ///
  /// 非强制更新时提供「后台下载」：关闭弹窗但继续下载，用户可以继续用 App，
  /// 下载完成后用全局导航键弹出安装确认（不依赖发起下载的页面是否还活着）。
  static void _downloadAndInstall(BuildContext context, AppUpdateInfo info) {
    if (_downloading) {
      _showTip(context, '正在下载', '更新包正在下载，完成后会提示安装');
      return;
    }
    _downloading = true;

    // 提前捕获 NavigatorState：后面几处 pop 都在 async gap 之后，
    // 直接持有它就不必反复用已可能失效的 BuildContext。
    final nav = Navigator.of(context);
    final cancelToken = CancelToken();
    double progress = 0;
    String progressText = '准备下载...';
    String routeText = '线路：正在选择最快线路…';
    bool dialogClosed = false;

    /// 用户点了「后台下载」：弹窗已关，下载继续
    bool inBackground = false;
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          dialogSetState = setDialogState;
          final s = DesignDialog.s(ctx);
          return DesignDialog.shell(
            ctx,
            child: DesignDialog.card(
              ctx,
              children: [
                DesignDialog.title(ctx, '正在下载 v${info.versionName}'),
                SizedBox(height: 6 * s),
                Text(
                  routeText,
                  style: TextStyle(
                      fontSize: 12.5 * s, color: DesignDialog.confirmBlue),
                ),
                SizedBox(height: 12 * s),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3 * s),
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    backgroundColor: const Color(0xFFE8E8E8),
                    color: DesignDialog.confirmBlue,
                    minHeight: 6 * s,
                  ),
                ),
                SizedBox(height: 10 * s),
                Text(
                  progressText,
                  style:
                      TextStyle(fontSize: 12 * s, color: DesignDialog.cancelGray),
                ),
                if (!info.force) ...[
                  SizedBox(height: 18 * s),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      DesignDialog.cancelText(ctx, '后台下载', () {
                        inBackground = true;
                        dialogClosed = true;
                        Navigator.of(ctx).pop();
                        final root = appNavigatorKey.currentContext;
                        if (root != null) {
                          DesignToast.show(root, '已转入后台下载，可继续使用');
                        }
                      }),
                      SizedBox(width: 6 * s),
                      DesignDialog.cancelText(
                        ctx,
                        '取消',
                        () => cancelToken.cancel(),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );

    UpdateService.downloadApk(
      info.downloadUrls,
      cancelToken: cancelToken,
      onRouteChanged: (route) {
        dialogSetState?.call(() {
          routeText = '线路：$route';
        });
      },
      onProgress: (received, total) {
        dialogSetState?.call(() {
          progress = total > 0 ? received / total : 0;
          final receivedMb = (received / 1024 / 1024).toStringAsFixed(1);
          progressText = total > 0
              ? '$receivedMb MB / ${(total / 1024 / 1024).toStringAsFixed(1)} MB'
              : '已下载 $receivedMb MB';
        });
      },
    ).then((savePath) async {
      _downloading = false;
      if (!inBackground) {
        nav.pop(); // 关闭下载弹窗
        dialogClosed = true;
      }

      if (inBackground) {
        final go = await _confirmInstall(info.versionName);
        if (!go) return;
      }

      // 安装阶段错误单独处理，避免误报为下载失败。
      // 一律用全局导航键取上下文：页面此时可能已被用户切走。
      try {
        final err = await UpdateService.installApk(savePath);
        final c = appNavigatorKey.currentContext;
        if (err != null && c != null) {
          // ignore: use_build_context_synchronously
          _showTip(c, '安装', '无法调起安装：$err');
        }
      } catch (e) {
        debugPrint('调起安装异常: $e');
        // 全局导航键的 context 与应用根绑定，不随页面销毁失效
        final c = appNavigatorKey.currentContext;
        if (c != null) {
          // ignore: use_build_context_synchronously
          _showTip(c, '安装', '无法调起安装，请确认已允许安装未知应用后重试');
        }
      }
    }).catchError((Object e) {
      _downloading = false;
      // 弹窗可能已在成功 / 后台分支关闭，避免二次 pop 把页面弹出导致黑屏
      if (!dialogClosed) {
        nav.pop();
        dialogClosed = true;
      }
      final cancelled = e is DioException && e.type == DioExceptionType.cancel;
      if (cancelled) return;
      final c = appNavigatorKey.currentContext;
      // ignore: use_build_context_synchronously
      if (c != null) _showTip(c, '下载失败', '下载失败，请检查网络后重试');
    });
  }

  /// 后台下载完成后的安装确认（用全局导航键，不依赖发起下载的页面）。
  static Future<bool> _confirmInstall(String version) async {
    final context = appNavigatorKey.currentContext;
    if (context == null) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final s = DesignDialog.s(ctx);
        return DesignDialog.shell(
          ctx,
          child: DesignDialog.card(
            ctx,
            children: [
              DesignDialog.title(ctx, '下载完成'),
              SizedBox(height: 8 * s),
              Text(
                'v$version 已下载完成，是否立即安装？',
                style: TextStyle(
                  fontSize: 14 * s,
                  color: DesignDialog.contentGray,
                  height: 1.6,
                ),
              ),
              SizedBox(height: 20 * s),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  DesignDialog.cancelText(
                      ctx, '稍后', () => Navigator.pop(ctx, false)),
                  SizedBox(width: 10 * s),
                  DesignDialog.confirmButton(
                      ctx, '立即安装', () => Navigator.pop(ctx, true)),
                ],
              ),
            ],
          ),
        );
      },
    );
    return result ?? false;
  }

  /// 通用提示弹窗（最新版本 / 检查失败 / 安装失败）：标题 + 正文 + 蓝色「确定」
  static void _showTip(BuildContext context, String title, String content) {
    DesignDialog.showConfirm(
      context,
      titleText: title,
      contentText: content,
      showCancel: false,
    );
  }
}

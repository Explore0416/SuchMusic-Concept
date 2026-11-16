import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/third_party_auth.dart';
import 'client_registry.dart';
import 'third_party_auth_service.dart';
import 'third_party_bridge.dart';

/// 静默续期通知的标题（ARCHITECTURE §6.6 / M6）。
const String kThirdPartyAccessNoticeTitle = '第三方应用访问';

/// 深链解析与入口分发（ARCHITECTURE §5 / §9.1）。
///
/// 职责单一：把 `suchmusic://` Uri 交给 [ThirdPartyAuthService]，
/// 再把结果按类型分发出去。**不做任何授权判断**。
class DeepLinkService {
  DeepLinkService({
    ThirdPartyAuthService? authService,
    ThirdPartyBridge? bridge,
    ClientRegistry? registry,
  })  : _auth = authService ?? ThirdPartyAuthService.instance,
        _bridge = bridge ?? MethodChannelThirdPartyBridge(),
        _registry = registry ?? ClientRegistry.standard();

  /// 全局单例。
  static final DeepLinkService instance = DeepLinkService();

  final ThirdPartyAuthService _auth;
  final ThirdPartyBridge _bridge;

  /// 通知里展示应用名用（注册表展示名，取不到退回 clientId）。
  final ClientRegistry _registry;

  StreamSubscription<String>? _sub;
  Future<bool> Function(AuthRequest request)? _confirm;
  void Function(String error, String message)? _onError;
  bool _started = false;

  /// 是否已开始监听。
  bool get isStarted => _started;

  /// 开始监听原生深链事件，并处理冷启动 Uri。
  ///
  /// [confirm] 由 M4（授权确认页）注入；为 null 时只打印日志、不弹页，
  /// 保证内核可以先落地而不依赖 UI。
  /// [onError] 把授权失败回传给 UI 层（如 SnackBar）——授权失败绝不静默，
  /// 否则用户只看到 App 被唤起却毫无反应（1.5.3 实机踩过的坑）。
  Future<void> start({
    Future<bool> Function(AuthRequest request)? confirm,
    void Function(String error, String message)? onError,
  }) async {
    _confirm = confirm;
    _onError = onError;
    if (_started) return;
    _started = true;

    _sub ??= _bridge.deepLinks.listen(
      (String uri) {
        unawaited(handleUri(uri));
      },
      onError: (Object e) {
        debugPrint('[ThirdParty] 深链事件异常: ${e.runtimeType}');
      },
      cancelOnError: false,
    );

    // 冷启动：App 是被 suchmusic:// 拉起的，初始 Uri 只从原生取一次
    try {
      final launchUri = await _bridge.getLaunchUri();
      if (launchUri != null && launchUri.isNotEmpty) {
        await handleUri(launchUri, confirm: confirm);
      }
    } catch (e) {
      debugPrint('[ThirdParty] 读取启动深链失败: ${e.runtimeType}');
    }
  }

  /// 停止监听（测试 / 退出）。
  void stop() {
    _sub?.cancel();
    _sub = null;
    _onError = null;
    _started = false;
  }

  /// 处理一条 Uri 字符串（M4 的路由回调与单测都从这里进来）。
  ///
  /// 返回 [AuthOutcome]；非 suchmusic 深链返回 null（交回系统其它处理方）。
  Future<AuthOutcome?> handleUri(
    String raw, {
    Future<bool> Function(AuthRequest request)? confirm,
  }) async {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != ThirdPartyAuthService.scheme) {
      return null;
    }
    final outcome = await _auth.handleAuthorizeRequest(
      uri,
      confirm: confirm ?? _confirm,
    );
    _dispatch(outcome, uri);
    return outcome;
  }

  /// 按结果类型分发。
  ///
  /// - [AuthCompleted]：静默续期则叠加一条系统通知（M6），前台确认过的请求
  ///   不发通知（用户刚看过确认页，再弹一条只会打扰）；
  /// - [AuthNeedsUi]：没有任何 confirm 实现时只打印（内核可独立于 UI 运行）；
  /// - [AuthFailed]：打印错误码（错误信息不含任何令牌，T8）。
  void _dispatch(AuthOutcome outcome, Uri uri) {
    switch (outcome) {
      case AuthCompleted(:final String clientId, :final bool silent):
        debugPrint('[ThirdParty] 授权完成: $clientId (silent=$silent)');
        if (silent) {
          unawaited(_notifySilentAccess(clientId, _scopesOf(uri)));
        }
      case AuthNeedsUi(:final AuthRequest request):
        if (_confirm == null) {
          debugPrint(
            '[ThirdParty] 需要用户确认: ${request.client.clientId} '
            'scopes=${ThirdPartyScope.codesOf(request.scopes)}（确认页未接线）',
          );
        } else {
          debugPrint('[ThirdParty] 确认页已接管: ${request.client.clientId}');
        }
      case AuthFailed(:final String error, :final String message):
        debugPrint('[ThirdParty] 授权失败: $error $message');
        // 失败必须让用户看见：App 是被这条深链唤起的，静默吞掉
        // 只会让人以为「点了没反应」。UI 未接线时仅日志。
        try {
          _onError?.call(error, message);
        } catch (e) {
          debugPrint('[ThirdParty] 错误回传异常: ${e.runtimeType}');
        }
    }
  }

  /// 从深链里取本次申请的 scope（未知项忽略）。
  ///
  /// 只用于生成通知文案：授权判定始终以服务返回的结论为准，这里不做任何放行。
  List<ThirdPartyScope> _scopesOf(Uri uri) {
    final out = <ThirdPartyScope>[];
    for (final piece in (uri.queryParameters['scopes'] ?? '').split(',')) {
      final scope = ThirdPartyScope.fromCode(piece.trim());
      if (scope != null && !out.contains(scope)) out.add(scope);
    }
    out.sort((a, b) => a.index.compareTo(b.index));
    return out;
  }

  /// 静默续期后发系统通知：「{App} 读取了你的曲风画像」等。
  ///
  /// 多个 scope 合并成一条，内容用「、」连接；`account.token` 不参与
  /// （它永远不会走到静默路径，ADR-003）。
  Future<void> _notifySilentAccess(
    String clientId,
    List<ThirdPartyScope> scopes,
  ) async {
    final phrases = <String>[];
    for (final scope in scopes) {
      switch (scope) {
        case ThirdPartyScope.genreRead:
          phrases.add('读取了你的曲风画像');
        case ThirdPartyScope.urlResolve:
          phrases.add('获取了歌曲直链');
        case ThirdPartyScope.playbackControl:
          phrases.add('正在通过 SuchMusic 播放');
        case ThirdPartyScope.accountToken:
          break;
      }
    }
    if (phrases.isEmpty) return;
    final content = '${_appNameOf(clientId)} ${phrases.join('、')}';
    try {
      await _bridge.showAccessNotice(
        title: kThirdPartyAccessNoticeTitle,
        content: content,
      );
    } catch (e) {
      // 通知失败不影响已完成的授权（数据已投递给目标包）
      debugPrint('[ThirdParty] 访问通知发送失败: ${e.runtimeType}');
    }
  }

  /// 通知里的应用名：注册表展示名优先，取不到退回 clientId。
  String _appNameOf(String clientId) {
    final name = (_registry.findById(clientId)?.displayName ?? '').trim();
    return name.isEmpty ? clientId : name;
  }
}

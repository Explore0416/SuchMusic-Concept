import 'dart:async';

import 'package:flutter/material.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/kugou_platform.dart';
import '../services/kugou_credential_service.dart';
import '../services/music_api_service.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';
import 'kugou_login_dialog.dart';

/// 登录音源。
enum LoginSource {
  netease('网易云音乐'),
  kugou('酷狗音乐');

  const LoginSource(this.label);

  final String label;
}

/// 统一登录弹层：**一个入口**登录所有音源。
///
/// 之前「我的」页既有顶部「扫码登录」（只认网易云），又有一张「音源账号」
/// 卡片（网易云 + 酷狗两行），同一个动作出现三次，酷狗用户还得先猜入口。
/// 现在收成一个弹层，顶部切换音源，页面里不再重复挂账号入口。
Future<void> showLoginSheet(
  BuildContext context, {
  required MusicApiService apiService,
  required void Function(NeteaseAccountInfoWrap info) onNeteaseLoggedIn,
  LoginSource initial = LoginSource.netease,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppColors.ink.withValues(alpha: 0.42),
    builder: (ctx) {
      final inset = MediaQuery.of(ctx).viewInsets.bottom;
      final bottom = MediaQuery.of(ctx).padding.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: inset),
        child: Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(AppRadius.sheet),
            ),
          ),
          padding: EdgeInsets.only(
            left: AppSpace.xl,
            right: AppSpace.xl,
            top: AppSpace.md,
            bottom: bottom + AppSpace.xl,
          ),
          child: _LoginSheetBody(
            apiService: apiService,
            onNeteaseLoggedIn: onNeteaseLoggedIn,
            initial: initial,
          ),
        ),
      );
    },
  );
}

class _LoginSheetBody extends StatefulWidget {
  const _LoginSheetBody({
    required this.apiService,
    required this.onNeteaseLoggedIn,
    required this.initial,
  });

  final MusicApiService apiService;
  final void Function(NeteaseAccountInfoWrap info) onNeteaseLoggedIn;
  final LoginSource initial;

  @override
  State<_LoginSheetBody> createState() => _LoginSheetBodyState();
}

class _LoginSheetBodyState extends State<_LoginSheetBody> {
  late LoginSource _source = widget.initial;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 拖拽指示条：底部弹层的可关闭暗示
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.hairline,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        Row(
          children: [
            const Expanded(child: Text('登录', style: AppType.display)),
            AppIconButton(
              icon: Icons.close_rounded,
              iconSize: 20,
              tooltip: '关闭',
              onTap: () => Navigator.maybePop(context),
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        _SourceSwitch(
          value: _source,
          onChanged: (v) => setState(() => _source = v),
        ),
        const SizedBox(height: AppSpace.xl),
        // 切换时高度不同，用 AnimatedSize 过渡，避免弹层突然跳一下
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: switch (_source) {
            LoginSource.netease => NeteaseQrLoginBody(
              apiService: widget.apiService,
              onLoggedIn: widget.onNeteaseLoggedIn,
            ),
            LoginSource.kugou => const KugouLoginBody(),
          },
        ),
      ],
    );
  }
}

/// 音源分段切换：拇指在灰底胶囊里滑动，选中项是白卡。
class _SourceSwitch extends StatelessWidget {
  const _SourceSwitch({required this.value, required this.onChanged});

  final LoginSource value;
  final ValueChanged<LoginSource> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceMuted,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        children: [
          for (final s in LoginSource.values)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(s),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: s == value ? AppColors.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: s == value
                        ? Border.all(color: AppColors.hairline, width: 0.7)
                        : null,
                  ),
                  child: Text(
                    s.label,
                    style: AppType.body.copyWith(
                      fontWeight: s == value
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: s == value
                          ? AppColors.ink
                          : AppColors.inkSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 网易云扫码登录内容（不含弹层外壳）。
class NeteaseQrLoginBody extends StatefulWidget {
  const NeteaseQrLoginBody({
    super.key,
    required this.apiService,
    required this.onLoggedIn,
  });

  final MusicApiService apiService;
  final void Function(NeteaseAccountInfoWrap info) onLoggedIn;

  @override
  State<NeteaseQrLoginBody> createState() => _NeteaseQrLoginBodyState();
}

class _NeteaseQrLoginBodyState extends State<NeteaseQrLoginBody> {
  String? _qrKey;
  String? _qrUrl;
  String _statusText = '正在获取二维码…';
  bool _isLoading = true;
  bool _isExpired = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _fetchQrCode();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchQrCode() async {
    setState(() {
      _isLoading = true;
      _statusText = '正在获取二维码…';
      _isExpired = false;
    });

    final result = await widget.apiService.getQrCodeKey();
    if (!mounted) return;

    if (result is QrCodeError) {
      setState(() {
        _isLoading = false;
        _statusText = result.message;
        _isExpired = true;
      });
      return;
    }

    final key = result as String;
    final url = widget.apiService.getQrCodeUrl(key);
    setState(() {
      _qrKey = key;
      _qrUrl = url;
      _isLoading = false;
      _statusText = '打开网易云音乐 App 扫一扫';
    });

    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_qrKey == null) return;

      final code = await widget.apiService.checkQrCodeStatus(_qrKey!);
      if (!mounted) return;

      switch (code) {
        case 800:
          _pollTimer?.cancel();
          setState(() {
            _statusText = '二维码已过期，点一下重新获取';
            _isExpired = true;
          });
        case 801:
          setState(() => _statusText = '等待扫码…');
        case 802:
          setState(() => _statusText = '已扫码，请在手机上确认');
        case 803:
          _pollTimer?.cancel();
          setState(() => _statusText = '登录成功，正在读取账号…');
          try {
            final info = await widget.apiService.handleQrCodeLoginSuccess();
            if (!mounted) return;
            if (info != null) {
              widget.onLoggedIn(info);
            } else {
              setState(() => _statusText = '登录成功但读取账号失败，请重试');
            }
          } catch (e) {
            if (!mounted) return;
            setState(() => _statusText = '登录处理异常：$e');
          }
        default:
          if (code == -462 || code == 8821) {
            _pollTimer?.cancel();
            setState(() {
              _statusText = '服务器拒绝扫码登录，请使用手动输入 MUSIC_U';
              _isExpired = true;
            });
          }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_isLoading)
          const SizedBox(
            width: 188,
            height: 188,
            child: Center(
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
          )
        else if (_qrUrl != null)
          GestureDetector(
            // 过期后点二维码即可刷新，不必再去找按钮
            onTap: _isExpired ? _fetchQrCode : null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 188,
                  height: 188,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.row),
                    border: Border.all(color: AppColors.hairline, width: 0.7),
                  ),
                  child: Opacity(
                    // 过期时二维码压暗，避免用户拿旧码去扫
                    opacity: _isExpired ? 0.18 : 1,
                    child: QrImageView(
                      data: _qrUrl!,
                      version: QrVersions.auto,
                      size: 164,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: AppColors.ink,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: AppColors.ink,
                      ),
                    ),
                  ),
                ),
                if (_isExpired)
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.refresh_rounded,
                        size: 28,
                        color: AppColors.ink,
                      ),
                      const SizedBox(height: AppSpace.xs),
                      Text('点击刷新', style: AppType.captionStrong),
                    ],
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpace.lg),
        Text(
          _statusText,
          textAlign: TextAlign.center,
          style: AppType.caption.copyWith(
            color: _isExpired ? AppColors.danger : AppColors.inkTertiary,
          ),
        ),
        if (_isExpired) ...[
          const SizedBox(height: AppSpace.lg),
          SizedBox(
            height: 44,
            child: FilledButton(
              onPressed: _fetchQrCode,
              child: const Text('重新获取二维码'),
            ),
          ),
        ],
      ],
    );
  }
}

/// 酷狗账号登录内容（不含弹层外壳）：概念版 / 原版按 appid 各授权一次。
class KugouLoginBody extends StatefulWidget {
  const KugouLoginBody({super.key});

  @override
  State<KugouLoginBody> createState() => _KugouLoginBodyState();
}

class _KugouLoginBodyState extends State<KugouLoginBody> {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final platform in KugouPlatform.values) ...[
          if (platform != KugouPlatform.values.first)
            const AppHairline(indent: 60),
          _KugouRow(platform: platform, onTap: () => _login(platform)),
        ],
        const SizedBox(height: AppSpace.md),
        Text(
          '两个版本共用同一个酷狗账号，但按 appid 分别签发凭证，需要各扫一次码。'
          '登录凭据只存在本机。',
          style: AppType.caption.copyWith(
            color: AppColors.inkTertiary,
            height: 1.55,
          ),
        ),
      ],
    );
  }

  Future<void> _login(KugouPlatform platform) async {
    await showKugouLoginDialog(context, platform: platform);
    if (!mounted) return;
    setState(() {});
  }
}

class _KugouRow extends StatelessWidget {
  const _KugouRow({required this.platform, required this.onTap});

  final KugouPlatform platform;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cred = KugouCredentialService.instance;
    final logged = cred.hasCredentialsFor(platform);
    final uid = logged ? '（${_maskUid(cred.userIdOf(platform))}）' : '';

    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 68,
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadius.row),
              ),
              child: const Icon(
                Icons.library_music_rounded,
                size: 20,
                color: AppColors.inkSecondary,
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(platform.label, style: AppType.body),
                  const SizedBox(height: 2),
                  Text(
                    logged ? '已登录$uid' : '未登录 · 登录后可用对应音质与权益',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.caption.copyWith(
                      color: AppColors.inkTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpace.sm),
            AppTag(
              text: logged ? '已连接' : '去登录',
              color: logged ? AppColors.success : AppColors.ink,
              background: logged
                  ? AppColors.successSoft
                  : AppColors.surfaceMuted,
            ),
          ],
        ),
      ),
    );
  }

  String _maskUid(String? uid) {
    if (uid == null || uid.isEmpty) return '';
    if (uid.length <= 6) return uid;
    return '${uid.substring(0, 3)}***${uid.substring(uid.length - 3)}';
  }
}

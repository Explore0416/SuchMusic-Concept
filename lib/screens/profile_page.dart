import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/kugou_platform.dart';
import '../models/song_model.dart';

import '../services/music_api_service.dart';
import '../services/app_init.dart';
import '../services/kugou_credential_service.dart';
import '../utils/responsive.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/kugou_account_sheet.dart';
import 'library_page.dart';
import 'playlist_detail_page.dart';
import 'settings_page.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _apiService = MusicApiService();
  bool _isLoggedIn = false;
  NeteaseAccountInfoWrap? _userInfo;

  String? _cachedNickname;
  String? _cachedAvatarUrl;
  String? _cachedUserId;

  List<PlaylistModel> _playlists = [];
  bool _loadingPlaylists = false;

  @override
  void initState() {
    super.initState();
    _initState();
  }

  Future<void> _initState() async {
    await ensureInitialized;
    await _apiService.init();
    if (!mounted) return;
    _cachedNickname = _apiService.cachedNickname;
    _cachedAvatarUrl = _apiService.cachedAvatarUrl;
    _cachedUserId = _apiService.cachedUserId;

    if (_apiService.hasCachedUser) {
      setState(() {
        _isLoggedIn = true;
      });
      _verifyLogin();
    }
  }

  Future<void> _verifyLogin() async {
    final result = await _apiService.verifyLogin();
    if (!mounted) return;
    setState(() {
      if (result != null) {
        _isLoggedIn = true;
        _userInfo = result;
        _cachedNickname = _apiService.cachedNickname;
        _cachedAvatarUrl = _apiService.cachedAvatarUrl;
        _cachedUserId = _apiService.cachedUserId;
      } else {
        _isLoggedIn = false;
        _userInfo = null;
        _cachedNickname = null;
        _cachedAvatarUrl = null;
        _cachedUserId = null;
      }
    });
    if (_isLoggedIn) _loadPlaylists();
  }

  Future<void> _clearCookie() async {
    await _apiService.clearCookie();
    if (!mounted) return;
    setState(() {
      _isLoggedIn = false;
      _userInfo = null;
      _cachedNickname = null;
      _cachedAvatarUrl = null;
      _cachedUserId = null;
      _playlists = [];
    });
  }

  Future<void> _loadPlaylists() async {
    final userId = _cachedUserId ??
        _userInfo?.profile?.userId.toString();
    if (userId == null || userId.isEmpty) return;
    setState(() => _loadingPlaylists = true);
    final playlists = await _apiService.userPlaylist(userId);
    debugPrint('🎵 歌单数量: ${playlists.length}');
    for (final p in playlists) {
      debugPrint('🎵 歌单: ${p.name} | coverUrl: ${p.coverUrl}');
    }
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _loadingPlaylists = false;
    });
  }

  void _showQrCodeLoginDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 25),
        child: _QrCodeLoginSheet(
          apiService: _apiService,
          onLoginSuccess: (info) {
            Navigator.pop(context);
            setState(() {
              _isLoggedIn = true;
              _userInfo = info;
              _cachedNickname = _apiService.cachedNickname;
              _cachedAvatarUrl = _apiService.cachedAvatarUrl;
              _cachedUserId = _apiService.cachedUserId;
            });
            _loadPlaylists();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = !_isLoggedIn ? _buildUnloggedPage() : _buildLoggedPage();
    // 大屏内容居中留白（内容上限 960dp）；手机竖屏下与改造前一致
    return Center(
      child: ConstrainedBox(
        constraints:
            const BoxConstraints(maxWidth: Responsive.contentMaxWidth),
        child: SizedBox.expand(
          // 登录态切换时淡入淡出，避免页面「跳变」
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: KeyedSubtree(
              key: ValueKey(_isLoggedIn),
              child: page,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoggedPage() {
    final topPadding = MediaQuery.of(context).padding.top;
    final profile = _userInfo?.profile;
    final nickname = profile?.nickname ?? _cachedNickname ?? '未知用户';
    final avatarUrl = profile?.avatarUrl ?? _cachedAvatarUrl ?? '';
    final vipType = _userInfo?.profile?.vipType ?? _userInfo?.account?.vipType ?? 0;

    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: Responsive.gradientHeight(MediaQuery.of(context).size),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x264D8CFF),
                  Color(0x00C4C4C4),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 25,
          top: topPadding + 15,
          child: GestureDetector(
            onTap: _openSettings,
            child: SvgPicture.asset(
              'assets/images/svg/settings_fill.svg',
              width: 24,
              height: 24,
              colorFilter: const ColorFilter.mode(
                Color(0xFF333333),
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
        Positioned(
          right: 67,
          top: topPadding + 15,
          child: SvgPicture.asset(
            'assets/images/svg/moon.svg',
            width: 24,
            height: 24,
            colorFilter: const ColorFilter.mode(
              Color(0xFF333333),
              BlendMode.srcIn,
            ),
          ),
        ),
        // Positioned(
        //   right: 67,
        //   top: topPadding + 12,
        //   child: GestureDetector(
        //     onTap: _clearCookie,
        //     child: const Icon(Icons.logout, size: 22, color: Color(0xFF333333)),
        //   ),
        // ),
        Positioned(
          left: 25,
          top: topPadding + 72,
          child: ClipOval(
            child: Container(
              width: 52,
              height: 52,
              color: const Color(0xFFE8E8E8),
              child: avatarUrl.isNotEmpty
                  ? _AvatarImage(url: avatarUrl)
                  : const Icon(Icons.person, size: 30, color: Colors.grey),
            ),
          ),
        ),
        Positioned(
          left: 89,
          top: topPadding + 79,
          child: Text(
            nickname,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Colors.black,
            ),
          ),
        ),
        if (vipType != 0)
          Positioned(
            left: 89,
            top: topPadding + 104,
            child: Container(
              width: 40,
              height: 13,
              decoration: BoxDecoration(
                color: const Color(0x1A3080FF),
                borderRadius: BorderRadius.circular(3),
              ),
              alignment: Alignment.center,
              child: const Text(
                'VIP',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: Color(0xFF3080FF),
                ),
              ),
            ),
          ),
        Positioned(
          left: 25,
          top: topPadding + 175,
          child: const Text(
            '我的歌单',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.black,
            ),
          ),
        ),
        Positioned(
          left: 25,
          right: 25,
          top: topPadding + 217,
          bottom: 0,
          child: _buildPlaylistList(),
        ),
      ],
    );
  }

  Widget _buildPlaylistList() {
    if (_loadingPlaylists) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_playlists.isEmpty) {
      return const Center(
        child: Text(
          '暂无歌单',
          style: TextStyle(fontSize: 14, color: Colors.black45),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _playlists.length,
      itemBuilder: (_, index) {
        final playlist = _playlists[index];
        return Padding(
          padding: EdgeInsets.only(bottom: index < _playlists.length - 1 ? 8 : 0),
          child: _buildPlaylistItem(playlist),
        );
      },
    );
  }

  Widget _buildPlaylistItem(PlaylistModel playlist) {
    return GestureDetector(
      onTap: () => _openPlaylistDetail(playlist),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFF0F0F0),
                borderRadius: BorderRadius.circular(5),
              ),
              child: playlist.coverUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: _PlaylistCoverImage(url: playlist.coverUrl!),
                    )
                  : const Icon(Icons.music_note, color: Colors.grey, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: Colors.black,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${playlist.trackCount ?? 0}首',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: Color(0x80000000),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnloggedPage() {
    final topPadding = MediaQuery.of(context).padding.top;
    return Stack(
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: Responsive.gradientHeight(MediaQuery.of(context).size),
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x264D8CFF),
                  Color(0x00C4C4C4),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 25,
          top: topPadding + 15,
          child: GestureDetector(
            onTap: _openSettings,
            child: SvgPicture.asset(
              'assets/images/svg/settings_fill.svg',
              width: 24,
              height: 24,
              colorFilter: const ColorFilter.mode(
                Color(0xFF333333),
                BlendMode.srcIn,
              ),
            ),
          ),
        ),
        Positioned(
          left: 25,
          right: 25,
          top: topPadding + 115,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAccountCard(),
              const SizedBox(height: 12),
              _buildKugouPlaylistEntry(),
            ],
          ),
        ),
      ],
    );
  }

  /// 歌单入口：我喜欢的音乐 / 自建歌单 / 酷狗歌单。
  Widget _buildKugouPlaylistEntry() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: _buildAccountRow(
        icon: Icons.queue_music,
        title: '歌单',
        subtitle: '我喜欢的、自建歌单与酷狗歌单',
        actionText: '进入',
        onTap: _openLibrary,
      ),
    );
  }

  Future<void> _openLibrary() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LibraryPage()),
    );
    if (!mounted) return;
    setState(() {});
  }

  /// 音源账号卡片：网易云一家、酷狗一家，共两行。
  ///
  /// 酷狗概念版与原版本质是同一个账号体系的两个 appid，原先并排占两行，
  /// 看起来像「要登录两个账号」。现在收进一个入口，点开后分别授权。
  Widget _buildAccountCard() {
    final cred = KugouCredentialService.instance;
    final liteLogged = cred.hasCredentialsFor(KugouPlatform.lite);
    final stdLogged = cred.hasCredentialsFor(KugouPlatform.standard);
    final anyKugou = liteLogged || stdLogged;

    final subtitle = switch ((liteLogged, stdLogged)) {
      (true, true) => '已登录 · 概念版 / 原版',
      (true, false) => '已登录 · 概念版',
      (false, true) => '已登录 · 原版',
      _ => '扫码登录后可使用酷狗音源',
    };

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          _buildAccountRow(
            icon: Icons.music_note,
            title: '网易云音乐',
            subtitle: '扫码登录后可使用网易云音源',
            actionText: '扫码登录',
            onTap: _showQrCodeLoginDialog,
          ),
          const Divider(height: 1, indent: 56, endIndent: 16),
          _buildAccountRow(
            icon: Icons.library_music_outlined,
            title: '酷狗音乐',
            subtitle: subtitle,
            actionText: anyKugou ? '管理' : '扫码登录',
            onTap: () => showKugouAccountSheet(context),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required String actionText,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: const Color(0xFF3080FF)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.black87,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFF3080FF),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                actionText,
                style: const TextStyle(
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPlaylistDetail(PlaylistModel playlist) async {
    Navigator.push(
      context,
      fadeSlideRoute(PlaylistDetailPage(playlist: playlist)),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          onLogout: _isLoggedIn ? _clearCookie : null,
        ),
      ),
    );
  }
}

class _QrCodeLoginSheet extends StatefulWidget {
  final MusicApiService apiService;
  final void Function(NeteaseAccountInfoWrap) onLoginSuccess;

  const _QrCodeLoginSheet({
    required this.apiService,
    required this.onLoginSuccess,
  });

  @override
  State<_QrCodeLoginSheet> createState() => _QrCodeLoginSheetState();
}

class _QrCodeLoginSheetState extends State<_QrCodeLoginSheet> {
  String? _qrKey;
  String? _qrUrl;
  String _statusText = '正在获取二维码...';
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
      _statusText = '正在获取二维码...';
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
      _statusText = '请使用网易云音乐 APP 扫码登录';
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
            _statusText = '二维码已过期，请点击刷新';
            _isExpired = true;
          });
          break;
        case 801:
          setState(() {
            _statusText = '等待扫码...';
          });
          break;
        case 802:
          setState(() {
            _statusText = '已扫码，请在手机上确认登录';
          });
          break;
        case 803:
          _pollTimer?.cancel();
          setState(() {
            _statusText = '登录成功！正在获取用户信息...';
          });
          try {
            final info =
                await widget.apiService.handleQrCodeLoginSuccess();
            if (!mounted) return;
            if (info != null) {
              widget.onLoginSuccess(info);
            } else {
              setState(() {
                _statusText = '登录成功但获取用户信息失败，请重试';
              });
            }
          } catch (e) {
            if (!mounted) return;
            setState(() {
              _statusText = '登录处理异常: $e';
            });
          }
          break;
        default:
          debugPrint('⚠️ 未知二维码状态码: $code');
          if (code == -462 || code == 8821) {
            _pollTimer?.cancel();
            setState(() {
              _statusText = '服务器拒绝扫码登录，请使用手动输入 MUSIC_U';
              _isExpired = true;
            });
          }
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '扫码登录',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 24),
          if (_isLoading)
            const SizedBox(
              width: 200,
              height: 200,
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF2F84FE)),
              ),
            )
          else if (_qrUrl != null)
            Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 200,
                  height: 200,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFEEEEEE)),
                  ),
                  child: QrImageView(
                    data: _qrUrl!,
                    version: QrVersions.auto,
                    size: 176,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF1A1A2E),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF1A1A2E),
                    ),
                  ),
                ),
                if (_isExpired)
                  Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.refresh,
                            size: 40,
                            color: Color(0xFF2F84FE),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '二维码已过期',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[600],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 16),
          Text(
            _statusText,
            style: TextStyle(
              fontSize: 14,
              color: _isExpired ? Colors.red : Colors.black54,
            ),
          ),
          const SizedBox(height: 16),
          if (_isExpired)
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                onPressed: _fetchQrCode,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2F84FE),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('刷新二维码', style: TextStyle(fontSize: 15)),
              ),
            ),
        ],
      ),
    );
  }
}

class _AvatarImage extends StatefulWidget {
  final String url;
  const _AvatarImage({required this.url});

  @override
  State<_AvatarImage> createState() => _AvatarImageState();
}

class _AvatarImageState extends State<_AvatarImage> {
  Uint8List? _imageBytes;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final response = await Dio().get(
        '${widget.url.split('?').first}?param=150y150',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        if (mounted) {
          setState(() {
            _imageBytes = response.data as Uint8List;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        width: 72,
        height: 72,
        fit: BoxFit.cover,
      );
    }
    return const Icon(Icons.person, size: 40, color: Colors.grey);
  }
}

class _PlaylistCoverImage extends StatefulWidget {
  final String url;
  const _PlaylistCoverImage({required this.url});

  @override
  State<_PlaylistCoverImage> createState() => _PlaylistCoverImageState();
}

class _PlaylistCoverImageState extends State<_PlaylistCoverImage> {
  Uint8List? _imageBytes;
  bool _loading = true;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 10),
  ));

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final response = await _dio.get(
        '${widget.url.split('?').first}?param=300y300',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'Referer': 'https://music.163.com',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          },
        ),
      );
      if (response.statusCode == 200 && response.data != null) {
        if (mounted) {
          setState(() {
            _imageBytes = response.data as Uint8List;
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (e) {
      debugPrint('🎵 封面加载失败: ${widget.url} | 错误: $e');
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_imageBytes != null) {
      return Image.memory(
        _imageBytes!,
        width: 50,
        height: 50,
        fit: BoxFit.cover,
      );
    }
    return const Icon(Icons.music_note, color: Colors.grey);
  }
}
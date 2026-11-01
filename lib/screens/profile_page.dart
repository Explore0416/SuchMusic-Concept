import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:netease_music_api/netease_music_api.dart';
import '../models/kugou_platform.dart';
import '../models/song_model.dart';

import '../services/music_api_service.dart';
import '../services/app_init.dart';
import '../services/kugou_credential_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/fade_slide_in.dart';
import '../widgets/login_sheet.dart';
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
    final userId = _cachedUserId ?? _userInfo?.profile?.userId.toString();
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

  /// 打开统一登录弹层：一个入口登录全部音源，页面里不再重复挂账号入口。
  Future<void> _openLogin({LoginSource initial = LoginSource.netease}) async {
    await showLoginSheet(
      context,
      apiService: _apiService,
      initial: initial,
      onNeteaseLoggedIn: (info) {
        Navigator.maybePop(context);
        setState(() {
          _isLoggedIn = true;
          _userInfo = info;
          _cachedNickname = _apiService.cachedNickname;
          _cachedAvatarUrl = _apiService.cachedAvatarUrl;
          _cachedUserId = _apiService.cachedUserId;
        });
        _loadPlaylists();
      },
    );
    if (!mounted) return;
    // 酷狗是在弹层里二级授权的，回来要刷新一次状态
    setState(() {});
  }

  /// 已连接的音源名称，用于身份卡副标题。
  String _connectedSources() {
    final cred = KugouCredentialService.instance;
    final kugou =
        cred.hasCredentialsFor(KugouPlatform.lite) ||
        cred.hasCredentialsFor(KugouPlatform.standard);
    final names = <String>[if (_isLoggedIn) '网易云', if (kugou) '酷狗'];
    if (names.isEmpty) return '账号已失效，点这里重新登录';
    return '已连接 ${names.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        child: KeyedSubtree(
          key: ValueKey(_isLoggedIn),
          child: _isLoggedIn ? _buildLoggedPage() : _buildUnloggedPage(),
        ),
      ),
    );
  }

  Widget _pageShell(List<Widget> children) {
    return ListView(
      padding: const EdgeInsets.only(bottom: AppLayout.bottomInsetWithPlayer),
      children: [
        // 设置只在「通用」分组里保留一个入口：右上角再来个齿轮属于重复。
        const AppPageHeader(title: '我的'),
        ...children,
        const SizedBox(height: AppSpace.xxxl),
      ],
    );
  }

  Widget _buildLoggedPage() {
    final profile = _userInfo?.profile;
    final nickname = profile?.nickname ?? _cachedNickname ?? '未知用户';
    final avatarUrl = profile?.avatarUrl ?? _cachedAvatarUrl ?? '';
    final vipType =
        _userInfo?.profile?.vipType ?? _userInfo?.account?.vipType ?? 0;

    return _pageShell([
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: _buildIdentityCard(
          nickname: nickname,
          avatarUrl: avatarUrl,
          vipType: vipType,
          loggedIn: true,
        ),
      ),
      const SizedBox(height: AppSpace.xxl),
      AppSectionHeader(
        title: '我的歌单',
        actionLabel: _playlists.isEmpty ? null : '刷新',
        onAction: _playlists.isEmpty ? null : _loadPlaylists,
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: _buildPlaylistList(),
      ),
      const SizedBox(height: AppSpace.xxl),
      const AppSectionHeader(title: '通用'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: _buildSettingsCard(),
      ),
    ]);
  }

  Widget _buildUnloggedPage() {
    return _pageShell([
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: _buildIdentityCard(
          nickname: '未登录',
          avatarUrl: '',
          vipType: 0,
          loggedIn: false,
        ),
      ),
      const SizedBox(height: AppSpace.xxl),
      // 未登录时页面会显得空，这里把「登录能得到什么」讲清楚，
      // 而不是留一大片白让人不知道自己错过了什么。
      const AppSectionHeader(title: '登录后可以'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: AppCard(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.xs,
          ),
          child: Column(
            children: const [
              _FeatureLine(
                icon: Icons.queue_music_rounded,
                title: '云端歌单',
                desc: '这里会列出你在网易云、酷狗收藏的歌单',
              ),
              AppHairline(indent: 44),
              _FeatureLine(
                icon: Icons.insights_rounded,
                title: '每日推荐与私人 FM',
                desc: '按你实际听的口味每天换一批，不用再猜',
              ),
              AppHairline(indent: 44),
              _FeatureLine(
                icon: Icons.swap_horiz_rounded,
                title: '两个音源一起用',
                desc: '网易云与酷狗分别登录，缺歌时自动换源',
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: AppSpace.xxl),
      const AppSectionHeader(title: '通用'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.page),
        child: _buildSettingsCard(),
      ),
    ]);
  }

  /// 身份卡：登录前后共用同一骨架，只换头像、文案与右侧动作。
  Widget _buildIdentityCard({
    required String nickname,
    required String avatarUrl,
    required int vipType,
    required bool loggedIn,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        // 已登录时点卡片同样是进登录弹层：切换音源 / 重新授权都在里面
        onTap: _openLogin,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFF0F3FF), Color(0xFFFFFFFF)],
            ),
            border: Border.all(color: AppColors.hairline, width: 0.7),
          ),
          child: Row(
            children: [
              ClipOval(
                child: Container(
                  width: 56,
                  height: 56,
                  color: AppColors.surfaceMuted,
                  child: avatarUrl.isNotEmpty
                      ? _AvatarImage(url: avatarUrl)
                      : const Icon(
                          Icons.person_rounded,
                          size: 28,
                          color: AppColors.inkTertiary,
                        ),
                ),
              ),
              const SizedBox(width: AppSpace.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 20,
                              height: 1.25,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              color: AppColors.ink,
                            ),
                          ),
                        ),
                        if (vipType != 0) ...[
                          const SizedBox(width: AppSpace.sm),
                          const AppTag(
                            text: 'VIP',
                            color: AppColors.brand,
                            background: AppColors.brandSoft,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      loggedIn ? _connectedSources() : '登录后同步歌单与每日推荐',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.md),
              if (!loggedIn)
                FilledButton(
                  onPressed: () => _openLogin(),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  child: const Text('登录'),
                )
              else
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: AppColors.inkDisabled,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistList() {
    if (_loadingPlaylists) {
      return const AppCard(
        child: Padding(
          padding: EdgeInsets.all(AppSpace.xl),
          child: Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    if (_playlists.isEmpty) {
      return AppCard(
        child: AppEmptyState(
          icon: Icons.queue_music_rounded,
          title: '暂无歌单',
          message: '在网易云创建歌单后会显示在这里',
          compact: true,
        ),
      );
    }
    return AppCard(
      child: Column(
        children: [
          for (var i = 0; i < _playlists.length; i++) ...[
            if (i > 0) const AppHairline(indent: 76),
            _buildPlaylistItem(_playlists[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildPlaylistItem(PlaylistModel playlist) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _openPlaylistDetail(playlist),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: 10,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 44,
                  height: 44,
                  color: AppColors.surfaceMuted,
                  child: playlist.coverUrl != null
                      ? _PlaylistCoverImage(url: playlist.coverUrl!)
                      : const Icon(
                          Icons.music_note_rounded,
                          size: 20,
                          color: AppColors.inkTertiary,
                        ),
                ),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${playlist.trackCount ?? 0} 首',
                      style: AppType.caption.copyWith(
                        color: AppColors.inkTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: AppColors.inkDisabled,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsCard() {
    return AppCard(
      child: AppListTile(
        icon: Icons.settings_outlined,
        iconColor: AppColors.inkSecondary,
        iconBackground: AppColors.surfaceMuted,
        title: '设置',
        subtitle: '音效、下载、关于与更新',
        onTap: _openSettings,
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
        builder: (_) =>
            SettingsPage(onLogout: _isLoggedIn ? _clearCookie : null),
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

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

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

/// 未登录页的能力说明行：图标 + 标题 + 一句白话
class _FeatureLine extends StatelessWidget {
  const _FeatureLine({
    required this.icon,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.md),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: AppColors.surfaceMuted,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppColors.inkSecondary),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: AppType.body),
                const SizedBox(height: 2),
                Text(
                  desc,
                  style: AppType.caption.copyWith(color: AppColors.inkTertiary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

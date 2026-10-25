import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/update_checker.dart';
import '../utils/responsive.dart';
import 'agreement_page.dart';
import 'changelog_page.dart';

/// 关于页面
/// 布局参考 cankao/1.txt 设计稿（430x932）
/// 流光背景参考 cankao/Qii - 动态流光（测试）.jsx：
/// 多个大尺寸径向渐变光斑（色→透明）以错开的周期缓慢漂移，形成流动光感
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> with TickerProviderStateMixin {
  late final List<AnimationController> _blobCtrls;

  /// 当前App版本，从 package_info 读取（与 pubspec version 保持一致）
  String _appVersion = '1.0.0';

  /// 开发者弹幕：每点一次「开发者们」就在本页飘过一轮，可叠加多轮
  Ticker? _danmakuTicker;
  Duration _danmakuElapsed = Duration.zero;
  final List<_DanmakuItem> _danmakuItems = [];
  int _danmakuWaves = 0;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    // 三个光斑的漂移周期错开（对应 jsx 中的 20s/23s/25s）
    _blobCtrls = [
      AnimationController(
        vsync: this,
        duration: const Duration(seconds: 20),
      )..repeat(reverse: true),
      AnimationController(
        vsync: this,
        duration: const Duration(seconds: 23),
      )..repeat(reverse: true),
      AnimationController(
        vsync: this,
        duration: const Duration(seconds: 25),
      )..repeat(reverse: true),
    ];
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = info.version);
    });
  }

  @override
  void dispose() {
    _danmakuTicker?.dispose();
    for (final c in _blobCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  /// 动态流光背景：底色 + 三个缓慢漂移的径向渐变光斑
  Widget _buildFlowBackground(Size size) {
    final w = size.width;
    final h = size.height;
    return Positioned.fill(
      child: Stack(
        children: [
          const Positioned.fill(
            child: ColoredBox(color: Color(0xFFF2F4F8)),
          ),
          _blob(
            _blobCtrls[0],
            color: const Color(0x402F84FE), // 主题蓝
            diameter: w * 1.35,
            from: Offset(-w * 0.25, -h * 0.30),
            to: Offset(w * 0.45, h * 0.10),
          ),
          _blob(
            _blobCtrls[1],
            color: const Color(0x3816CDFF), // Logo 浅蓝
            diameter: w * 1.50,
            from: Offset(w * 0.10, h * 0.35),
            to: Offset(-w * 0.40, h * 0.02),
          ),
          _blob(
            _blobCtrls[2],
            color: const Color(0x309CC5FF), // 主题蓝混白
            diameter: w * 1.25,
            from: Offset(w * 0.30, h * 0.50),
            to: Offset(w * 0.55, h * 0.05),
          ),
        ],
      ),
    );
  }

  /// 单个流光光斑：超大径向渐变圆（色→透明），在 from↔to 之间往返漂移
  Widget _blob(
    Animation<double> anim, {
    required Color color,
    required double diameter,
    required Offset from,
    required Offset to,
  }) {
    return AnimatedBuilder(
      animation: anim,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(anim.value);
        return Positioned(
          left: 0,
          top: 0,
          child: Transform.translate(
            offset: Offset.lerp(from, to, t)!,
            child: child,
          ),
        );
      },
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final danmakuSeconds = _danmakuElapsed.inMicroseconds / 1e6;
    // 设计稿卡片左右边距 29/430，按内容宽度（受 960 上限约束）等比缩放
    final contentW = Responsive.contentWidth(size);
    final cardMargin = contentW * 29 / 430;
    // logo 宽：设计稿 367/430 屏宽，缩小 10%，并设 460 上限
    final logoWidth = min(contentW * 367 / 430 * 0.9, 460.0);

    return Scaffold(
      body: Stack(
        children: [
          _buildFlowBackground(size),
          SafeArea(
            child: Stack(
              children: [
                ResponsiveContent(
                  child: Column(
                    children: [
                      SizedBox(height: size.height * 0.15),
                      // 概念版标识：克制的字母间距标签（原版无此行），用主色弱化呈现
                      Text(
                        'SUCHMUSIC',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 6,
                          fontWeight: FontWeight.w600,
                          color: _themeBlue.withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(height: 10),
                      // Such Music 字标 SVG（设计稿 logo 区域 367/430 屏宽，缩小 10%）
                      SvgPicture.asset(
                        'assets/images/Such_music_sxt.svg',
                        width: logoWidth,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 12),
                      // 版本 + 概念版徽章同一行：视觉重量与原版一致，但表明这是概念版
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            'v $_appVersion',
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF7C7C7C)),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 2),
                            decoration: BoxDecoration(
                              color: _themeBlue.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '概念版',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: _themeBlue,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Expanded(child: Container()),
                      Container(
                        margin: EdgeInsets.symmetric(horizontal: cardMargin),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(17),
                        ),
                        child: Column(
                          children: [
                            _buildMenuRow(
                              '检查更新',
                              onTap: _checkUpdate,
                            ),
                            ..._menuItems.map(
                              (title) => _buildMenuRow(
                                title,
                                onTap: switch (title) {
                                  '更新日志' => _openChangelog,
                                  '官方社群' => _openCommunity,
                                  '使用协议' => _openAgreement,
                                  '开发者们' => _startDeveloperDanmaku,
                                  '免责声明' => _showDisclaimer,
                                  _ => null,
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      // 概念版定位说明：一行小字，与流光背景同灰阶，不抢卡片注意力
                      Text(
                        '独立开发 · 与官方版无隶属或合作关系',
                        style: TextStyle(
                          fontSize: 11,
                          color: const Color(0xFF9A9AA0).withValues(alpha: 0.9),
                        ),
                      ),
                      SizedBox(height: size.height * 0.19),
                    ],
                  ),
                ),
                // 开发者弹幕层：不拦截点击，飘在内容上方
                if (_danmakuItems.isNotEmpty)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: ClipRect(
                        child: Stack(
                          children: [
                            for (final item in _danmakuItems)
                              _buildDanmaku(size, item, danmakuSeconds),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  left: 4,
                  top: 4,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context),
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(
                        Icons.arrow_back_ios_new,
                        size: 20,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static const List<String> _menuItems = [
    '更新日志',
    '官方社群',
    '使用协议',
    '免责声明',
    '开发者们',
  ];

  static const Color _themeBlue = Color(0xFF2F84FE);

  Widget _buildMenuRow(String title, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap, // 空 onTap 为占位：后续可跳转对应页面
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15, color: Colors.black),
            ),
            const Spacer(),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: Color(0xFFCCCCCC),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开使用协议页面
  void _openAgreement() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AgreementPage()),
    );
  }

  /// 免责声明（Q8=A）：酷狗概念版为第三方逆向接口，仅透传用户自有合法凭证
  void _showDisclaimer() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('免责声明'),
        content: const SingleChildScrollView(
          child: Text(
            '1. 本应用为个人学习与技术研究用途的非官方客户端，与任何音乐平台均无关联。\n\n'
            '2. 「酷狗概念版」音源相关接口为第三方逆向接口，可能随时变更或失效，'
            '本应用不保证其可用性。\n\n'
            '3. 本应用仅透传用户自行提供的合法账号凭证，不破解、不绕过任何版权限制，'
            '不提供任何付费内容。\n\n'
            '4. 请使用者在合法合规范围内使用，由此产生的任何法律责任由使用者自行承担。',
            style: TextStyle(fontSize: 14, height: 1.6),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('我知道了', style: TextStyle(color: _themeBlue)),
          ),
        ],
      ),
    );
  }

  /// 点击「开发者们」：在本页新增一轮弹幕（名字/职位从右向左飘过）
  void _startDeveloperDanmaku() {
    final now = _danmakuElapsed.inMicroseconds / 1e6;
    final wave = _danmakuWaves++;
    for (var i = 0; i < _developers.length; i++) {
      _danmakuItems.add(_DanmakuItem(
        devIndex: i,
        startSeconds: now + i * 0.9, // 同一轮内依次错开进入
        period: 9.0 + ((i + wave) % 4) * 2.5,
        // 纵向位置每条随机（屏高 8%~80%），多轮之间再错开一点
        topFraction: 0.08 + _random.nextDouble() * 0.72,
        trackOffset: (wave % 4) * 12.0,
      ));
    }
    _danmakuTicker ??= createTicker((elapsed) {
      _danmakuElapsed = elapsed;
      final t = elapsed.inMicroseconds / 1e6;
      _danmakuItems.removeWhere((it) => t - it.startSeconds >= it.period);
      if (mounted) setState(() {});
    });
    if (!_danmakuTicker!.isActive) _danmakuTicker!.start();
    setState(() {});
  }

  /// 单条开发者弹幕：从右侧屏外飘到左侧屏外
  Widget _buildDanmaku(Size size, _DanmakuItem item, double seconds) {
    final dev = _developers[item.devIndex];
    final i = item.devIndex;
    final progress =
        ((seconds - item.startSeconds) / item.period).clamp(0.0, 1.0);
    // 起点在右侧屏外（x = 屏宽），终点在左侧屏外（x = -屏宽），保证完全飘出
    final x = size.width - progress * size.width * 2;
    // 纵向位置：出生时随机决定
    final top = size.height * item.topFraction + item.trackOffset;
    final fontSize = 16.0 + (i % 3) * 3.0;
    // 进出屏幕两端时淡入淡出
    final opacity =
        (progress * 10).clamp(0.0, 1.0) * ((1 - progress) * 10).clamp(0.0, 1.0);

    return Positioned(
      left: 0,
      top: top,
      child: Transform.translate(
        offset: Offset(x, 0),
        child: Opacity(
          opacity: opacity,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                dev.name,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF2F84FE),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                dev.role,
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 更新日志：展示历代所有版本（数据来自打包进 App 的 CHANGELOG.md）
  void _openChangelog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ChangelogPage()),
    );
  }

  /// 官方社群：先让用户选「原版交流群」还是「二开团队群」
  Future<void> _openCommunity() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: false,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                '官方社群',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF333333),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '请选择要加入的群',
                style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
              ),
              const SizedBox(height: 12),
              _buildCommunityTile(
                title: '原版 · Such 交流群',
                subtitle: '群号 $kQQGroupNumber',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openContact();
                },
              ),
              const SizedBox(height: 8),
              _buildCommunityTile(
                title: '二开 · 闪电科技团队官方交流群',
                subtitle: '点击链接加入群聊',
                onTap: () {
                  Navigator.of(ctx).pop();
                  _openTeamGroup();
                },
              ),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => Navigator.of(ctx).pop(),
                behavior: HitTestBehavior.opaque,
                child: const SizedBox(
                  height: 48,
                  child: Center(
                    child: Text(
                      '取消',
                      style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCommunityTile({
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 15),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6F8),
          borderRadius: BorderRadius.circular(13),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF999999),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: Color(0xFFCCCCCC),
            ),
          ],
        ),
      ),
    );
  }

  /// 二开团队群：走 QQ 的 universal-share 链接（未装 QQ 时退化为浏览器打开）
  Future<void> _openTeamGroup() async {
    final uri = Uri.parse(kTeamQQGroupUrl);
    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      await launchUrl(uri, mode: LaunchMode.platformDefault);
    }
  }

  /// 联系我们：唤起QQ群名片；未安装QQ（或唤起失败）时弹窗展示群号供复制
  Future<void> _openContact() async {
    final uri = Uri.parse(
      'mqqapi://card/show_pslcard?src_type=internal&version=1'
      '&uin=$kQQGroupNumber&card_type=group&source=qrcode',
    );
    bool ok = false;
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && mounted) _showGroupNumberDialog();
  }

  /// 唤起QQ失败时的兜底：展示QQ群号，可一键复制
  void _showGroupNumberDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('联系我们'),
        content: Text('QQ群：$kQQGroupNumber\n（未检测到QQ，可复制群号手动添加）'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: Color(0xFF999999))),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(const ClipboardData(text: kQQGroupNumber));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制QQ群号')),
              );
            },
            child: const Text(
              '复制群号',
              style: TextStyle(color: _themeBlue, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 检查更新：交给 UpdateChecker 统一处理（弹窗/下载/安装）
  Future<void> _checkUpdate() async {
    await UpdateChecker.check(context);
  }
}

class _Dev {
  final String name;
  final String role;
  const _Dev(this.name, this.role);
}

/// 单条弹幕数据
class _DanmakuItem {
  final int devIndex;
  final double startSeconds; // 出生时刻（弹幕时钟，含同轮错开延迟）
  final double period; // 单程耗时（秒）
  final double topFraction; // 纵向位置（屏高比例，出生时随机）
  final double trackOffset; // 波次纵向偏移（px）
  const _DanmakuItem({
    required this.devIndex,
    required this.startSeconds,
    required this.period,
    required this.topFraction,
    required this.trackOffset,
  });
}

// 开发者名单：弹幕展示用
const List<_Dev> _developers = [
  _Dev('夕落', '手机端开发'),
  _Dev('小风', 'UI'),
  _Dev('酶游明', 'PC端开发'),
  _Dev('闪电科技团队', '手机、平板端二次开发'),
];

// QQ群号：联系我们跳转用
const String kQQGroupNumber = '677063599';

/// 二开团队群（闪电科技团队官方交流群）分享链接
const String kTeamQQGroupUrl =
    'https://qun.qq.com/universal-share/share?ac=1&authKey=xmzJlkDUVWFwudrqNvMoXC%2BTgZvVtrUK3uNqPBoh6JdewyNehl%2BAnNP6iHoKUFgT&busi_data=eyJncm91cENvZGUiOiIxMDg3Mzc2ODk2IiwidG9rZW4iOiJPQnRyQWRaQmhxaElKOURVTXZJTTJjK1RoS0RjRVJCdDVhWGlpRTU2SWx1TDQveEUwS3EzKzV0L25OMFpQdS9iIiwidWluIjoiMTk4OTgzMzYyNSJ9&data=NmmD0-39RllYb9oj_2riS82fczqKUdNJOjx6qBu47bx6kEGzvm9CM35teoGRD6KyOVXI7KDLtg6D4Rm6zJGQ6Q&svctype=4&tempid=h5_group_info';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/design_dialog.dart';

/// 使用协议页面
/// 展示《Such Music 用户协议》全文
/// 返回按钮与配色风格与关于页保持一致
class AgreementPage extends StatelessWidget {
  const AgreementPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F4F8),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(
                  height: 44,
                  child: Center(
                    child: Text(
                      '使用协议',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(15, 8, 15, 24),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(18, 20, 18, 24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(17),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Center(
                            child: Text(
                              'Such Music 用户协议',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF333333),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Center(
                            child: Text(
                              '版本号：v1.0｜更新日期：2026-10-05｜生效日期：2026-10-05',
                              style: TextStyle(
                                  fontSize: 11.5, color: Color(0xFF999999)),
                            ),
                          ),
                          const SizedBox(height: 14),
                          // 重点提示：重大利害关系条款已加粗
                          Text.rich(
                            TextSpan(
                              children: [
                                const TextSpan(
                                  text: '【请您注意】',
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.6,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF333333),
                                  ),
                                ),
                                const TextSpan(
                                  text:
                                      '本协议中与您的权益有重大利害关系的条款（特别是第二条、第三条、第七条）已加粗，提请您重点阅读。首次启动本软件时，我们将以弹窗方式请您阅读并勾选确认本协议。',
                                  style: _bodyStyle,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '使用本软件即代表您已阅读、理解并同意本用户协议全部条款。',
                            style: _boldBodyStyle,
                          ),
                          for (final s in _sections) ..._buildSection(s),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // 返回按钮：与关于页一致
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
    );
  }

  static const _bodyStyle = TextStyle(
    fontSize: 13.5,
    height: 1.6,
    color: Color(0xFF666666),
  );

  static const _boldBodyStyle = TextStyle(
    fontSize: 13.5,
    height: 1.6,
    fontWeight: FontWeight.w600,
    color: Color(0xFF333333),
  );

  List<Widget> _buildSection(_Section s) {
    return [
      const SizedBox(height: 18),
      Text(
        s.title,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Color(0xFF333333),
        ),
      ),
      for (final p in s.paragraphs) ...[
        const SizedBox(height: 6),
        Text(p.text, style: p.bold ? _boldBodyStyle : _bodyStyle),
      ],
    ];
  }
}

/// 单条条款：bold 为 true 时加粗显示（重大利害关系条款）
class _Para {
  final String text;
  final bool bold;
  const _Para(this.text, {this.bold = false});
}

class _Section {
  final String title;
  final List<_Para> paragraphs;
  const _Section(this.title, this.paragraphs);
}

const List<_Section> _sections = [
  _Section('一、协议的接受', [
    _Para('1.1 本协议是您与 Such Music 开发团队（以下简称“我们”）之间关于使用本软件预编译版本及相关服务的约定。'),
    _Para('1.2 若您不同意本协议任何内容，请立即停止使用并卸载本软件。'),
    _Para('1.3 本协议适用于官方渠道发布的预编译版本。本软件的源代码依照对应开源许可证发布，源代码的使用、修改与再分发遵循该开源许可证，不受本协议约束。'),
  ]),
  _Section('二、软件性质', [
    _Para('2.1 Such Music 是一款第三方开源音乐播放器，与网易云音乐及网易公司不存在任何隶属、合作或授权关系。'),
    _Para(
      '2.2 本软件由个人出于学习、研究目的开发，仅供个人学习、研究与交流使用，不用于任何商业目的。本软件通过调用开源社区第三方接口项目（以下简称“接口项目”）获取音乐信息，该接口项目及其所调用的平台接口均未获得相关平台或版权方授权，其可用性、稳定性与合规性不受我们控制，由此产生的风险由您自行判断并承担。',
      bold: true,
    ),
    _Para('2.3 平台内音乐、图片、文字等内容的版权均归原权利人所有。本软件不存储、不上传、不修改任何音频文件，音频流由第三方平台接口实时返回。'),
    _Para('2.4 本软件在本地产生的歌曲缓存仅用于保障本地流畅播放的临时数据，不构成对任何内容的下载授权，您不得将缓存文件导出、传播或用于其他用途。'),
    _Para('2.5 第三方开源组件：本软件使用了若干第三方开源组件（包括2.2所述的接口项目），各组件的权利与义务以其对应的开源许可证为准，相关许可声明随本软件一并提供（见“设置 → 关于 → 开源许可”）。我们不对第三方组件的功能、安全性与持续性负责。'),
    _Para(
      '2.6 本软件不提供任何形式的会员权限破解、解密或绕过功能。歌曲能否播放完全取决于您登录账号自身的权限状态：您账号在官方客户端可播放的内容，本软件可播放；您账号无权限访问的内容（如非会员账号的会员专享歌曲），本软件同样无法播放。',
      bold: true,
    ),
  ]),
  _Section('三、账号与登录', [
    _Para('3.1 您可以使用网易云音乐账号扫码登录。登录凭据仅加密存储于您的设备本地，本软件不会将其上传至任何服务器。'),
    _Para('3.2 请妥善保管您的账号与设备，因保管不当造成的账号相关损失由您自行承担。'),
    _Para(
      '3.3 您理解并同意，使用本软件登录网易云音乐账号属于非官方客户端使用行为，存在账号被限流、风控甚至封禁的风险，由此产生的一切账号相关后果由您自行承担。',
      bold: true,
    ),
  ]),
  _Section('四、用户数据与隐私', [
    _Para('4.1 本软件不架设后台服务器，不主动收集、不上传您的个人数据。'),
    _Para('4.2 为实现应用功能，本软件会在设备本地保存登录凭据、播放记录、图片与歌曲缓存等数据，这些数据不会离开您的设备。'),
    _Para('4.3 您可以随时在“设置”页清除缓存或退出登录以删除本地数据，卸载本软件即彻底删除全部本地数据。'),
  ]),
  _Section('五、知识产权', [
    _Para('5.1 本软件源代码依照对应开源许可证发布，您可在该许可证允许的范围内使用与修改。开源许可证仅授予源代码层面的权利，不授予本软件名称、标识的任何使用权。'),
    _Para('5.2 本软件内呈现的音乐、图片、文字等内容版权归原权利人所有，未经权利人授权，您不得将其下载、导出、传播或用于商业用途（本地临时缓存除外，见2.4）。'),
  ]),
  _Section('六、使用规范', [
    _Para('您在使用本软件时，不得实施以下行为：'),
    _Para('6.1 将本软件或其获取的内容用于商业用途；'),
    _Para('6.2 未经开发者书面授权，对官方预编译版本进行二次封装、修改后对外分发，或去除、篡改本软件的版权信息与本协议；对源代码的修改与再分发须遵循对应开源许可证并注明出处；'),
    _Para('6.3 滥用接口，包括但不限于高频请求、批量抓取、爬取数据；'),
    _Para('6.4 利用本软件从事任何违反法律法规或公序良俗的活动；'),
    _Para('6.5 将缓存文件导出、上传至网络或以其他方式传播（见2.4）。'),
  ]),
  _Section('七、免责声明', [
    _Para(
      '7.1 本软件按“现状”提供，我们不对功能的完整性、可用性与稳定性作任何保证；第三方平台接口变更、限制，可能造成部分或全部功能失效。',
      bold: true,
    ),
    _Para(
      '7.2 对于因使用或无法使用本软件造成的任何直接或间接损失，我们不承担责任；但法律另有强制性规定的除外。',
      bold: true,
    ),
    _Para('7.3 本软件仅供个人学习交流使用，请支持正版音乐。'),
    _Para(
      '7.4 本软件不具备、亦不提供任何破解会员权限或绕过版权保护机制的功能，可播放内容范围与您登录账号在官方客户端权限完全一致。使用者需自行遵守著作权相关法律法规。',
      bold: true,
    ),
  ]),
  _Section('八、协议的变更与终止', [
    _Para('8.1 本软件更新时可能对本协议进行调整，调整后将通过应用内公告等显著方式提示您。涉及与您有重大利害关系的变更，需经您重新确认后方可生效；若您不同意变更内容，可停止使用并卸载本软件。'),
    _Para('8.2 您可随时停止使用并卸载本软件以终止本协议。'),
  ]),
  _Section('九、适用法律与争议解决', [
    _Para('9.1 本协议受中华人民共和国法律管辖。若发生争议，双方优先友好协商；协商不成，任何一方均可向本协议签署地（开发者经常居住地）有管辖权的人民法院提起诉讼。'),
    _Para('9.2 本协议部分条款被认定无效时，其余条款仍然有效。'),
  ]),
  _Section('十、未成年人条款', [
    _Para('10.1 若您为未成年人，请在监护人陪同下阅读本协议，并取得监护人同意后方可使用本软件。'),
    _Para('10.2 监护人应当对未成年人的使用行为及由此产生的后果承担相应责任。'),
  ]),
  _Section('十一、联系我们', [
    _Para('如对本协议有任何疑问或建议，可通过应用内“联系我们”、发送邮件至 sunset5277@qq.com，或于开源仓库提交 Issue 与我们取得联系。'),
  ]),
  _Section('十二、协议文本', [
    _Para('12.1 本协议中文版本为唯一有效版本；任何翻译版本仅供参考，如有冲突，以中文版本为准。'),
  ]),
];

/// 协议版本号：协议内容发生重大变更时更新此版本号，将触发用户重新确认
const String kAgreementVersion = 'v1.1';

/// 协议同意状态的本地存取
class UserAgreement {
  static const String _prefKey = 'user_agreement_accepted_version';

  /// 是否已同意当前版本协议
  static Future<bool> isAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKey) == kAgreementVersion;
  }

  /// 记录已同意当前版本协议
  static Future<void> accept() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, kAgreementVersion);
  }
}

/// 首次启动（或协议更新后）弹出协议确认弹窗；已同意则直接返回 true
Future<bool> showAgreementConsentDialogIfNeed(BuildContext context) async {
  if (await UserAgreement.isAgreed()) return true;
  if (!context.mounted) return false;
  final agreed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _AgreementConsentDialog(),
  );
  return agreed ?? false;
}

/// 首启协议确认弹窗（设计稿统一样式）：
/// 协议要点滚动到底部 + 勾选同意后才能进入App，否则只能退出
class _AgreementConsentDialog extends StatefulWidget {
  const _AgreementConsentDialog();

  @override
  State<_AgreementConsentDialog> createState() =>
      _AgreementConsentDialogState();
}

class _AgreementConsentDialogState extends State<_AgreementConsentDialog> {
  static const Color _themeBlue = Color(0xFF2F84FE);
  bool _agreed = false;
  bool _hasRead = false; // 协议要点是否已滚动到底部
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    // 内容不足一屏（无可滚动距离）时直接视为已读完
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollCtrl.hasClients && _scrollCtrl.position.maxScrollExtent <= 8) {
        setState(() => _hasRead = true);
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  bool get _canAgree => _hasRead && _agreed;

  /// 打开协议全文页面
  void _openFullAgreement() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AgreementPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final k = DesignDialog.s(context);
    return PopScope(
      canPop: false, // 返回键不能跳过协议
      child: DesignDialog.shell(
        context,
        child: DesignDialog.card(
          context,
          children: [
            DesignDialog.title(context, '用户协议'),
            SizedBox(height: 12 * k),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 420 * k),
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.pixels >= n.metrics.maxScrollExtent - 8) {
                    if (!_hasRead) setState(() => _hasRead = true);
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scrollCtrl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DesignDialog.body(
                          context, '欢迎使用 Such Music！在开始使用前，请您重点了解：'),
                      SizedBox(height: 8 * k),
                      DesignDialog.body(
                          context,
                          '· 本软件为第三方开源音乐播放器，与网易云音乐官方不存在任何隶属、合作或授权关系，仅供个人学习、研究与交流使用；'),
                      SizedBox(height: 6 * k),
                      DesignDialog.body(
                          context,
                          '· 扫码登录属于非官方客户端使用行为，您的账号存在被限流、风控甚至封禁的风险，相关后果由您自行承担；'),
                      SizedBox(height: 6 * k),
                      DesignDialog.body(
                          context,
                          '· 登录凭据与个人数据仅加密保存在本机，本软件不设服务器、不上传任何个人数据；'),
                      SizedBox(height: 6 * k),
                      DesignDialog.body(
                          context,
                          '· 本软件不提供任何会员权限破解功能，可播放范围与您账号在官方客户端的权限完全一致。'),
                      SizedBox(height: 10 * k),
                      GestureDetector(
                        onTap: _openFullAgreement,
                        behavior: HitTestBehavior.opaque,
                        child: Text(
                          '点击查看《Such Music 用户协议》全文 >',
                          style: TextStyle(
                            fontSize: 12.5 * k,
                            color: _themeBlue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!_hasRead) ...[
              SizedBox(height: 6 * k),
              Text(
                '请先将上方协议内容阅读至底部',
                style: TextStyle(
                    fontSize: 11.5 * k, color: const Color(0xFF999999)),
              ),
            ],
            SizedBox(height: 10 * k),
            // 勾选行
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _agreed = !_agreed),
              child: Row(
                children: [
                  SizedBox(
                    width: 22 * k,
                    height: 22 * k,
                    child: Checkbox(
                      value: _agreed,
                      onChanged: (v) => setState(() => _agreed = v ?? false),
                      activeColor: _themeBlue,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  SizedBox(width: 8 * k),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: '我已阅读并同意 ',
                        style: TextStyle(
                            fontSize: 12.5 * k, color: const Color(0xFF333333)),
                        children: [
                          TextSpan(
                            text: '《Such Music 用户协议》',
                            style: TextStyle(
                              fontSize: 12.5 * k,
                              color: _themeBlue,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 18 * k),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                DesignDialog.cancelText(context, '不同意并退出',
                    () => SystemNavigator.pop()),
                SizedBox(width: 12 * k),
                DesignDialog.confirmButton(
                  context,
                  '同意并继续',
                  _canAgree
                      ? () async {
                          await UserAgreement.accept();
                          if (!context.mounted) return;
                          Navigator.of(context).pop(true);
                        }
                      : null,
                  enabled: _canAgree,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

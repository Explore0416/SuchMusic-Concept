import 'dart:async';

import 'package:flutter/material.dart';

import '../services/band/band_service.dart';
import '../utils/responsive.dart';
import '../widgets/design_dialog.dart';

/// 手环设置页（小米手环绑定与音乐控制）。
///
/// 风格与「音效」「错误日志」等设置卡片一致：白底圆角卡片、主色 `#2F84FE`。
/// 展示：连接状态 / SDK 是否就绪 / 快应用是否已安装 + 启用开关 + 绑定指引 + 隐私说明。
class BandPage extends StatefulWidget {
  const BandPage({super.key});

  @override
  State<BandPage> createState() => _BandPageState();
}

class _BandPageState extends State<BandPage> {
  final BandService _band = BandService.instance;
  StreamSubscription<BandConnectionState>? _stateSub;
  bool _busy = false;

  // 中继功能移除后不再使用；保留以便将来恢复局域网控制
  // ignore: unused_field, prefer_final_fields
  bool _showToken = false;

  /// 原生适配器诊断（nodeId / 权限 / 安装状态 / 最近错误），用于定位连接失败。
  Map<String, dynamic>? _diag;

  Future<void> _loadDiag() async {
    try {
      final d = await _band.diagnose();
      if (mounted && d != null) setState(() => _diag = d);
    } catch (_) {
      // 诊断读取失败不影响主流程
    }
  }

  @override
  void initState() {
    super.initState();
    // 进入页面刷新一次真实状态（SDK / 连接 / 快应用安装）
    _band.refresh().then((_) {
      if (mounted) setState(() {});
      _loadDiag();
    });
    _stateSub = _band.onStateChanged.listen((_) {
      if (mounted) setState(() {});
      _loadDiag();
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await _band.refresh();
    if (mounted) setState(() => _busy = false);
    await _loadDiag();
  }

  Future<void> _toggleEnabled(bool value) async {
    setState(() => _busy = true);
    await _band.setEnabled(value);
    await _band.refresh();
    if (!mounted) return;
    setState(() => _busy = false);
    if (value && !_band.sdkReady) {
      DesignToast.show(context, '手环 SDK 未就绪，请先按指引放置 AAR 后重新构建');
    }
  }
  String get _stateText => switch (_band.state) {
        BandConnectionState.ready => '已连接',
        BandConnectionState.connecting => '连接中…',
        BandConnectionState.disconnected => '未连接',
        BandConnectionState.unavailable => '不可用',
      };

  Color get _stateColor => switch (_band.state) {
        BandConnectionState.ready => const Color(0xFF2F84FE),
        BandConnectionState.connecting => const Color(0xFFFF9800),
        _ => const Color(0xFF838383),
      };

  String get _wearAppText => switch (_band.wearAppInstallState) {
        'installed' => '已安装',
        'not_installed' => '未安装',
        _ => '未知',
      };

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final s = Responsive.uiScale(size);
    final topPadding = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: const Color(0xFFF1F2F4),
      body: Column(
        children: [
          // 白色导航栏：返回 + 居中标题（与设置页一致）
          Container(
            padding: EdgeInsets.only(top: topPadding),
            color: Colors.white,
            child: SizedBox(
              height: 44 * s,
              child: Stack(
                children: [
                  Positioned(
                    left: 12 * s,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: () => Navigator.pop(context),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          const Icon(Icons.arrow_back_ios_new,
                              size: 20, color: Colors.black),
                          SizedBox(width: 8 * s - 3),
                          Text('返回',
                              style: TextStyle(
                                  color: Colors.black, fontSize: 14 * s)),
                        ],
                      ),
                    ),
                  ),
                  Center(
                    child: Text(
                      '手环',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 17.5 * s,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: 17 * s),
                  _sectionHeader('状态', s),
                  SizedBox(height: 10 * s),
                  _card(
                    s: s,
                    child: Column(
                      children: [
                        _statusRow('连接状态', _stateText, s,
                            valueColor: _stateColor),
                        _divider(s),
                        _statusRow('手环 SDK', _band.sdkReady ? '已就绪' : '未就绪', s,
                            valueColor: _band.sdkReady
                                ? const Color(0xFF2F84FE)
                                : const Color(0xFF838383)),
                        _divider(s),
                        _statusRow('手环端快应用', _wearAppText, s),
                        _divider(s),
                        _statusRow(
                          '已启用手环控制',
                          _band.enabled ? '是' : '否',
                          s,
                        ),
                      ],
                    ),
                  ),
                  if (!_band.sdkReady) ...[
                    SizedBox(height: 10 * s),
                    _hintCard(
                      s: s,
                      text: '检测到本机未加载小米手环官方 SDK（xms-wearable-lib）。'
                          '这不会影响 App 其它功能；按下方指引放置 AAR 后重新构建即可启用真机通信。'
                          '当前显示为「不可用 / 未知」属正常现象。',
                    ),
                  ],
                  // 连接失败定位：直接展示原生适配器诊断（无需连电脑看 logcat）
                  if (_band.sdkReady) ...[
                    SizedBox(height: 10 * s),
                    _sectionHeader('诊断', s),
                    SizedBox(height: 10 * s),
                    _card(
                      s: s,
                      child: Column(
                        children: [
                          _statusRow('适配器', '${_diag?['adapter'] ?? '—'}', s),
                          _divider(s),
                          _statusRow('节点', '${_diag?['nodeId'] ?? '未发现'}', s),
                          _divider(s),
                          _statusRow(
                            '设备管理权限',
                            (_diag?['permissionGranted'] == true) ? '已授予' : '未授予',
                            s,
                            valueColor: (_diag?['permissionGranted'] == true)
                                ? const Color(0xFF2F84FE)
                                : const Color(0xFFFF9800),
                          ),
                          _divider(s),
                          _statusRow('最近错误', '${_diag?['lastError'] ?? '无'}', s),
                        ],
                      ),
                    ),
                  ],
                  SizedBox(height: 10 * s),
                  _sectionHeader('控制', s),
                  SizedBox(height: 10 * s),
                  _tappableCard(
                    s: s,
                    onTap: _busy ? null : () => _toggleEnabled(!_band.enabled),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('启用手环控制',
                                  style: TextStyle(
                                      color: Colors.black, fontSize: 16 * s)),
                              SizedBox(height: 2 * s),
                              Text('允许手环控制播放 / 暂停 / 切歌 / 进度',
                                  style: TextStyle(
                                      color: const Color(0xFF838383),
                                      fontSize: 11 * s)),
                            ],
                          ),
                        ),
                        _switch(s, _band.enabled,
                            _busy ? null : () => _toggleEnabled(!_band.enabled)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _tappableCard(
                    s: s,
                    onTap: _busy ? null : _refresh,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('刷新连接状态',
                              style: TextStyle(
                                  color: Colors.black, fontSize: 16 * s)),
                        ),
                        if (_busy)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        else
                          const Icon(Icons.refresh,
                              size: 20, color: Color(0xFF2F84FE)),
                      ],
                    ),
                  ),
                  SizedBox(height: 10 * s),
                  _sectionHeader('绑定指引', s),
                  SizedBox(height: 10 * s),
                  _card(s: s, child: _guide(s)),
                  SizedBox(height: 10 * s),
                  _sectionHeader('隐私', s),
                  SizedBox(height: 10 * s),
                  _hintCard(
                    s: s,
                    text: '手环与手机仅通过系统提供的本机配对链路（蓝牙 / 系统互联通道）通信；'
                        '播放控制命令与播放状态仅在该本机链路内传输，不经过任何服务器、不上传。'
                        '手环端不保存账号凭证、歌词全文与歌单。',
                  ),
                  SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 构建件 ────────────────────────────────────────────────
/// 可复制的一行（label + 值 + 可选尾部件 + 复制按钮）。
  // ignore: unused_element
  Widget _copyRow({
    required double s,
    required String label,
    required String value,
    required Color valueColor,
    VoidCallback? onCopy,
    Widget? trailing,
  }) {
    return SizedBox(
      height: 48 * s,
      child: Row(
        children: [
          Text(label, style: TextStyle(color: Colors.black, fontSize: 15 * s)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 13.5 * s,
                  fontWeight: FontWeight.w500),
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: 8 * s),
            trailing,
          ],
          if (onCopy != null)
            GestureDetector(
              onTap: onCopy,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: EdgeInsets.only(left: 8 * s),
                child: const Icon(Icons.copy, size: 17, color: Color(0xFF2F84FE)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, double s) => SizedBox(
        height: 20 * s,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(title,
              style: TextStyle(
                  color: const Color(0xFF838383), fontSize: 15.5 * s)),
        ),
      );

  Widget _card({required double s, required Widget child}) => Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 12 * s, vertical: 4 * s),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10 * s),
        ),
        child: child,
      );

  Widget _tappableCard({
    required double s,
    required Widget child,
    VoidCallback? onTap,
  }) =>
      GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: double.infinity,
          height: 52,
          padding: EdgeInsets.symmetric(horizontal: 9 * s),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10 * s),
          ),
          alignment: Alignment.centerLeft,
          child: child,
        ),
      );

  Widget _hintCard({required double s, required String text}) => Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(12 * s, 10 * s, 12 * s, 10 * s),
        decoration: BoxDecoration(
          color: const Color(0xFFEAF2FF),
          borderRadius: BorderRadius.circular(10 * s),
        ),
        child: Text(text,
            style: TextStyle(
                color: const Color(0xFF4A5568), fontSize: 11.5 * s, height: 1.6)),
      );

  Widget _statusRow(String label, String value, double s,
      {Color valueColor = const Color(0xFF333333)}) {
    return SizedBox(
      height: 44 * s,
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(color: Colors.black, fontSize: 15 * s)),
          ),
          Text(value,
              style: TextStyle(
                  color: valueColor,
                  fontSize: 14 * s,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _divider(double s) =>
      Container(height: 1, color: const Color(0xFFEEEEEE));

  Widget _guide(double s) {
    const steps = <String>[
      '在手机「设置 → 手环」开启「启用手环控制」。',
      '将小米手环与手机在「小米运动健康」中完成蓝牙配对，并保持连接。',
      '安装手环端快应用 SuchMusic（与手机 App 同包名、同签名）。',
      '保持本 App 在前台或后台运行，然后打开手环端 SuchMusic，'
          '两端会自动建立互联（无需在运动健康中做任何授权）。',
      '首次连接如弹出系统授权提示，请允许；'
          '手环端显示「手机未装App」时，请确认本 App 已安装并处于运行状态。',
      '手机播放一首歌，手环首页即可看到歌名与进度。',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 6 * s),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 18 * s,
                  height: 18 * s,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: Color(0xFF2F84FE),
                    shape: BoxShape.circle,
                  ),
                  child: Text('${i + 1}',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11 * s,
                          fontWeight: FontWeight.w600)),
                ),
                SizedBox(width: 8 * s),
                Expanded(
                  child: Text(steps[i],
                      style: TextStyle(
                          color: const Color(0xFF333333),
                          fontSize: 12.5 * s,
                          height: 1.55)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _switch(double s, bool value, VoidCallback? onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: 53 * s + 6,
        height: 25 * s + 6,
        padding: EdgeInsets.all(4 * s),
        decoration: BoxDecoration(
          color: value ? const Color(0xFF2F84FE) : const Color(0xFFC4C4C4),
          borderRadius: BorderRadius.circular(84),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 23 * s,
            height: 23 * s,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/kugou_platform.dart';
import '../models/song_model.dart';
import '../services/kugou_credential_service.dart';
import '../services/music_api_service.dart';
import '../services/sources/source_manager.dart';
import '../theme/app_theme.dart';
import 'design_dialog.dart';

/// 两个胶囊的定位 key（测试与外部对齐用，避免依赖私有组件类型）。
const Key sourceSwitcherNeteasePillKey = Key('source-switcher-pill-netease');
const Key sourceSwitcherKugouPillKey = Key('source-switcher-pill-kugou');
const Key sourceSwitcherNeteaseDotKey = Key('source-switcher-dot-netease');
const Key sourceSwitcherKugouDotKey = Key('source-switcher-dot-kugou');

/// 「我的」页双音源登录态行的定位 key（行 / 单个音源 / 圆点三层各一份）。
const Key sourceStatusRowKey = Key('source-status-row');
const Key sourceStatusRowNeteaseKey = Key('source-status-row-netease');
const Key sourceStatusRowKugouKey = Key('source-status-row-kugou');
const Key sourceStatusRowNeteaseDotKey = Key('source-status-dot-netease');
const Key sourceStatusRowKugouDotKey = Key('source-status-dot-kugou');

/// 未登录时点击音源胶囊的引导文案。
///
/// 音源胶囊是「切换」入口，不是「登录」入口：未登录硬切过去只会让列表变空，
/// 用户会以为 App 坏了。所以这里只提示去登录，不切换。
String sourceLoginHintFor(SongSource kind) =>
    '请先在「我的」页登录${kind.isKugou ? '酷狗' : '网易云'}账号';

/// 两个音源的登录态快照。
///
/// 只是一次读取的结果（不可变值对象），不承担任何状态管理职责；
/// 唯一真源仍然是 [MusicApiService] 与 [KugouCredentialService]。
@immutable
class SourceLoginState {
  const SourceLoginState({this.netease = false, this.kugou = false});

  /// 全部未登录（初始值 / 读取失败时的降级值）
  static const SourceLoginState none = SourceLoginState();

  /// 网易云是否已登录
  final bool netease;

  /// 酷狗（概念版或原版）是否已登录
  final bool kugou;

  /// 指定音源是否已登录（本地音乐不参与，按未登录处理）
  bool isLoggedIn(SongSource kind) => kind.isKugou ? kugou : netease;

  SourceLoginState copyWith({bool? netease, bool? kugou}) => SourceLoginState(
    netease: netease ?? this.netease,
    kugou: kugou ?? this.kugou,
  );

  @override
  bool operator ==(Object other) =>
      other is SourceLoginState &&
      other.netease == netease &&
      other.kugou == kugou;

  @override
  int get hashCode => Object.hash(netease, kugou);

  @override
  String toString() => 'SourceLoginState(netease: $netease, kugou: $kugou)';
}

/// 同步读取两个音源的登录态快照（不触发任何 IO 与 init）。
///
/// 供「点击判定」使用：点一下胶囊必须立刻有反馈，不能等一次磁盘读；
/// 这两个服务在读取过一次之后，值就是内存里的真值。
SourceLoginState readSourceLoginStateSync() => SourceLoginState(
  netease: MusicApiService().hasCachedUser,
  kugou: KugouPlatform.values.any(
    KugouCredentialService.instance.hasCredentialsFor,
  ),
);

/// 读取两个音源的登录态（只读，不改任何凭证）。
///
/// [fallback] 用于读取失败时保留上一次的结果——圆点只是辅助信息，
/// 不能因为一次 IO 抖动就把「已登录」闪成「未登录」。
Future<SourceLoginState> readSourceLoginState({
  SourceLoginState fallback = SourceLoginState.none,
}) async {
  var state = fallback;
  try {
    final api = MusicApiService();
    await api.init();
    state = state.copyWith(netease: api.hasCachedUser);
  } catch (e) {
    debugPrint('⚠️ 读取网易云登录态失败: $e');
  }
  try {
    final credential = KugouCredentialService.instance;
    await credential.init();
    state = state.copyWith(
      kugou: KugouPlatform.values.any(credential.hasCredentialsFor),
    );
  } catch (e) {
    debugPrint('⚠️ 读取酷狗登录态失败: $e');
  }
  return state;
}

/// 音源登录态圆点：已登录品牌蓝，未登录置灰。
///
/// 6px 纯装饰元素，语义由旁边的名称文字承担（不靠颜色单独表意）。
class SourceStatusDot extends StatelessWidget {
  const SourceStatusDot({super.key, required this.loggedIn});

  final bool loggedIn;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: loggedIn ? AppColors.brand : AppColors.inkDisabled,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 双音源登录态行：「圆点 + 名称」× 2，12px。
///
/// 「我的」页身份卡下方的一行，回答「我现在到底登录了哪个音源」。
/// 与 [SourceSwitcher] 共用 [readSourceLoginState]，不另造一套判断。
/// 登录态变化后由宿主通过 [reloadToken] 触发重读（例如扫码登录返回后）。
class SourceStatusRow extends StatefulWidget {
  const SourceStatusRow({super.key, this.reloadToken = 0});

  /// 宿主每次拿到新的登录结果就自增这个值，行内据此重读一次登录态。
  final int reloadToken;

  @override
  State<SourceStatusRow> createState() => _SourceStatusRowState();
}

class _SourceStatusRowState extends State<SourceStatusRow> {
  SourceLoginState _state = SourceLoginState.none;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SourceStatusRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reloadToken != widget.reloadToken) _load();
  }

  Future<void> _load() async {
    final next = await readSourceLoginState(fallback: _state);
    if (!mounted) return;
    if (next == _state) return;
    setState(() => _state = next);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      key: sourceStatusRowKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildItem(
          rowKey: sourceStatusRowNeteaseKey,
          dotKey: sourceStatusRowNeteaseDotKey,
          label: '网易云',
          loggedIn: _state.netease,
        ),
        const SizedBox(width: AppSpace.md),
        _buildItem(
          rowKey: sourceStatusRowKugouKey,
          dotKey: sourceStatusRowKugouDotKey,
          label: '酷狗',
          loggedIn: _state.kugou,
        ),
      ],
    );
  }

  Widget _buildItem({
    required Key rowKey,
    required Key dotKey,
    required String label,
    required bool loggedIn,
  }) {
    return Row(
      key: rowKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        SourceStatusDot(key: dotKey, loggedIn: loggedIn),
        const SizedBox(width: 6),
        Text(
          label,
          maxLines: 1,
          style: AppType.caption.copyWith(
            fontSize: 12,
            height: 1.1,
            color: loggedIn ? AppColors.ink : AppColors.inkTertiary,
          ),
        ),
      ],
    );
  }
}

/// 双音源切换器：两个胶囊并排。
///
/// 「支持两个音源」是本产品的核心差异点，但过去只用首页日期旁一个 6px 圆点暗示，
/// 用户完全看不出这是什么能力。这里把它提成可读、可点的显式控件：
/// 选中态墨色实心，未选中浅灰底，胶囊前的圆点额外表达该音源的登录态。
///
/// 状态全部来自既有 [SourceManager]，不新建任何状态管理：
/// [SourceManager.currentSource] 读当前音源，[SourceManager.switchTo] 执行切换，
/// [SourceManager.onSourceChanged] 保证外部的切换（如设置页）也能同步到这里。
///
/// 未登录的音源**不切换**，只提示去「我的」页登录：胶囊是「切换」入口，
/// 硬切到没有凭证的音源只会得到一片空白。
class SourceSwitcher extends StatefulWidget {
  const SourceSwitcher({super.key});

  @override
  State<SourceSwitcher> createState() => _SourceSwitcherState();
}

class _SourceSwitcherState extends State<SourceSwitcher> {
  StreamSubscription<SongSource>? _sourceSub;

  /// 当前音源：以 [SourceManager] 为唯一真源，本地字段只做构建期的快照。
  SongSource _current = SongSource.netease;

  /// 登录态：同样只是快照，真源在 [readSourceLoginState] 背后。
  SourceLoginState _login = SourceLoginState.none;

  /// 登录态是否至少成功读过一次（首次读取完成前点击要先补读，避免误判未登录）。
  bool _loginLoaded = false;

  @override
  void initState() {
    super.initState();
    _current = SourceManager().currentSource;
    _sourceSub = SourceManager().onSourceChanged.listen((kind) {
      if (!mounted) return;
      setState(() => _current = kind);
      // 登录态可能与音源切换同时变化（例如刚扫码回来），顺手刷新一次
      _refreshLoginState();
    });
    _refreshLoginState();
  }

  @override
  void dispose() {
    _sourceSub?.cancel();
    super.dispose();
  }

  /// 读取两个音源的登录态（只读，不改任何凭证）。
  ///
  /// 失败一律静默降级为上一次的值（首次为「未登录」）：圆点只是辅助信息，
  /// 不能成为异常源。
  Future<void> _refreshLoginState() async {
    final next = await readSourceLoginState(fallback: _login);
    if (!mounted) return;
    final changed = next != _login || !_loginLoaded;
    if (!changed) return;
    setState(() {
      _login = next;
      _loginLoaded = true;
    });
  }

  /// 点击胶囊：已登录才切换，未登录只给一次去登录的引导。
  ///
  /// 判定用同步快照（[readSourceLoginStateSync]）：点击不能挂在一次 IO 上。
  /// 首帧后台读取还没回来时（[_loginLoaded] 为 false）用同步值兜底并顺手补读，
  /// 读完之后的判定就都走 [_login] 这个权威快照。
  void _onPillTap(SongSource kind) {
    if (SourceManager().currentSource == kind) return;
    final login = _loginLoaded ? _login : readSourceLoginStateSync();
    if (login != _login) setState(() => _login = login);
    if (!_loginLoaded) unawaited(_refreshLoginState());
    if (!login.isLoggedIn(kind)) {
      DesignToast.show(context, sourceLoginHintFor(kind));
      return;
    }
    unawaited(_switchTo(kind));
  }

  /// 切换音源：沿用 [SourceManager.switchTo]（会持久化并广播），不清空播放队列。
  Future<void> _switchTo(SongSource kind) async {
    if (SourceManager().currentSource == kind) return;
    await SourceManager().switchTo(kind);
    if (!mounted) return;
    setState(() => _current = SourceManager().currentSource);
    DesignToast.show(context, '已切换音源：${kind.label}');
  }

  /// 酷狗家族（概念版 / 原版）都归到同一个「酷狗」胶囊下。
  bool get _kugouSelected => _current.isKugou;

  bool get _neteaseSelected => !_kugouSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildPill(
          key: sourceSwitcherNeteasePillKey,
          dotKey: sourceSwitcherNeteaseDotKey,
          label: '网易云',
          selected: _neteaseSelected,
          loggedIn: _login.netease,
          onTap: () => _onPillTap(SongSource.netease),
        ),
        const SizedBox(width: AppSpace.sm),
        _buildPill(
          key: sourceSwitcherKugouPillKey,
          dotKey: sourceSwitcherKugouDotKey,
          label: '酷狗',
          selected: _kugouSelected,
          loggedIn: _login.kugou,
          onTap: () => _onPillTap(SongSource.kugou),
        ),
      ],
    );
  }

  /// 单个胶囊：视觉高 32，热区高 44（满足 ≥44 的触控要求）。
  Widget _buildPill({
    required Key key,
    required Key dotKey,
    required String label,
    required bool selected,
    required bool loggedIn,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 44,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Center(
            child: Container(
              key: key,
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected ? AppColors.ink : AppColors.surfaceMuted,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SourceStatusDot(key: dotKey, loggedIn: loggedIn),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    maxLines: 1,
                    style: AppType.caption.copyWith(
                      fontSize: 12,
                      height: 1.1,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? Colors.white : AppColors.inkSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

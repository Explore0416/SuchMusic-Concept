// 1.4.1 横屏播放页动作入口回归测试。
//
// 背景：分栏（横屏）左栏此前只拼了封面 / 歌名 / 进度 / 控制，把
// 下载 / 分享 / 定时关闭 / 更多 四个入口整个漏掉了。本文件锁定：
//  1. 720×480 横屏四个入口同时可见；
//  2. 点「更多」能弹出「歌曲信息」面板；
//  3. 640×360 小屏横屏四个入口仍在，且无 overflow 异常；
//  4. 390×844 竖屏四个入口仍在（防止把竖屏改坏）；
//  5. 紧凑形态下动作按钮点击热区高度 ≥ 44。
//
// PlayerPage 会触发 AudioPlayerService 单例（just_audio 平台通道在纯 Dart
// 测试里会抛 MissingPluginException，但服务内部已 try/catch，不会冒泡到
// 测试框架）；「更多」需要一首当前歌曲才有回调，这里用一首**本地伪曲目**
// 走 play()，它只把 currentSong 同步赋值，不产生真实网络请求。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/screens/player_page.dart';
import 'package:such_music/services/audio_player_service.dart';

/// 测试用路径提供者：把网易云 SDK 的 cookie / 数据目录指到临时目录，
/// 避开 path_provider 插件（widget test 里没有平台实现）。
///
/// 「更多」用例需要一首当前歌曲，`play()` 内部会 fire-and-forget 拉歌词，
/// SDK 构造时若没设 pathProvider 会抛 LateError（未捕获 → 用例失败）。
class _TempPathProvider extends PathProvider {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<void> init() async {}

  @override
  String getCookieSavedPath() => '$root/.cookies/';

  @override
  String getDataSavedPath() => '$root/.data/';
}

/// 四个动作入口的文案（与 `_buildActionRow` 保持一致）
const List<String> _actionLabels = ['下载', '分享', '定时', '更多'];

/// 本地伪曲目：路径不存在，play() 会把 currentSong 同步置上后静默失败，
/// 不会像在线曲目那样去打网络接口。
const SongModel _probeSong = SongModel(
  id: 'landscape-probe-1',
  name: '东风破',
  artist: '周杰伦',
  album: '叶惠美',
  duration: 300000,
  source: SongSource.local,
  localUri: 'file:///tmp/suchmusic-test-nonexistent.mp3',
);

void _useSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 直接 pump 真实 [PlayerPage]（竖屏走 `_buildColumnBody`，横屏走 `_buildSplitBody`）
Future<void> _pumpPlayer(WidgetTester tester, Size size) async {
  _useSize(tester, size);
  await tester.pumpWidget(const MaterialApp(home: PlayerPage()));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 动作按钮的点击热区（最近的 GestureDetector 祖先）
Finder _actionHitArea(String label) => find
    .ancestor(of: find.text(label), matching: find.byType(GestureDetector))
    .first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp('suchmusic_landscape_test');
    await NeteaseMusicApi.init(provider: _TempPathProvider(dir.path));
  });

  testWidgets('720×480 横屏：下载 / 分享 / 定时 / 更多 四个入口同时存在', (tester) async {
    await _pumpPlayer(tester, const Size(720, 480));

    for (final label in _actionLabels) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: '横屏播放页缺少「$label」入口',
      );
    }
    expect(tester.takeException(), isNull);

    // 动作行必须落在左栏（分栏左侧），而不是溢出到右栏或屏幕外
    final downloadCenter = tester.getCenter(find.text('下载'));
    expect(downloadCenter.dx, lessThan(720 / 2));
  });

  testWidgets('横屏：点击「更多」弹出「歌曲信息」面板', (tester) async {
    // play() 是异步方法，但在首个 await 之前就同步写好了 currentSong，
    // 因此这里不 await 也能让 PlayerPage 首次 build 拿到歌曲。
    // ignore: discarded_futures
    AudioPlayerService().play(_probeSong);

    await _pumpPlayer(tester, const Size(720, 480));
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('歌曲信息'), findsNothing);

    await tester.tap(find.text('更多'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('歌曲信息'), findsOneWidget, reason: '「更多」应弹出歌曲信息面板');
    expect(find.text('歌名'), findsOneWidget);
    expect(find.text('东风破'), findsWidgets);

    // play() 给本地源装了 10 秒超时定时器；用假时钟把它走完并卸载播放页，
    // 否则测试收尾会因「A Timer is still pending」误报失败（不是业务问题）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('640×360 小屏横屏：四个入口仍在，且无 overflow', (tester) async {
    await _pumpPlayer(tester, const Size(640, 360));

    for (final label in _actionLabels) {
      expect(find.text(label), findsOneWidget, reason: '小屏横屏缺少「$label」入口');
    }
    expect(tester.takeException(), isNull, reason: '小屏横屏不应出现 overflow');

    // 四个入口都必须真正落在屏幕内、且可点击
    for (final label in _actionLabels) {
      final rect = tester.getRect(_actionHitArea(label));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(360));
      expect(rect.height, greaterThanOrEqualTo(44));
    }
  });

  testWidgets('390×844 竖屏：四个入口仍在（竖屏回归）', (tester) async {
    await _pumpPlayer(tester, const Size(390, 844));

    for (final label in _actionLabels) {
      expect(find.text(label), findsOneWidget, reason: '竖屏播放页缺少「$label」入口');
    }
    expect(tester.takeException(), isNull);

    // 竖屏仍是常规尺寸（64×56），紧凑形态不得泄漏到竖屏
    expect(tester.getSize(_actionHitArea('下载')).height, 56);
  });

  testWidgets('紧凑形态动作按钮点击热区高度 ≥ 44', (tester) async {
    await _pumpPlayer(tester, const Size(720, 480));

    for (final label in _actionLabels) {
      final size = tester.getSize(_actionHitArea(label));
      expect(
        size.height,
        greaterThanOrEqualTo(44),
        reason: '「$label」紧凑按钮热区只有 ${size.height}，低于 44 会点不中',
      );
      expect(size.width, 52, reason: '紧凑形态视觉宽 52（热区随宽）');
    }

    // 竖屏对照：热区按常规尺寸 56 高
    await _pumpPlayer(tester, const Size(390, 844));
    expect(tester.getSize(_actionHitArea('下载')).height, 56);
  });
}

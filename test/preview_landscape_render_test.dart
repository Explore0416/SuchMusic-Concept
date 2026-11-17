// 横屏播放页预览图，供人工目检：
//   568×320（tiny，无封面）/ 640×360 / 720×480（compact）/
//   800×600（full）。
//
// 横屏形态（2026-11 定稿）：左封面+歌名+进度+控制，右半屏常驻多行歌词，
// 底部 4 个功能入口**只占左栏、左对齐、纯图标不带文字**；封面不可点，
// 因此**没有**「收起态」截图。
//
// 为什么单独一个文件：`preview_render_test.dart` 是 1.4.0 那批整包截图，
// 批量 `--update-goldens` 会连带重写一批与本轮无关的旧图；这里只负责横屏这批，
// 互不影响。
//
// 生成：
//   flutter test test/preview_landscape_render_test.dart --update-goldens --no-version-check
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netease_music_api/netease_music_api.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/screens/player_page.dart';
import 'package:such_music/services/audio_player_service.dart';
import 'package:such_music/services/local_lyric_service.dart';
import 'package:such_music/theme/app_theme.dart';

/// 测试用路径提供者：网易云 SDK 的 cookie 目录指到临时目录，
/// 避开 path_provider 插件（widget test 里没有平台实现）。
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

/// 中文字体：**每个用例内部**、经 `runAsync` 调用（见 [shoot] 里的说明）。
///
/// 走 `File.readAsBytes`（与 `preview_render_test.dart` 一致）：`File` IO 在
/// fake async 里会挂起，所以调用点必须包在 `tester.runAsync` 里。
Future<void> _loadTextFont() async {
  final loader = FontLoader('MiSans');
  for (final f in const [
    'assets/fonts/MiSans-Regular.ttf',
    'assets/fonts/MiSans-Medium.ttf',
    'assets/fonts/MiSans-Bold.ttf',
  ]) {
    // 必须用 `File` 读原始字节：`rootBundle.load()` 返回的 ByteData 是 asset
    // bundle 大 buffer 上的切片，直接交给 FontLoader 会解析失败（整个 family
    // 静默失效 → 中文全变豆腐块）。
    loader.addFont(File(f).readAsBytes().then((b) => b.buffer.asByteData()));
  }
  await loader.load();
}

/// 图标字体：走 `File` 读 Flutter SDK 缓存里的 MaterialIcons。
///
/// 只在 [shoot] 的 `runAsync`（真实 Zone）里调用 —— `File` IO 在 fake async
/// 里会挂起，`FontLoader.load()` 不 await 又会让图标退化成方块。
Future<void> _loadIconFont() async {
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!icons.existsSync()) return;
  final il = FontLoader('MaterialIcons');
  il.addFont(icons.readAsBytes().then((b) => b.buffer.asByteData()));
  await il.load();
}

/// 给 just_audio / audio_session 打最小桩（同 preview_render_test.dart）：
/// 出预览图走 `runAsync`（真实 Zone），迟到的 MissingPluginException 会被
/// 算到用例头上导致截图失败。
void _stubAudioPlugins() {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const mainChannel = MethodChannel('com.ryanheise.just_audio.methods');

  void handlerFor(String id) {
    messenger.setMockMethodCallHandler(
      MethodChannel('com.ryanheise.just_audio.methods.$id'),
      (call) async => <dynamic, dynamic>{},
    );
    for (final prefix in const [
      'com.ryanheise.just_audio.events',
      'com.ryanheise.just_audio.data',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel('$prefix.$id'),
        (call) async => null,
      );
    }
  }

  messenger.setMockMethodCallHandler(mainChannel, (call) async {
    if (call.method == 'init') {
      final args = call.arguments;
      final id = args is Map ? args['id'] as String? : null;
      if (id != null) handlerFor(id);
      return null;
    }
    return <dynamic, dynamic>{};
  });
  messenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => <dynamic, dynamic>{},
  );
}

/// 本地伪曲目：play() 只把 currentSong 同步置上后静默失败，不触网。
const SongModel _probeLocalSong = SongModel(
  id: 'preview-landscape-parity-1',
  name: '东风破',
  artist: '周杰伦',
  album: '叶惠美',
  duration: 300000,
  source: SongSource.local,
  localUri: 'file:///tmp/suchmusic-preview-parity-nonexistent.mp3',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final dir = await Directory.systemTemp.createTemp(
      'suchmusic_landscape_preview',
    );
    await NeteaseMusicApi.init(provider: _TempPathProvider(dir.path));
    _stubAudioPlugins();
    // 在 **fake async 之外**创建播放器单例并置上当前歌曲：
    // just_audio 的位置轮询是个永不结束的 16ms 周期定时器，在用例体内创建
    // 会被判成「Pending timers」；放在 setUpAll 里就挂在真实时钟上，无害。
    // ignore: discarded_futures
    AudioPlayerService().play(_probeLocalSong);

    // 伪曲目是个不存在的本地文件，本身取不到歌词。但右栏歌词面板要能**肉眼**
    // 看出多行滚动效果（空歌词面板与有内容的面板，截图差别很大），所以先给它
    // 塞几行手动歌词再让播放器重新取一次。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalLyricService().init();
    await LocalLyricService().set(
      _probeLocalSong.id,
      '[00:00.000]雨纷纷 旧故里草木深\n'
          '[00:08.000]我听闻 你始终一个人\n'
          '[00:16.000]斑驳的城门 盘踞着老树根\n'
          '[00:24.000]石板上回荡的是 再等\n'
          '[00:32.000]雨纷纷 旧故里草木深\n'
          '[00:40.000]我听闻 你仍守着孤城\n'
          '[00:48.000]城郊牧笛声 落在那座野村\n'
          '[00:56.000]缘份落地生根是 我们',
    );
    // 逐字对齐要下载 / 解码音频，纯 widget 测试里跑不通（会抛 path_provider
    // 的 MissingPluginException），这里先关掉；关掉后 reloadLyrics 只做
    // 「取歌词文本 → 更新 currentLyric」这一步，正好是我们需要的。
    await AudioPlayerService().setKaraokeEnabled(false);
    await AudioPlayerService().reloadLyrics();
  });

  Future<void> shoot(WidgetTester tester, String name, Size size) async {
    // 字体必须在每个用例内部、且用 `runAsync`（真实 Zone）注册：
    // 放 setUpAll 里时字形不参与解析，金图的中文全变豆腐块 —— 而且不会报错，
    // 只能靠肉眼发现。加载必须 await 到 `FontLoader.load()` 完成。
    await tester.runAsync(() async {
      await _loadTextFont();
      await _loadIconFont();
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 必须带真实主题：歌名 / 歌词的 TextStyle 没显式写 fontFamily，靠
    // ThemeData.fontFamily 落到 MiSans；裸 MaterialApp 会落到 Roboto，
    // 中文直接渲染成豆腐块。
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        debugShowCheckedModeBanner: false,
        home: const PlayerPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/$name.png'),
    );

    // 收尾：卸载播放页（顺带取消它每秒刷新的定时器），避免 pending timer
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('player-landscape-568x320', (tester) async {
    await shoot(tester, 'player-landscape-568x320', const Size(568, 320));
  });

  testWidgets('player-landscape-640x360', (tester) async {
    await shoot(tester, 'player-landscape-640x360', const Size(640, 360));
  });

  testWidgets('player-landscape-720x480', (tester) async {
    await shoot(tester, 'player-landscape-720x480', const Size(720, 480));
  });

  testWidgets('player-landscape-800x600', (tester) async {
    await shoot(tester, 'player-landscape-800x600', const Size(800, 600));
  });

  testWidgets('player-landscape-1280x720', (tester) async {
    await shoot(tester, 'player-landscape-1280x720', const Size(1280, 720));
  });
}

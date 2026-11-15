// 1.5.2 横屏播放页预览图，供人工目检：
//   568×320（tiny，无封面）/ 640×360（compact，无歌词行）/
//   720×480（compact，有歌词行）/ 720×480 收起态 / 800×600（full）。
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

Future<void> _loadFonts() async {
  final loader = FontLoader('MiSans');
  for (final f in const [
    'assets/fonts/MiSans-Regular.ttf',
    'assets/fonts/MiSans-Medium.ttf',
    'assets/fonts/MiSans-Bold.ttf',
  ]) {
    loader.addFont(File(f).readAsBytes().then((b) => b.buffer.asByteData()));
  }
  await loader.load();

  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? '/opt/flutter'}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final il = FontLoader('MaterialIcons');
    il.addFont(icons.readAsBytes().then((b) => b.buffer.asByteData()));
    await il.load();
  }
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
    await _loadFonts();
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

    // 伪曲目是个不存在的本地文件，本身取不到歌词。但金图要能**肉眼**看出
    // 「歌名下面那一行歌词」是否存在（LyricDisplay 空文本只占 20px 空白，
    // 截图里看不出区别），所以先给它塞一条手动歌词再让播放器重新取一次。
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LocalLyricService().init();
    await LocalLyricService().set(_probeLocalSong.id, '[00:00.000]雨纷纷 旧故里草木深');
    // 逐字对齐要下载 / 解码音频，纯 widget 测试里跑不通（会抛 path_provider
    // 的 MissingPluginException），这里先关掉；关掉后 reloadLyrics 只做
    // 「取歌词文本 → 更新 currentLyric」这一步，正好是我们需要的。
    await AudioPlayerService().setKaraokeEnabled(false);
    await AudioPlayerService().reloadLyrics();
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Size size, {
    bool tapCover = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(debugShowCheckedModeBanner: false, home: PlayerPage()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    if (tapCover) {
      // 收起态：点封面（compact / full 两档都必须有反应），等动画走完再截
      await tester.tap(find.byType(AspectRatio).first);
      await tester.pump(const Duration(milliseconds: 300));
    }

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

  testWidgets('player-landscape-720x480-collapsed', (tester) async {
    await shoot(
      tester,
      'player-landscape-720x480-collapsed',
      const Size(720, 480),
      tapCover: true,
    );
  });

  testWidgets('player-landscape-800x600', (tester) async {
    await shoot(tester, 'player-landscape-800x600', const Size(800, 600));
  });
}

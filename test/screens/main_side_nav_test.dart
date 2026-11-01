// 宽屏左侧导航（MainSideNav）布局与交互测试 + golden 截图。
//
// 一级入口与窄屏底部导航坞一致：首页 / 本地 / 歌单 / 我的；
// 底部是当前播放卡（宽屏没有底部导航坞，这里是回到播放页的入口）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/theme/app_theme.dart';
import 'package:such_music/widgets/main_side_nav.dart';

const _song = SongModel(
  id: '1',
  name: '东风破',
  artist: '周杰伦',
  album: '叶惠美',
  source: SongSource.kugou,
);

/// 用真实字体渲染，golden 里才能看清中文排版与图标（测试默认字体是方块占位）
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

  // Material Icons 取自 Flutter SDK 缓存，缺失时（非本地环境）跳过
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

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(backgroundColor: AppColors.canvas, body: child),
    );

MainSideNav _nav({
  int index = 0,
  SongModel? song = _song,
  bool isPlaying = true,
  ValueChanged<int>? onSelect,
  VoidCallback? onTogglePlay,
  VoidCallback? onOpenPlayer,
}) =>
    MainSideNav(
      index: index,
      song: song,
      isPlaying: isPlaying,
      onSelect: onSelect ?? (_) {},
      onTogglePlay: onTogglePlay ?? () {},
      onOpenPlayer: onOpenPlayer ?? () {},
      cover: song == null
          ? null
          : Container(
              color: const Color(0xFFCAD9F2),
              child: const Icon(Icons.music_note, size: 18),
            ),
    );

void main() {
  setUpAll(_loadFonts);

  testWidgets('侧栏含四个入口 + 底部当前播放卡，点击回调带正确下标', (tester) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <int>[];
    var toggled = 0;
    var opened = 0;

    await tester.pumpWidget(
      _host(
        _nav(
          onSelect: picked.add,
          onTogglePlay: () => toggled++,
          onOpenPlayer: () => opened++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final label in ['首页', '本地', '歌单', '我的']) {
      expect(find.text(label), findsOneWidget, reason: '侧栏应有「$label」入口');
    }
    // 当前播放卡（横屏没有底部导航坞，播放入口在这里）
    expect(find.text('东风破'), findsOneWidget);
    expect(find.text('周杰伦'), findsOneWidget);

    await tester.tap(find.text('本地'));
    await tester.tap(find.text('歌单'));
    await tester.tap(find.text('我的'));
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.tap(find.text('东风破'));

    expect(picked, [1, 2, 3]);
    expect(toggled, 1);
    expect(opened, 1);
  });

  testWidgets('无歌曲时不渲染空的播放卡', (tester) async {
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var opened = 0;
    await tester.pumpWidget(
      _host(_nav(song: null, onOpenPlayer: () => opened++)),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无播放'), findsNothing);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    expect(opened, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('极矮横屏（640x360）不溢出', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_nav()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // golden：900x540 横屏侧栏观感留档（--update-goldens 生成）
  testWidgets('golden: 侧栏 @900x540', (tester) async {
    tester.view.physicalSize = const Size(900, 540);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(_nav(index: 2)));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MainSideNav),
      matchesGoldenFile('goldens/main_side_nav_900x540.png'),
    );
  });
}

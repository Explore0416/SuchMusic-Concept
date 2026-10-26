// 「歌单」入口接入 + 导航归属的回归测试。
//
// 背景：首页顶部的「歌单」标签原来只弹「敬请期待」，现在直接打开做好的
// 歌单页（我喜欢的音乐 / 我的歌单 / 酷狗歌单）；宽屏（横屏 / 平板）时
// 首页 / 本地 / 歌单 这三项从顶部挪到左侧导航，两处共用 [HomeTab] 状态。
//
// 这里覆盖状态单一真源与两个渲染形态（内嵌 / 独立页），UI 级横屏截图
// 依赖真机，不在纯 Dart 测试范围内。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/screens/library_page.dart';
import 'package:such_music/services/user_library_service.dart';
import 'package:such_music/utils/home_tab.dart';

/// golden 用真实字体，避免中文变成方块占位
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await UserLibraryService.instance.init();
    HomeTab.index.value = HomeTab.home;
  });

  test('HomeTab 为唯一状态源：值变化才通知，重复选中不重建', () {
    var notified = 0;
    void listener() => notified++;
    HomeTab.index.addListener(listener);
    addTearDown(() => HomeTab.index.removeListener(listener));

    HomeTab.select(HomeTab.local);
    expect(HomeTab.index.value, HomeTab.local);
    expect(notified, 1, reason: '切到本地应通知一次');

    HomeTab.select(HomeTab.local);
    expect(notified, 1, reason: '重复选中同一标签不应再通知');

    HomeTab.select(HomeTab.playlists);
    expect(HomeTab.index.value, HomeTab.playlists);
    expect(notified, 2);
  });

  test('侧栏断点：>=720 走左侧导航（顶部标签行同份状态下隐藏）', () {
    expect(HomeTab.useSideNav(360), isFalse);
    expect(HomeTab.useSideNav(719.9), isFalse);
    expect(HomeTab.useSideNav(720), isTrue);
    expect(HomeTab.useSideNav(1280), isTrue);
  });

  testWidgets('LibraryPage 内嵌形态：无 AppBar，三块歌单入口齐全', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: LibraryPage(embedded: true))),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      find.byType(AppBar),
      findsNothing,
      reason: '内嵌在首页「歌单」标签里时标题在导航上，不应再套一层 AppBar',
    );
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('新建歌单'), findsOneWidget);
    expect(find.text('我的歌单'), findsOneWidget);
    expect(find.text('酷狗歌单'), findsOneWidget);
  });

  testWidgets('LibraryPage 独立形态：保留 AppBar 与标题', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LibraryPage()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('歌单'), findsWidgets);
    expect(find.text('我喜欢的音乐'), findsOneWidget);
  });

  // golden：横屏右侧内容区（宽 620）里的歌单标签页观感留档
  testWidgets('golden: 歌单标签内嵌 @900x540', (tester) async {
    tester.view.physicalSize = const Size(900, 540);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'MiSans', useMaterial3: true),
        home: const Scaffold(
          backgroundColor: Color(0xFFF1F2F4),
          body: Center(
            child: SizedBox(width: 620, child: LibraryPage(embedded: true)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(LibraryPage),
      matchesGoldenFile('goldens/library_tab_embedded_900x540.png'),
    );
  });
}

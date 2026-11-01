// 「歌单」页与底部导航坞的回归测试。
//
// 背景：一级入口收敛为 首页 / 本地 / 歌单 / 我的，窄屏走底部导航坞、
// 宽屏走左侧导航；「歌单」是真实页面（我喜欢的音乐 / 我的歌单 / 酷狗歌单）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/screens/library_page.dart';
import 'package:such_music/services/user_library_service.dart';
import 'package:such_music/theme/app_theme.dart';
import 'package:such_music/widgets/app_bottom_dock.dart';

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

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(backgroundColor: AppColors.canvas, body: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await UserLibraryService.instance.init();
  });

  testWidgets('LibraryPage：三块歌单入口齐全，无多余 AppBar', (tester) async {
    await tester.pumpWidget(_host(const LibraryPage()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AppBar), findsNothing, reason: '标题由页面自身绘制');
    expect(find.text('歌单'), findsWidgets);
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('我的歌单'), findsOneWidget);
    expect(find.text('酷狗歌单'), findsOneWidget);
    expect(find.text('还没有自建歌单'), findsOneWidget);
  });

  testWidgets('底部导航坞：四项齐全，点击回传正确下标', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final picked = <int>[];
    await tester.pumpWidget(
      _host(
        Align(
          alignment: Alignment.bottomCenter,
          child: AppBottomDock(index: 0, onSelect: picked.add),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final label in ['首页', '本地', '歌单', '我的']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.tap(find.text('本地'));
    await tester.tap(find.text('歌单'));
    await tester.tap(find.text('我的'));
    expect(picked, [1, 2, 3]);
    expect(tester.takeException(), isNull);
  });

  // golden：手机竖屏「歌单」页观感留档
  testWidgets('golden: 歌单页 @390x844', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(const LibraryPage()));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(LibraryPage),
      matchesGoldenFile('goldens/library_page_390x844.png'),
    );
  });
}

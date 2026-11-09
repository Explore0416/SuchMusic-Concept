// 临时预览渲染：把 1.4.0 的新界面出成 PNG，供交付时人工核对。
// 用法：flutter test test/preview_render_test.dart --update-goldens --no-version-check
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/screens/library_page.dart';
import 'package:such_music/screens/local_music_page.dart';
import 'package:such_music/screens/profile_page.dart';
import 'package:such_music/screens/settings_page.dart';
import 'package:such_music/services/user_library_service.dart';
import 'package:such_music/theme/app_theme.dart';
import 'package:such_music/widgets/app_bottom_dock.dart';
import 'package:such_music/widgets/home_sections.dart';
import 'package:such_music/widgets/source_switcher.dart';

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
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: AppColors.canvas, body: child),
    );

SongModel _song(int i) => SongModel(
      id: 'preview-$i',
      name: const [
        '晴天',
        '夜曲',
        '富士山下',
        '起风了',
        '海阔天空',
        '平凡之路',
      ][i % 6],
      artist: const ['周杰伦', '周杰伦', '陈奕迅', '买辣椒也用券', 'Beyond', '朴树'][i % 6],
      album: '预览专辑',
    );

Widget _cover(double side, int i) => Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(const Color(0xFFB9C4D8), const Color(0xFF6E7A90), i / 6)!,
            Color.lerp(const Color(0xFF8794AC), const Color(0xFF3D4759), i / 6)!,
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.music_note_rounded, color: Colors.white54, size: 24),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadFonts);

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await UserLibraryService.instance.init();
    // 让预览稳定：固定 390×844
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget child, {
    Size size = const Size(390, 844),
    double heightFactor = 1.0,
  }) async {
    tester.view.physicalSize = Size(size.width, size.height * heightFactor);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(child));
    await tester.pump(const Duration(milliseconds: 300));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('preview/$name.png'),
    );
  }

  testWidgets('home', (tester) async {
    await shoot(
      tester,
      'home',
      SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 56),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('下午好', style: AppType.display),
                  ),
                  Text('11 月 9 日 周日', style: AppType.caption),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: SourceSwitcher(),
            ),
            HomeSearchEntry(onTap: () {}),
            const SizedBox(height: 24),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('猜你想听', style: AppType.title),
            ),
            const SizedBox(height: 16),
            PickRail(
              songs: List.generate(4, _song),
              coverOf: (s, side) => _cover(side, int.parse(s.id.split("-").last)),
              onSongTap: (_) {},
            ),
            const HomeSectionSpacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  const Expanded(child: Text('每日推荐', style: AppType.title)),
                  Text('全部', style: AppType.caption.copyWith(color: AppColors.brand)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            DailyGrid(
              songs: List.generate(6, (i) => _song(i + 1)),
              coverOf: (s, side) => _cover(side, 1),
              onSongTap: (_) {},
            ),
            const HomeSectionSpacer(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Text('热歌推荐', style: AppType.title),
            ),
            const SizedBox(height: 16),
            HotRankList(
              songs: List.generate(5, (i) => _song(i)),
              coverOf: (s, side) => _cover(side, 2),
              onSongTap: (_) {},
            ),
            const SizedBox(height: 120),
          ],
        ),
      ),
      heightFactor: 2.0,
    );
  });

  testWidgets('profile', (tester) async {
    await shoot(tester, 'profile', const ProfilePage(), heightFactor: 1.6);
  });

  testWidgets('settings', (tester) async {
    await shoot(tester, 'settings', const SettingsPage(), heightFactor: 1.6);
  });

  testWidgets('library', (tester) async {
    await shoot(tester, 'library', const LibraryPage());
  });

  testWidgets('local', (tester) async {
    await shoot(tester, 'local', const LocalMusicPage(), heightFactor: 1.3);
  });

  testWidgets('player-card', (tester) async {
    await shoot(
      tester,
      'player-card',
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 0),
            color: AppColors.canvas,
            child: MiniPlayerCard(
              title: '富士山下',
              subtitle: '陈奕迅',
              cover: _cover(48, 2),
              isPlaying: true,
              progress: 0.42,
              onTap: () {},
              onToggle: () {},
              onSeek: (_) {},
              onPrevious: () {},
              onNext: () {},
            ),
          ),
          const SizedBox(height: 16),
          const Text('播放卡（76 高 / 3px 可拖进度 / 上下曲）',
              style: AppType.caption),
        ],
      ),
      size: const Size(390, 220),
    );
  });
}

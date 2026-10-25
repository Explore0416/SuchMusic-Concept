// 横屏 / 平板形态：底部常驻播放条（PlayerBar）+ 外壳接入。
//
// 覆盖需求「横屏下能看到并控制正在播放的歌」：
//  - 展示歌名 / 歌手 / 时间；
//  - 播放暂停 / 上一首 / 下一首 / 播放模式 回调；
//  - 无歌曲时展示占位且控件禁用；
//  - 平板断点下 ResponsiveScaffold 采用 Android 底部胶囊栏（不移植 PC 侧边栏）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/audio_player_service.dart';
import 'package:such_music/widgets/player_bar.dart';
import 'package:such_music/widgets/responsive_scaffold.dart';

const _song = SongModel(
  id: '1',
  name: '晴天',
  artist: '周杰伦',
  album: '叶惠美',
  source: SongSource.kugou,
);

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: child),
    );

PlayerBar _bar({
  SongModel? song = _song,
  bool isPlaying = true,
  VoidCallback? onToggle,
  VoidCallback? onPrev,
  VoidCallback? onNext,
  VoidCallback? onMode,
  ValueChanged<Duration>? onSeek,
  VoidCallback? onOpen,
}) =>
    PlayerBar(
      song: song,
      isPlaying: isPlaying,
      position: const Duration(seconds: 12),
      duration: const Duration(minutes: 3, seconds: 45),
      playMode: PlayMode.loop,
      onTogglePlayPause: onToggle ?? () {},
      onPrevious: onPrev ?? () {},
      onNext: onNext ?? () {},
      onTogglePlayMode: onMode ?? () {},
      onSeek: onSeek ?? (_) {},
      onOpenPlayer: onOpen ?? () {},
    );

void main() {
  group('PlayerBar（横屏常驻播放条）', () {
    testWidgets('展示歌名 / 歌手 / 时间（mm:ss / mm:ss）', (tester) async {
      await tester.pumpWidget(_host(_bar()));
      await tester.pump();

      expect(find.text('晴天'), findsOneWidget);
      expect(find.text('周杰伦'), findsOneWidget);
      expect(find.text('00:12 / 03:45'), findsOneWidget);
    });

    testWidgets('播放暂停 / 上一首 / 下一首 / 播放模式 均可触发', (tester) async {
      var toggle = 0, prev = 0, next = 0, mode = 0;
      await tester.pumpWidget(_host(_bar(
        onToggle: () => toggle++,
        onPrev: () => prev++,
        onNext: () => next++,
        onMode: () => mode++,
      )));
      await tester.pump();

      await tester.tap(find.byTooltip('暂停'));
      await tester.tap(find.byTooltip('上一首'));
      await tester.tap(find.byTooltip('下一首'));
      await tester.tap(find.byTooltip('播放模式'));
      await tester.pump();

      expect(toggle, 1);
      expect(prev, 1);
      expect(next, 1);
      expect(mode, 1);
    });

    testWidgets('未播放时主按钮显示「播放」', (tester) async {
      await tester.pumpWidget(_host(_bar(isPlaying: false)));
      await tester.pump();
      expect(find.byTooltip('播放'), findsOneWidget);
    });

    testWidgets('无歌曲：显示占位且控制禁用（点击不触发回调）', (tester) async {
      var prev = 0, toggle = 0;
      await tester.pumpWidget(_host(_bar(
        song: null,
        isPlaying: false,
        onPrev: () => prev++,
        onToggle: () => toggle++,
      )));
      await tester.pump();

      expect(find.text('暂无播放'), findsOneWidget);

      await tester.tap(find.byTooltip('上一首'), warnIfMissed: false);
      await tester.tap(find.byTooltip('播放'), warnIfMissed: false);
      await tester.pump();

      expect(prev, 0);
      expect(toggle, 0);
    });

    testWidgets('点击左侧歌曲信息可打开播放页', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_host(_bar(onOpen: () => opened++)));
      await tester.pump();

      await tester.tap(find.text('晴天'));
      await tester.pump();
      expect(opened, 1);
    });
  });

  group('ResponsiveScaffold 平板形态接入 PlayerBar', () {
    // 真实 PlayerBar 在多个平板/横屏尺寸下渲染，均不得溢出
    for (final size in const [Size(900, 600), Size(1280, 800), Size(1600, 900)]) {
      testWidgets(
          '宽 ${size.width.toInt()}（平板横屏）→ 底部胶囊栏且无溢出',
          (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(MaterialApp(
          home: ResponsiveScaffold(
            currentIndex: 0,
            onDestinationSelected: (_) {},
            destinations: const [
              NavDestination(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home,
                  label: '首页'),
              NavDestination(
                  icon: Icons.person_outline,
                  selectedIcon: Icons.person,
                  label: '我的'),
            ],
            body: const SizedBox.shrink(),
            bottomBar: const Text('手机底部胶囊栏'),
            playerBar: _bar(),
          ),
        ));
        await tester.pump();

        expect(tester.takeException(), isNull, reason: '不应有溢出/异常');
        // 横屏不再移植 PC 侧边栏：没有 Logo 区、没有常驻播放条
        expect(find.text('SuchMusic概念版'), findsNothing);
        expect(find.byType(PlayerBar), findsNothing);
        // 沿用手机端底部胶囊栏
        expect(find.text('手机底部胶囊栏'), findsOneWidget);
      });
    }

    testWidgets('宽 430（手机竖屏 B1）→ 用悬浮胶囊栏，不渲染 PlayerBar', (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: ResponsiveScaffold(
          currentIndex: 0,
          onDestinationSelected: (_) {},
          destinations: const [
            NavDestination(
                icon: Icons.home_outlined,
                selectedIcon: Icons.home,
                label: '首页'),
          ],
          body: const SizedBox.shrink(),
          bottomBar: const Text('手机底部胶囊栏'),
          playerBar: _bar(),
        ),
      ));
      await tester.pump();

      expect(find.text('手机底部胶囊栏'), findsOneWidget);
      expect(find.byType(PlayerBar), findsNothing);
    });
  });
}

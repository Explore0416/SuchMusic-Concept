// 外壳组件（ResponsiveScaffold / ResponsiveContent）多尺寸冒烟测试。
//
// 目的：在 320→1600dp 各断点下 pump 外壳，断言**无 overflow / 无未捕获异常**，
// 并验证横屏大屏（B4/B5）沿用 Android 底部胶囊栏（不再移植 PC 侧边栏）、
// 竖屏（B1/B3）与手机横屏（B2）保留原版悬浮胶囊栏。
// 说明：PlayerPage / SettingsPage 依赖 just_audio/audio_service 等平台插件，
// 在纯 Dart 测试环境无法构造，需真机验证（见 QA 报告「未验证项」）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/utils/responsive.dart';
import 'package:such_music/widgets/responsive_scaffold.dart';

/// 播放条占位（真实 PlayerBar 的溢出验证见 player_bar_test.dart）。
const _playerBarKey = Key('playerBar');

ResponsiveScaffold _shell() => ResponsiveScaffold(
      currentIndex: 0,
      onDestinationSelected: (_) {},
      destinations: const [
        NavDestination(
            icon: Icons.home_outlined, selectedIcon: Icons.home, label: '首页'),
        NavDestination(
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
            label: '我的'),
      ],
      body: const SizedBox.expand(),
      bottomBar: const SizedBox(width: 120, height: 48),
      playerBar: const SizedBox(key: _playerBarKey, height: 80),
    );

void main() {
  const sizes = <Size>[
    Size(320, 800),
    Size(393, 852),
    Size(430, 932),
    Size(600, 960),
    Size(840, 1200),
    Size(900, 600),
    Size(1200, 800),
    Size(1600, 900),
  ];

  for (final size in sizes) {
    testWidgets(
        'ResponsiveScaffold @${size.width.toInt()}x${size.height.toInt()} 无溢出异常',
        (tester) async {
      // 用 tester.view 驱动 MediaQuery.sizeOf（setSurfaceSize 在本版本不改 MediaQuery）
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(home: _shell()));
      await tester.pump();

      expect(tester.takeException(), isNull);

      if (Responsive.showRail(Responsive.of(size))) {
        // 横屏大屏：**不再使用 PC 侧边栏**，沿用 Android 底部胶囊栏
        expect(find.text('SuchMusic概念版'), findsNothing,
            reason: '横屏不应出现 PC 侧边栏的 Logo 区');
        expect(find.byType(NavigationRail), findsNothing,
            reason: '横屏不使用 NavigationRail');
        expect(find.byKey(_playerBarKey), findsNothing,
            reason: '横屏不再渲染 PC 风格常驻播放条');
        expect(tester.takeException(), isNull);
      } else {
        // 竖屏（B1 手机竖屏 / B3 平板竖屏）与手机横屏（B2）：原版悬浮胶囊栏
        expect(find.byType(NavigationRail), findsNothing,
            reason: '竖屏 / 手机形态应保留悬浮胶囊栏');
        expect(find.byKey(_playerBarKey), findsNothing,
            reason: '竖屏形态不渲染底部播放条（与原版一致）');
      }
    });
  }

  testWidgets('ResponsiveContent 在超宽屏夹取到 contentMaxWidth 并居中', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ResponsiveContent(
          child: SizedBox(key: const Key('c'), width: 2000, height: 40),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    final box = tester.getSize(find.byKey(const Key('c')));
    expect(box.width, lessThanOrEqualTo(Responsive.contentMaxWidth));
    expect(box.width, closeTo(Responsive.contentMaxWidth, 0.5));
  });
}

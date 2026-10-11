// 外壳组件（ResponsiveScaffold / ResponsiveContent）多尺寸冒烟测试。
//
// 目的：在 320→1600dp 各断点下 pump 外壳，断言**无 overflow / 无未捕获异常**，
// 并验证平板形态切换为 NavigationRail、手机形态不出现 NavigationRail。
// 说明：PlayerPage / SettingsPage 依赖 just_audio/audio_service 等平台插件，
// 在纯 Dart 测试环境无法构造，需真机验证（见 QA 报告「未验证项」）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/utils/responsive.dart';
import 'package:such_music/widgets/responsive_scaffold.dart';

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

      if (Responsive.isTablet(size)) {
        expect(find.byType(NavigationRail), findsOneWidget,
            reason: '平板形态应使用 NavigationRail');
      } else {
        expect(find.byType(NavigationRail), findsNothing,
            reason: '手机形态应保留悬浮胶囊栏');
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

// 「我的」页登录入口：一个入口覆盖全部音源，页面内不再重复挂账号入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/screens/profile_page.dart';
import 'package:such_music/services/app_init.dart';

void main() {
  Future<void> pumpProfile(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    markInitialized();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ProfilePage())),
    );
    await tester.pump();
  }

  testWidgets('未登录：页面只有一个登录入口，不再挂「音源账号」区块', (tester) async {
    await pumpProfile(tester);

    expect(find.text('登录'), findsOneWidget);
    // 音源账号区块已并入登录弹层
    expect(find.text('音源账号'), findsNothing);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('点登录打开统一弹层，可在网易云 / 酷狗之间切换', (tester) async {
    await pumpProfile(tester);

    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 弹层标题与两个音源分段同时出现
    expect(find.text('登录'), findsWidgets);
    expect(find.text('网易云音乐'), findsWidgets);
    expect(find.text('酷狗音乐'), findsWidgets);
  });

  testWidgets('切到酷狗后展示概念版与原版两行授权入口', (tester) async {
    await pumpProfile(tester);

    await tester.tap(find.text('登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 分段按钮里的「酷狗音乐」——取第一个可点的
    await tester.tap(find.text('酷狗音乐').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('酷狗概念版'), findsOneWidget);
    expect(find.text('酷狗音乐'), findsWidgets);
    expect(find.text('去登录'), findsWidgets);
  });
}

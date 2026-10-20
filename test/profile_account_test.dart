// 「我的」页音源账号卡片：网易云一家、酷狗一家，共两行入口。
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

  testWidgets('未登录态只展示「网易云音乐」「酷狗音乐」两个入口', (tester) async {
    await pumpProfile(tester);

    expect(find.text('网易云音乐'), findsOneWidget);
    expect(find.text('酷狗音乐'), findsOneWidget);
    // 概念版不再单独占一行（两行酷狗已合并为一个入口）
    expect(find.text('酷狗概念版'), findsNothing);
    expect(find.text('扫码登录'), findsWidgets);
  });

  testWidgets('点「酷狗音乐」打开聚合面板，两个平台各一行', (tester) async {
    await pumpProfile(tester);

    await tester.tap(find.text('酷狗音乐'));
    await tester.pumpAndSettle();

    // 面板里出现两个平台（标题也叫「酷狗音乐」，故用 findsWidgets）
    expect(find.text('酷狗概念版'), findsOneWidget);
    expect(find.text('酷狗音乐'), findsWidgets);
    expect(find.text('扫码登录'), findsWidgets);
  });
}

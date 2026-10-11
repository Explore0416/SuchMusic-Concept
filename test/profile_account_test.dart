// 「我的」页音源账号卡片：未登录态应同时提供网易云与酷狗概念版入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/screens/profile_page.dart';
import 'package:such_music/services/app_init.dart';

void main() {
  testWidgets('未登录态展示「网易云音乐」「酷狗概念版」两个账号入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    markInitialized();
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ProfilePage())));
    await tester.pump();

    expect(find.text('网易云音乐'), findsOneWidget);
    expect(find.text('酷狗概念版'), findsOneWidget);
    // 酷狗行应可直接扫码登录（无需进设置）
    expect(find.text('扫码登录'), findsWidgets);
  });
}

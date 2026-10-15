// 灰屏（release 模式 RenderErrorBox）复现/回归测试。
//
// 背景：用户实测「关闭音效面板后整屏灰屏约 1 秒」。灰屏 = release 下
// `RenderErrorBox`（0xF0C0C0C0），意味着某个 widget 在 build/layout/paint
// 阶段抛出了未捕获异常。本用例把**真实 SettingsPage** 放进 widget test，
// 完整走一遍「进入设置页 → 打开音效面板 → 点预设 → 关闭面板」，
// 逐帧用 `tester.takeException()` 抓异常，确保该路径不再抛异常。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/screens/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const soundFx = MethodChannel('com.lightningteam.suchmusic/soundfx');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 通道行为：可用 + 有预设；apply 返回 false（模拟「无播放会话」失败分支）
    messenger.setMockMethodCallHandler(soundFx, (call) async {
      switch (call.method) {
        case 'available':
          return true;
        case 'presets':
          return <Map<String, String>>[
            {'code': 'default', 'name': '默认', 'desc': '不做任何增益'},
            {'code': 'origin_voice', 'name': '原声人声', 'desc': '突出人声'},
          ];
        case 'current':
          return 'off';
        case 'apply':
          return false;
        case 'diagnose':
          return <String, Object?>{
            'sdkInt': 34,
            'deviceModel': 'test',
            'success': false,
            'lastError': '',
          };
        case 'disable':
          return true;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(soundFx, null);
  });

  /// 收集当前帧及随后每帧的异常，返回全部捕获到的异常描述。
  Future<List<String>> drainExceptions(WidgetTester tester, int frames) async {
    final found = <String>[];
    for (var i = 0; i < frames; i++) {
      final e = tester.takeException();
      if (e != null) found.add(e.toString());
      await tester.pump(const Duration(milliseconds: 250));
    }
    return found;
  }

  testWidgets('设置页 → 音效面板 → 点预设 → 关闭：全程无未捕获异常（无灰屏）',
      (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '设置页首次渲染不应抛异常');

    // 打开「音效」面板
    await tester.scrollUntilVisible(find.text('音效'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('音效'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '打开音效面板不应抛异常');
    expect(find.text('默认'), findsOneWidget, reason: '面板应展示预设列表');

    // 点一个预设：apply 返回 false 且无播放会话 → 走「失败分支」并弹轻提示
    await tester.tap(find.text('默认'));
    final afterApply = await drainExceptions(tester, 6);
    expect(afterApply, isEmpty, reason: '点击预设不应抛异常：$afterApply');

    // 关闭面板：点右上角关闭按钮
    await tester.tap(find.byIcon(Icons.close));
    final afterClose = await drainExceptions(tester, 16);
    expect(afterClose, isEmpty,
        reason: '关闭面板后（含 setState 全页重建 + 2s 轻提示定时器）不应抛异常：$afterClose');
  });
}

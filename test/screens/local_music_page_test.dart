import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/screens/local_music_page.dart';

/// 本地音乐页的结构验证：用平台通道桩喂入固定数据，
/// 断言列表数量、格式标签、删除/空态分支，确保不会在真机上因数据形状崩溃。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.lightningteam.suchmusic/local_music');

  void mockScan(Map<String, dynamic> payload) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scan') return payload;
      if (call.method == 'hasAllFilesAccess') return payload['allFilesAccess'];
      return null;
    });
  }

  Map<String, dynamic> track({
    required String name,
    required String ext,
    required String kind,
    int durationMs = 215000,
    String? path,
  }) {
    return {
      'uri': kind == 'kgm' ? 'file:///storage/emulated/0/Music/$name.$ext' : 'content://media/1',
      'path': path,
      'name': name,
      'artist': '测试歌手',
      'album': '测试专辑',
      'durationMs': durationMs,
      'size': 1024,
      'ext': ext,
      'kind': kind,
    };
  }

  testWidgets('渲染曲目列表、KGM 标签与统计文案', (tester) async {
    mockScan({
      'tracks': [
        track(name: '普通歌曲', ext: 'mp3', kind: 'media'),
        track(
          name: '加密歌曲',
          ext: 'kgm',
          kind: 'kgm',
          path: '/storage/emulated/0/Music/加密歌曲.kgm',
        ),
      ],
      'audioPermission': true,
      'allFilesAccess': true,
    });

    await tester.pumpWidget(
      const MaterialApp(home: LocalMusicPage()),
    );
    await tester.pumpAndSettle();

    expect(find.text('本地音乐'), findsOneWidget);
    expect(find.text('共 2 首 · 其中加密格式 1 首'), findsOneWidget);
    expect(find.text('普通歌曲'), findsOneWidget);
    expect(find.text('加密歌曲'), findsOneWidget);
    // 格式标签：MP3 / KGM
    expect(find.text('MP3'), findsOneWidget);
    expect(find.text('KGM'), findsOneWidget);
    // 时长格式化（215000ms → 03:35）
    expect(find.text('03:35'), findsNWidgets(2));
  });

  testWidgets('未授予文件访问权限时出现授权引导卡', (tester) async {
    mockScan({
      'tracks': [track(name: '普通歌曲', ext: 'mp3', kind: 'media')],
      'audioPermission': true,
      'allFilesAccess': false,
    });

    await tester.pumpWidget(const MaterialApp(home: LocalMusicPage()));
    await tester.pumpAndSettle();

    expect(find.text('解锁 .kgm 等加密格式'), findsOneWidget);
    expect(find.text('去授权'), findsOneWidget);
  });

  testWidgets('已授权时不显示授权引导', (tester) async {
    mockScan({
      'tracks': [track(name: '普通歌曲', ext: 'mp3', kind: 'media')],
      'audioPermission': true,
      'allFilesAccess': true,
    });

    await tester.pumpWidget(const MaterialApp(home: LocalMusicPage()));
    await tester.pumpAndSettle();

    expect(find.text('解锁 .kgm 等加密格式'), findsNothing);
  });

  testWidgets('空列表展示空态且不显示「播放全部」', (tester) async {
    mockScan({
      'tracks': <Map<String, dynamic>>[],
      'audioPermission': true,
      'allFilesAccess': true,
    });

    await tester.pumpWidget(const MaterialApp(home: LocalMusicPage()));
    await tester.pumpAndSettle();

    expect(find.text('未找到本地音乐'), findsOneWidget);
    expect(find.text('设备上暂无可播放的音频'), findsOneWidget);
    expect(find.text('播放全部'), findsNothing);
  });
}

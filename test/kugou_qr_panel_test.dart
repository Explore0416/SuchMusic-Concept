import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:such_music/services/sources/kugou_login_models.dart';
import 'package:such_music/widgets/kugou_qr_panel.dart';

/// 1×1 透明 PNG（合法 base64）。
const String _png1x1 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

KugouQrSession session({String image = '', String key = 'KEY'}) => KugouQrSession(
      key: key,
      imageDataUri: image,
      expiresAt: DateTime(2030),
    );

Future<void> pumpPanel(
  WidgetTester tester, {
  required QrLoginState state,
  KugouQrSession? s,
  VoidCallback? onRefresh,
}) {
  return tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: KugouQrPanel(state: state, session: s, onRefresh: onRefresh),
    ),
  ));
}

void main() {
  group('KugouQrPanel 状态文案', () {
    testWidgets('session 为空 → 占位「获取二维码中…」', (tester) async {
      await pumpPanel(tester, state: QrLoginState.waiting);
      expect(find.text('获取二维码中…'), findsOneWidget);
    });

    testWidgets('waiting 文案', (tester) async {
      await pumpPanel(tester, state: QrLoginState.waiting, s: session());
      expect(find.text('请使用酷狗概念版 App 扫码'), findsOneWidget);
    });

    testWidgets('scanned 文案', (tester) async {
      await pumpPanel(tester, state: QrLoginState.scanned, s: session());
      expect(find.text('已扫码，请在手机上确认'), findsOneWidget);
    });

    testWidgets('success 文案', (tester) async {
      await pumpPanel(tester, state: QrLoginState.success, s: session());
      expect(find.text('登录成功'), findsOneWidget);
    });

    testWidgets('expired 文案 + 刷新回调', (tester) async {
      var refreshed = 0;
      await pumpPanel(
        tester,
        state: QrLoginState.expired,
        s: session(),
        onRefresh: () => refreshed++,
      );
      expect(find.text('二维码已过期，正在刷新…'), findsOneWidget);
      await tester.tap(find.text('刷新二维码'));
      expect(refreshed, 1);
    });

    testWidgets('failed 文案 + 刷新回调', (tester) async {
      var refreshed = 0;
      await pumpPanel(
        tester,
        state: QrLoginState.failed,
        s: session(),
        onRefresh: () => refreshed++,
      );
      expect(find.text('获取失败，点击重试'), findsOneWidget);
      await tester.tap(find.text('刷新二维码'));
      expect(refreshed, 1);
    });
  });

  group('KugouQrPanel 二维码渲染优先级', () {
    testWidgets('合法 data-URI → 优先 Image.memory', (tester) async {
      await pumpPanel(
        tester,
        state: QrLoginState.waiting,
        s: session(image: 'data:image/png;base64,$_png1x1'),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('无 data-URI → qr_flutter 渲染 placeholderUrl', (tester) async {
      await pumpPanel(
        tester,
        state: QrLoginState.waiting,
        s: session(image: ''),
      );
      expect(find.byType(QrImageView), findsOneWidget);
    });

    testWidgets('data-URI 解析失败 → 回退 qr_flutter，不崩溃', (tester) async {
      await pumpPanel(
        tester,
        state: QrLoginState.waiting,
        s: session(image: 'data:image/png;base64,@@@@not-base64@@@@'),
      );
      expect(find.byType(QrImageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('placeholderUrl 使用 qrcode=<key>', (tester) async {
      final s = session(key: 'XYZ');
      expect(s.placeholderUrl,
          'https://h5.kugou.com/apps/loginQRCode/html/index.html?qrcode=XYZ');
    });
  });
}

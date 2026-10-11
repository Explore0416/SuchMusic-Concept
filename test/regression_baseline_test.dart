// 回归护栏：430×932 竖屏基线 + 扫码登录增量「不污染音源状态 / 不越权持久化」。
//
// 目的：证明本次增量（扫码登录 + 两处缺陷修复）**不改变**既有已通过行为：
//  - 430×932 竖屏基线取值不变；
//  - 登录服务只产出 token/userid，不触碰 SourceManager / 播放队列 / prefs。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/models/song_model.dart';
import 'package:such_music/services/sources/kugou_config.dart';
import 'package:such_music/services/sources/kugou_login_service.dart';
import 'package:such_music/services/sources/source_manager.dart';
import 'package:such_music/utils/app_constants.dart';
import 'package:such_music/utils/responsive.dart';

import 'support/fake_dio.dart';

void main() {
  group('430×932 竖屏基线（不得回归）', () {
    const baseline = Size(430, 932);

    test('uiScale == 1.0', () {
      expect(Responsive.uiScale(baseline), 1.0);
    });

    test('断点 == B1 手机竖屏', () {
      expect(Responsive.of(baseline), AppBreakpoint.b1PhonePortrait);
      expect(Responsive.isTablet(baseline), isFalse);
    });

    test('contentWidth == 430（不夹取）', () {
      expect(Responsive.contentWidth(baseline), 430.0);
    });

    test('常量不变：contentMaxWidth=960 / minTouchTarget=48 / designWidth=430', () {
      expect(Responsive.contentMaxWidth, 960);
      expect(Responsive.minTouchTarget, 48);
      expect(Responsive.designWidth, 430);
      expect(Responsive.textScaleMin, 0.85);
      expect(Responsive.textScaleMax, 1.3);
    });

    test('封面尺寸保持「屏宽 - 50」= 380', () {
      expect(Responsive.coverSize(baseline, AppBreakpoint.b1PhonePortrait),
          380.0);
    });
  });

  group('扫码登录增量不回归护栏', () {
    test('登录成功不改变 SourceManager.currentSource / 不触发音源广播', () async {
      final sm = SourceManager();
      final before = sm.currentSource;
      final emitted = <SongSource>[];
      final sub = sm.onSourceChanged.listen(emitted.add);

      final adapter = FakeAdapter((o) {
        if (o.path.endsWith(KugouConfig.loginQrPath)) {
          return Future.value(jsonResponse({
            'status': 1,
            'data': {'qrcode': 'K', 'qrcode_img': ''},
          }));
        }
        return Future.value(jsonResponse({
          'status': 1,
          'data': {'status': 4, 'token': 'TK', 'userid': '88'},
        }));
      });
      final svc = KugouLoginService(
        dio: fakeDio(adapter),
        pollInterval: Duration.zero,
      );

      final events = await svc.startAutoLogin().toList();
      expect(events.last.state.name, 'success');

      // 音源未被改动
      expect(sm.currentSource, before);
      // 无音源切换广播
      expect(emitted, isEmpty);

      await sub.cancel();
    });

    test('登录服务不越权写 prefs（持久化由 UI 触发）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final adapter = FakeAdapter((o) {
        if (o.path.endsWith(KugouConfig.loginQrPath)) {
          return Future.value(jsonResponse({
            'status': 1,
            'data': {'qrcode': 'K', 'qrcode_img': ''},
          }));
        }
        return Future.value(jsonResponse({
          'status': 1,
          'data': {'status': 4, 'token': 'TK', 'userid': '88'},
        }));
      });
      final svc = KugouLoginService(
        dio: fakeDio(adapter),
        pollInterval: Duration.zero,
      );
      await svc.startAutoLogin().toList();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppConstants.kugouToken), isNull);
      expect(prefs.getString(AppConstants.kugouUserid), isNull);
    });
  });
}

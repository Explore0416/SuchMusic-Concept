// CrashLogService（全局异常兜底 + 落盘）单元测试。
//
// 覆盖点：
//  - record() 落盘内容（异常 / 堆栈 / 来源）与 lastError 同步；
//  - 滚动保留最近 maxEntries 条；
//  - 无日志时 readAll() 安全返回空串；
//  - install() 幂等，且 **debug 下保留红屏**（不把 ErrorWidget.builder 降级为占位）。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/crash_log_service.dart';

void main() {
  final svc = CrashLogService.instance;
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('crashlog_test');
    svc.debugReset();
    svc.debugDirectoryOverride = dir;
  });

  tearDown(() async {
    svc.debugReset();
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('无日志时 readAll 安全返回空串', () async {
    expect(await svc.readAll(), '');
  });

  test('record 落盘：含异常 / 来源 / 堆栈，lastError 同步', () async {
    await svc.record(StateError('boom'), StackTrace.current, source: 'unit');

    final log = await svc.readAll();
    expect(log, contains('boom'));
    expect(log, contains('source: unit'));
    expect(log, contains('stack:'));
    expect(svc.lastError, isNotNull);
    expect(svc.lastError, contains('boom'));
  });

  test('滚动保留最近 maxEntries 条', () async {
    for (var i = 0; i < CrashLogService.maxEntries + 3; i++) {
      await svc.record(ArgumentError('boom-$i'), StackTrace.current, source: 'unit');
    }

    final log = await svc.readAll();
    final count = CrashLogService.entrySeparator.allMatches(log).length;
    expect(count, CrashLogService.maxEntries, reason: '应滚动保留最近 N 条');
    expect(log, contains('boom-${CrashLogService.maxEntries + 2}'));
    expect(log, isNot(contains('boom-0')), reason: '最旧的一条应被滚出');
  });

  test('install 幂等；debug 下保留红屏（不降级为占位）', () async {
    final before = ErrorWidget.builder(FlutterErrorDetails(exception: 'x'));
    svc.install();
    svc.install(); // 重复安装应无副作用
    final after = ErrorWidget.builder(FlutterErrorDetails(exception: 'x'));

    // debug 下应仍返回默认红屏组件（与安装前同类型），而非 SizedBox 占位。
    expect(after.runtimeType, before.runtimeType);
    expect(after, isNot(isA<SizedBox>()));
  });
}

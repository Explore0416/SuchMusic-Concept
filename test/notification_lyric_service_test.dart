// NotificationLyricService 去重 / 节流 / 空行过滤 / 开关行为测试（REQ-06 边界 e）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:such_music/services/notification_lyric_service.dart';

Future<void> zero() => Future<void>.delayed(Duration.zero);

void main() {
  final svc = NotificationLyricService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    svc.setEnabled(true);
    svc.reset();
  });

  test('仅文本变化才更新 + 空行过滤', () async {
    final events = <String>[];
    final sub = svc.onSubtitleChanged.listen(events.add);
    addTearDown(sub.cancel);

    svc.feed('A');
    await zero();
    svc.feed('A'); // 文本未变 → 去重
    await zero();
    svc.feed(''); // 空行 → 过滤
    await zero();
    svc.feed('   '); // 纯空白 → 过滤
    await zero();

    expect(events, ['A']);
  });

  test('节流：500ms 内的第二次不同行被丢弃；超过 500ms 后可再次推送', () async {
    final events = <String>[];
    final sub = svc.onSubtitleChanged.listen(events.add);
    addTearDown(sub.cancel);

    svc.reset(); // 清空内部节流窗口
    svc.feed('A');
    await zero();
    svc.feed('B'); // 距 A ~0ms → 被节流
    await zero();
    expect(events.where((e) => e.isNotEmpty).toList(), ['A']);

    await Future<void>.delayed(const Duration(milliseconds: 550));
    svc.feed('C');
    await zero();
    expect(events.where((e) => e.isNotEmpty).toList(), ['A', 'C']);
  });

  test('≤2 次/秒：同一时刻连续多个不同行只放行 1 条', () async {
    final events = <String>[];
    final sub = svc.onSubtitleChanged.listen(events.add);
    addTearDown(sub.cancel);

    svc.reset();
    for (final t in ['1', '2', '3', '4', '5']) {
      svc.feed(t);
    }
    await zero();
    expect(events.where((e) => e.isNotEmpty).length, 1);
  });

  test('关闭开关：不再推送；并推空串以恢复「歌手 - 专辑」', () async {
    final events = <String>[];
    final sub = svc.onSubtitleChanged.listen(events.add);
    addTearDown(sub.cancel);

    svc.setEnabled(true);
    svc.feed('X');
    await zero();

    svc.setEnabled(false); // 内部 reset() → 推空串
    await zero();
    expect(events.last, ''); // 空串 → Handler 回退「歌手 - 专辑」

    svc.feed('Y'); // 关闭态：只更新 lastLine，不推送
    await zero();
    expect(events.where((e) => e.isNotEmpty).toList(), ['X']);
  });

  test('重新开启开关：把上一有效行再推一次', () async {
    final events = <String>[];
    final sub = svc.onSubtitleChanged.listen(events.add);
    addTearDown(sub.cancel);

    svc.setEnabled(true);
    svc.feed('Q');
    await zero();

    svc.setEnabled(false);
    svc.feed('Y'); // 记录 lastLine='Y'，关闭态不推送
    await zero();

    svc.setEnabled(true); // 重新开启 → 推送 lastLine
    await zero();
    expect(events.last, 'Y');
  });

  test('reset() 推空串并清空去重状态（切歌场景）', () async {
    final events = <String>[];
    final sub = svc.onSubtitleChanged.listen(events.add);
    addTearDown(sub.cancel);

    svc.feed('A');
    await zero();
    svc.reset(); // 切歌 → 空串 + 清 lastLine
    await zero();
    svc.feed('A'); // 重置后可再次推送相同的 'A'
    await zero();
    expect(events.where((e) => e.isNotEmpty).toList(), ['A', 'A']);
  });

  test('开关默认值读取：默认开启', () {
    expect(svc.enabled, isTrue);
  });
}

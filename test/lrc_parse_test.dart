// 歌词解析测试。
//
// `parseLrc` 已从 `AudioPlayerService._parseLrc` 提取为
// `lib/services/lyrics_parser.dart` 的**顶层函数**（并通过 audio_player_service.dart
// re-export），此处直接覆盖真实源码实现，不再使用镜像副本。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/lyrics_parser.dart';

void main() {
  group('LRC 解析', () {
    test('[mm:ss.xx] 两位毫秒 → 补齐为毫秒（xx0）', () {
      final r = parseLrc('[00:01.23]第一行');
      expect(r.length, 1);
      expect(r.first.timestamp, const Duration(seconds: 1, milliseconds: 230));
      expect(r.first.text, '第一行');
    });

    test('[mm:ss.xxx] 三位毫秒 → 原样解析', () {
      final r = parseLrc('[00:01.234]第一行');
      expect(r.first.timestamp, const Duration(seconds: 1, milliseconds: 234));
    });

    test('乱序时间戳 → 解析后按时间升序排列', () {
      final r = parseLrc('[00:03.00]C\n[00:01.00]A\n[00:02.00]B');
      expect(r.map((e) => e.text).toList(), ['A', 'B', 'C']);
      expect(r.map((e) => e.timestamp).toList(), [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 3),
      ]);
    });

    test('空行 / 纯时间戳行（无文本）被过滤；非时间戳行被忽略', () {
      final r = parseLrc(
        '[00:01.00]A\n\n[00:02.00]\n   \n[offset:0]\n[00:03.00]B',
      );
      expect(r.map((e) => e.text).toList(), ['A', 'B']);
    });

    test('文本首尾空白被 trim', () {
      final r = parseLrc('[00:01.00]   带空格歌词   ');
      expect(r.first.text, '带空格歌词');
    });

    test('01:70 这类分钟/秒组合按字面解析（不做进位校验）', () {
      final r = parseLrc('[01:70.00]溢出秒');
      // Duration 会自动归一化：1 分 70 秒 = 130 秒
      expect(r.first.timestamp, const Duration(seconds: 130));
    });

    test('空字符串输入 → 空列表', () {
      expect(parseLrc(''), isEmpty);
    });

    test('多行时间戳同行文本（多标签行）只取首个匹配标签', () {
      // 当前实现用 firstMatch：一行内多个 [..] 只解析第一个
      final r = parseLrc('[00:01.00][00:02.00]合并行');
      expect(r.length, 1);
      expect(r.first.timestamp, const Duration(seconds: 1));
      expect(r.first.text, '[00:02.00]合并行');
    });

    // ── 边界加固（第 2 轮）─────────────────────────────────────
    test('无时间戳行 → 全部忽略，返回空列表', () {
      expect(parseLrc('这是普通文本\n[offset:0]\n无标签'), isEmpty);
    });

    test('只有时间戳无文本 → 被过滤（不产生空文本行）', () {
      expect(parseLrc('[00:01.00]\n[00:02.00]   '), isEmpty);
    });

    test('重复时间戳 → 两行均保留（不做去重）', () {
      final r = parseLrc('[00:01.00]A\n[00:01.00]B');
      expect(r.length, 2);
      expect(r.map((e) => e.text).toSet(), {'A', 'B'});
      expect(r.every((e) => e.timestamp == const Duration(seconds: 1)), isTrue);
    });

    test('负数时间 [-1:00.00] → 正则不匹配（\\d{2} 限定），返回空', () {
      expect(parseLrc('[-1:00.00]负时间'), isEmpty);
    });

    test('三位分钟 [999:99.999] → 正则不匹配（分钟仅 2 位），返回空', () {
      expect(parseLrc('[999:99.999]超界'), isEmpty);
    });
  });
}

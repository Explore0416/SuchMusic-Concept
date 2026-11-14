import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/update_service.dart';

/// 更新弹窗只应展示**本次版本**的内容。
/// 分发清单的 changelog 是整篇 CHANGELOG，未裁剪时用户会看到全部历史，
/// 这正是用户报的「把整个更新日志塞进弹窗」。
void main() {
  group('extractChangelogSection', () {
    const full = '''
# 更新日志（CHANGELOG）

> 说明文字

---

## [1.4.1] - 2026-11-14

### 修复
- 横屏补齐四个入口
- 歌词渐隐提前

---

## [1.4.0] - 2026-11-09

### 界面重做
- 播放卡加高
''';

    test('只返回指定版本段落，不含其它版本', () {
      final section = extractChangelogSection(full, '1.4.1');
      expect(section, contains('横屏补齐四个入口'));
      expect(section, contains('### 修复'));
      expect(section, isNot(contains('1.4.0')));
      expect(section, isNot(contains('播放卡加高')));
    });

    test('裁掉段落末尾的分隔线', () {
      final section = extractChangelogSection(full, '1.4.1');
      expect(section.endsWith('---'), isFalse);
      expect(section.endsWith('歌词渐隐提前'), isTrue);
    });

    test('兼容不带方括号的标题', () {
      const text = '## 1.2.0 - 2026-10-01\n内容A\n\n## 1.1.0\n内容B';
      expect(extractChangelogSection(text, '1.2.0'), '内容A');
    });

    test('兼容 v 前缀', () {
      const text = '## [v1.3.0]\n内容C\n\n## [1.2.0]\n内容D';
      expect(extractChangelogSection(text, '1.3.0'), '内容C');
    });

    test('版本号不存在时回退到最新一段', () {
      const text = '# 标题\n\n## [2.0.0]\n新内容\n\n## [1.0.0]\n旧内容';
      final section = extractChangelogSection(text, '9.9.9');
      expect(section, '新内容');
    });

    test('整篇没有二级标题时原样返回', () {
      const text = '只有一段普通说明，没有任何版本标题。';
      expect(extractChangelogSection(text, '1.0.0'), text);
    });

    test('空文本返回空串，不会崩', () {
      expect(extractChangelogSection('', '1.0.0'), '');
      expect(extractChangelogSection('   \n  ', '1.0.0'), '');
    });

    test('CRLF 换行同样能解析', () {
      const text = '## [1.0.1]\r\n修复 A\r\n\r\n## [1.0.0]\r\n旧版';
      expect(extractChangelogSection(text, '1.0.1'), '修复 A');
    });
  });

  group('真实 CHANGELOG', () {
    test('1.4.1 段落不包含更早版本标题', () {
      final file = File('assets/CHANGELOG.md');
      expect(file.existsSync(), isTrue);
      final full = file.readAsStringSync();
      final section = extractChangelogSection(full, '1.4.1');
      expect(section, isNotEmpty);
      expect(section, contains('横屏播放页功能缺失'));
      expect(section, isNot(contains('## [1.4.0]')));
      expect(section, isNot(contains('## [1.3.5]')));
    });
  });
}

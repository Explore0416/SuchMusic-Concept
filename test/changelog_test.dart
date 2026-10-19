import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/screens/changelog_page.dart';

void main() {
  group('parseChangelog', () {
    const md = '''# 更新日志（CHANGELOG）

> 版本编号说明：这段在首个版本标题之前，应被忽略。

---

## [1.0.0] - 2026-10-18

> 引用里的**重点**

### 新增
- **第一条**：内容
  - 二级条目
- 第二条

| 原编号 | 新编号 |
| --- | --- |
| 1.1.0 | 0.1.0 |

---
## [0.9.0] - 2026-10-14
- 旧版本条目
''';

    test('按版本切分，忽略文件头说明', () {
      final entries = parseChangelog(md);
      expect(entries.length, 2);
      expect(entries[0].version, '1.0.0');
      expect(entries[0].date, '2026-10-18');
      expect(entries[1].version, '0.9.0');
    });

    test('识别小节 / 引用 / 列表 / 二级列表 / 表格', () {
      final e = parseChangelog(md).first;
      expect(e.blocks.where((b) => b.kind == ChangelogBlockKind.section).length,
          1);
      expect(e.blocks.where((b) => b.kind == ChangelogBlockKind.quote).length, 1);
      final bullets =
          e.blocks.where((b) => b.kind == ChangelogBlockKind.bullet).toList();
      expect(bullets.length, 3);
      expect(bullets[1].level, 2);
      final tables =
          e.blocks.where((b) => b.kind == ChangelogBlockKind.table).toList();
      // 表头 + 一行数据（分隔行被丢弃）
      expect(tables.length, 2);
      expect(tables[1].text, '1.1.0 · 0.1.0');
    });

    test('空字符串不会崩', () {
      expect(parseChangelog(''), isEmpty);
      expect(parseChangelog('\n\n'), isEmpty);
    });

    test('真实 CHANGELOG 能解析出全部版本', () {
      final text = File('CHANGELOG.md').readAsStringSync();
      final entries = parseChangelog(text);
      expect(entries.length, greaterThanOrEqualTo(10));
      expect(entries.first.version, isNotEmpty);
      // 最新版本号必须等于 pubspec 的 version（防止发了版却忘了写日志）
      final pubspec = File('pubspec.yaml').readAsStringSync();
      final m = RegExp(r'^version:\s*([0-9.]+)', multiLine: true).firstMatch(pubspec);
      expect(m, isNotNull);
      expect(entries.first.version, m!.group(1));
      for (final e in entries) {
        expect(e.blocks, isNotEmpty, reason: '版本 ${e.version} 没有内容');
      }
    });
  });

  testWidgets('更新日志页可渲染并默认展开最新版', (tester) async {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final v = RegExp(r'^version:\s*([0-9.]+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1)!;
    await tester.pumpWidget(const MaterialApp(home: ChangelogPage()));
    await tester.pumpAndSettle();
    expect(find.text('更新日志'), findsOneWidget);
    expect(find.text('v$v'), findsOneWidget);
    expect(find.text('当前最新'), findsOneWidget);
  });

  test('assets/CHANGELOG.md 必须与根目录 CHANGELOG.md 完全一致', () {
    final root = File('CHANGELOG.md').readAsStringSync();
    final asset = File('assets/CHANGELOG.md').readAsStringSync();
    expect(asset, root,
        reason: '修改 CHANGELOG.md 后请同步执行：cp CHANGELOG.md assets/CHANGELOG.md');
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 更新日志页面
///
/// 数据源：`assets/CHANGELOG.md`（与仓库根目录 CHANGELOG.md 内容一致，
/// 由 `test/changelog_asset_test.dart` 保证不漂移）。
/// 支持查看**历代所有版本**，最新版默认展开，其余折叠。
class ChangelogPage extends StatefulWidget {
  const ChangelogPage({super.key});

  @override
  State<ChangelogPage> createState() => _ChangelogPageState();
}

class _ChangelogPageState extends State<ChangelogPage> {
  static const Color _themeBlue = Color(0xFF2F84FE);

  List<ChangelogEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  /// 已展开的版本号集合（默认展开最新一版）
  final Set<String> _expanded = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await rootBundle.loadString('assets/CHANGELOG.md');
      final entries = parseChangelog(text);
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        if (entries.isNotEmpty) _expanded.add(entries.first.version);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '更新日志读取失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF2F4F8),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const SizedBox(
                  height: 44,
                  child: Center(
                    child: Text(
                      '更新日志',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333),
                      ),
                    ),
                  ),
                ),
                Expanded(child: _buildBody()),
              ],
            ),
            Positioned(
              left: 4,
              top: 4,
              child: GestureDetector(
                onTap: () => Navigator.pop(context),
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(
                    Icons.arrow_back_ios_new,
                    size: 20,
                    color: Color(0xFF333333),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(
        child: Text('暂无更新记录',
            style: TextStyle(fontSize: 13, color: Color(0xFF999999))),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(15, 8, 15, 28),
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final e = _entries[i];
        final open = _expanded.contains(e.version);
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(17),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(17),
                onTap: () => setState(() {
                  if (open) {
                    _expanded.remove(e.version);
                  } else {
                    _expanded.add(e.version);
                  }
                }),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                  child: Row(
                    children: [
                      Text(
                        'v${e.version}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF333333),
                        ),
                      ),
                      if (i == 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _themeBlue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: const Text(
                            '当前最新',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: _themeBlue,
                            ),
                          ),
                        ),
                      ],
                      const Spacer(),
                      if (e.date.isNotEmpty)
                        Text(
                          e.date,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF999999),
                          ),
                        ),
                      const SizedBox(width: 4),
                      Icon(
                        open
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 20,
                        color: const Color(0xFFCCCCCC),
                      ),
                    ],
                  ),
                ),
              ),
              if (open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Divider(height: 1, color: Color(0xFFF0F0F0)),
                      const SizedBox(height: 10),
                      for (final block in e.blocks) _buildBlock(block),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBlock(ChangelogBlock b) {
    switch (b.kind) {
      case ChangelogBlockKind.section:
        return Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 2),
          child: Text(
            b.text,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF333333),
            ),
          ),
        );
      case ChangelogBlockKind.quote:
        return Container(
          margin: const EdgeInsets.only(top: 4, bottom: 2),
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: const Color(0xFFF7F8FA),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text.rich(
            TextSpan(children: _inline(b.text)),
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: Color(0xFF666666),
            ),
          ),
        );
      case ChangelogBlockKind.bullet:
        return Padding(
          padding: EdgeInsets.only(
            left: b.level > 1 ? 14.0 : 0,
            top: 3,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 7),
                child: Container(
                  width: b.level > 1 ? 4 : 5,
                  height: b.level > 1 ? 4 : 5,
                  decoration: const BoxDecoration(
                    color: Color(0xFFBFBFBF),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(
                child: Text.rich(
                  TextSpan(children: _inline(b.text)),
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: Color(0xFF666666),
                  ),
                ),
              ),
            ],
          ),
        );
      case ChangelogBlockKind.table:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(
            TextSpan(children: _inline(b.text)),
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Color(0xFF777777),
            ),
          ),
        );
      case ChangelogBlockKind.text:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text.rich(
            TextSpan(children: _inline(b.text)),
            style: const TextStyle(
              fontSize: 13,
              height: 1.6,
              color: Color(0xFF666666),
            ),
          ),
        );
    }
  }

  /// 行内标记：**加粗**、`代码`
  static List<TextSpan> _inline(String raw) {
    final spans = <TextSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in re.allMatches(raw)) {
      if (m.start > last) {
        spans.add(TextSpan(text: raw.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
          text: m.group(1),
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF444444),
          ),
        ));
      } else {
        spans.add(TextSpan(
          text: m.group(2),
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: Color(0xFF555555),
          ),
        ));
      }
      last = m.end;
    }
    if (last < raw.length) {
      spans.add(TextSpan(text: raw.substring(last)));
    }
    return spans;
  }
}

/// 更新日志中的一个版本
class ChangelogEntry {
  final String version;
  final String date;
  final List<ChangelogBlock> blocks;

  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.blocks,
  });
}

enum ChangelogBlockKind { section, bullet, quote, text, table }

class ChangelogBlock {
  final ChangelogBlockKind kind;
  final String text;
  final int level;

  const ChangelogBlock({
    required this.kind,
    required this.text,
    this.level = 1,
  });
}

/// 解析 CHANGELOG.md（纯函数，便于单测）
///
/// 约定：每个版本以 `## [x.y.z] - yyyy-MM-dd` 开头；`## ` 之前的说明性文字忽略。
List<ChangelogEntry> parseChangelog(String source) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final header = RegExp(r'^##\s+\[?([0-9][^\]]*?)\]?(?:\s*-\s*(\S+))?\s*$');

  final entries = <ChangelogEntry>[];
  String? version;
  String date = '';
  final blocks = <ChangelogBlock>[];

  void flush() {
    final v = version;
    if (v != null) {
      entries.add(ChangelogEntry(
        version: v,
        date: date,
        blocks: List<ChangelogBlock>.unmodifiable(blocks),
      ));
    }
    blocks.clear();
  }

  for (final raw in lines) {
    final line = raw.trimRight();
    final m = header.firstMatch(line);
    if (m != null) {
      flush();
      version = m.group(1)!.trim();
      date = (m.group(2) ?? '').trim();
      continue;
    }
    // 其它二级标题（如文末「历史版本」附表）：结束当前版本，后续内容不再归属任何版本
    if (line.startsWith('## ')) {
      flush();
      version = null;
      date = '';
      continue;
    }
    if (version == null) continue; // 文件头部说明，跳过
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t == '---') continue;

    if (t.startsWith('### ')) {
      blocks.add(ChangelogBlock(
        kind: ChangelogBlockKind.section,
        text: t.substring(4).trim(),
      ));
      continue;
    }
    if (t.startsWith('> ')) {
      blocks.add(ChangelogBlock(
        kind: ChangelogBlockKind.quote,
        text: t.substring(2).trim(),
      ));
      continue;
    }
    if (t.startsWith('|')) {
      // 表格分隔行（| --- | --- |）不展示
      if (RegExp(r'^\|[\s\-:|]+\|?$').hasMatch(t)) continue;
      final cells = t
          .split('|')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (cells.isEmpty) continue;
      blocks.add(ChangelogBlock(
        kind: ChangelogBlockKind.table,
        text: cells.join(' · '),
      ));
      continue;
    }
    if (t.startsWith('- ') || t.startsWith('* ')) {
      final indent = line.length - line.trimLeft().length;
      blocks.add(ChangelogBlock(
        kind: ChangelogBlockKind.bullet,
        text: t.substring(2).trim(),
        level: indent >= 2 ? 2 : 1,
      ));
      continue;
    }
    blocks.add(ChangelogBlock(kind: ChangelogBlockKind.text, text: t));
  }
  flush();
  return entries;
}

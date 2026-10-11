/// LRC 歌词解析（从 `AudioPlayerService._parseLrc` 提取，行为保持不变）。
///
/// 提取为**顶层函数**以便被测试直接覆盖（Dart 无反射，私有方法不可单测）。
library;

/// 一行歌词：时间戳 + 文本。
class LyricLine {
  final Duration timestamp;
  final String text;

  const LyricLine({required this.timestamp, required this.text});
}

/// 解析 LRC 文本为按时间升序排列的歌词行列表。
///
/// 规则（与原 `_parseLrc` 逐字节一致）：
/// - 匹配 `[mm:ss.xx]` / `[mm:ss.xxx]` 时间标签，同一行多标签只取首个；
/// - 两位毫秒补齐为三位（`xx` → `xx0`）；
/// - 文本 trim 后为空的行走不进入结果（含纯时间戳行）；
/// - 结果按时间戳升序排序。
List<LyricLine> parseLrc(String lrcText) {
  final lines = lrcText.split('\n');
  final result = <LyricLine>[];
  final regExp = RegExp(r'\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)');

  for (final line in lines) {
    final match = regExp.firstMatch(line.trim());
    if (match != null) {
      final minutes = int.parse(match.group(1)!);
      final seconds = int.parse(match.group(2)!);
      var millisStr = match.group(3)!;
      if (millisStr.length == 2) millisStr += '0';
      final millis = int.parse(millisStr);
      final text = match.group(4)?.trim() ?? '';
      if (text.isNotEmpty) {
        result.add(LyricLine(
          timestamp: Duration(
              minutes: minutes, seconds: seconds, milliseconds: millis),
          text: text,
        ));
      }
    }
  }

  result.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return result;
}

/// SuchMusic 手环通信 · 分片编解码（header → data → end）+ CRC32（纯逻辑）。
///
/// 严格遵循 `docs/ARCH-手环通信.md` §3.8：
/// - 单包字节上限 [BandChunkCodec.chunkMaxBytes] = 900；
/// - 组装缓存上限 [BandChunkCodec.assembleMaxBytes] = 8192（超限即 `E_TOOLARGE`）；
/// - 整包 `crc32`（IEEE，与 zlib / Java `CRC32` 同款）、文本走 `txt`、二进制走 `b64`。
library;

import 'dart:convert';

/// 组装 / 校验失败的异常（携带协议错误码）。
class BandChunkException implements Exception {
  const BandChunkException(this.code, this.message, {this.missingSeqs = const []});

  final String code;
  final String message;

  /// 缺失分片序号（`E_CRC` 场景下用于 `xfer.nack`）。
  final List<int> missingSeqs;

  @override
  String toString() => 'BandChunkException($code: $message)';
}

/// 分片编解码（与 Kotlin 侧 `BandChunkCodec` 同构）。
class BandChunkCodec {
  BandChunkCodec._();

  /// 单包字节上限（保守值，真实上限待真机验证 V2）。
  static const int chunkMaxBytes = 900;

  /// 组装缓存上限。
  static const int assembleMaxBytes = 8192;

  static final List<int> _table = _buildTable();

  static List<int> _buildTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
      }
      table[i] = c;
    }
    return table;
  }

  /// IEEE CRC32（无符号 32 位）。
  static int crc32(List<int> data) {
    var crc = 0xFFFFFFFF;
    for (final byte in data) {
      crc = _table[(crc ^ byte) & 0xFF] ^ (crc >> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  /// CRC32 的小写 8 位十六进制表示（与 Kotlin `crc32Hex` 一致）。
  static String crc32Hex(List<int> data) =>
      crc32(data).toRadixString(16).padLeft(8, '0');

  /// 把一个完整文本切成帧列表 `[header, data…, end]`（每帧为 `payload` 对象）。
  ///
  /// 按 UTF-8 字节数切分，**不切断多字节字符**（按代理对边界推进）。
  static List<Map<String, dynamic>> splitText({
    required String tid,
    required String kind,
    required String text,
    Map<String, dynamic>? meta,
  }) {
    final allBytes = utf8.encode(text);
    final crcHex = crc32Hex(allBytes);

    final dataFrames = <Map<String, dynamic>>[];
    final buf = StringBuffer();
    var bufBytes = 0;
    var seq = 0;
    var i = 0;
    while (i < text.length) {
      final unit = text.codeUnitAt(i);
      // 高代理位且后面还有低位 → 视为一个 2 code-unit 字符，避免拆散 emoji 等
      final charLen =
          (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length) ? 2 : 1;
      final ch = text.substring(i, i + charLen);
      final chBytes = utf8.encode(ch).length;
      if (bufBytes + chBytes > chunkMaxBytes && buf.isNotEmpty) {
        dataFrames.add(_dataFrame(tid, seq++, buf.toString()));
        buf.clear();
        bufBytes = 0;
      }
      buf.write(ch);
      bufBytes += chBytes;
      i += charLen;
    }
    if (buf.isNotEmpty || dataFrames.isEmpty) {
      // 空文本也产出 1 个（空）分片，保证 total >= 1、组装语义稳定
      dataFrames.add(_dataFrame(tid, seq++, buf.toString()));
    }

    final total = dataFrames.length;
    return <Map<String, dynamic>>[
      <String, dynamic>{
        'tid': tid,
        'phase': 'header',
        'kind': kind,
        'total': total,
        'bytes': allBytes.length,
        'crc32': crcHex,
        if (meta != null && meta.isNotEmpty) 'meta': meta,
      },
      ...dataFrames,
      <String, dynamic>{'tid': tid, 'phase': 'end', 'total': total, 'crc32': crcHex},
    ];
  }

  static Map<String, dynamic> _dataFrame(String tid, int seq, String chunk) =>
      <String, dynamic>{
        'tid': tid,
        'phase': 'data',
        'seq': seq,
        'txt': chunk,
      };
}

/// 分片组装器：消费 [BandChunkCodec.splitText] 产出的帧，`end` 时校验。
class BandChunkAssembler {
  BandChunkAssembler({this.maxBytes = BandChunkCodec.assembleMaxBytes});

  /// 组装上限（超过即 `E_TOOLARGE`）。
  final int maxBytes;

  String? tid;
  String? kind;
  int? total;
  int expectedBytes = 0;
  String? expectedCrc;

  final Map<int, String> _parts = <int, String>{};
  bool _overflow = false;
  int _currentBytes = 0;

  /// 是否超过组装上限。
  bool get overflow => _overflow;

  /// 是否已收齐全部分片。
  bool get isComplete {
    final n = total;
    if (n == null || n < 0) return false;
    for (var i = 0; i < n; i++) {
      if (!_parts.containsKey(i)) return false;
    }
    return true;
  }

  /// 缺失分片序号（用于 `xfer.nack`）。
  List<int> get missingSeqs {
    final n = total ?? 0;
    if (n <= 0) return const [];
    final miss = <int>[];
    for (var i = 0; i < n; i++) {
      if (!_parts.containsKey(i)) miss.add(i);
    }
    return miss;
  }

  /// 处理 header 帧。
  void onHeader(Map<String, dynamic> payload) {
    tid = payload['tid'] as String?;
    kind = payload['kind'] as String?;
    total = (payload['total'] as num?)?.toInt();
    expectedBytes = (payload['bytes'] as num?)?.toInt() ?? 0;
    expectedCrc = payload['crc32'] as String?;
    _parts.clear();
    _currentBytes = 0;
    _overflow = expectedBytes > maxBytes;
  }

  /// 处理 data 帧（`txt` 或 `b64` 二选一）。
  void onData(Map<String, dynamic> payload) {
    final seq = (payload['seq'] as num?)?.toInt();
    if (seq == null || seq < 0) return;
    final txt = payload['txt'] as String?;
    final String chunk;
    if (txt != null) {
      chunk = txt;
    } else {
      final b64 = payload['b64'] as String?;
      chunk = b64 == null ? '' : utf8.decode(base64.decode(b64));
    }
    if (_parts.containsKey(seq)) {
      _currentBytes -= utf8.encode(_parts[seq]!).length;
    }
    _parts[seq] = chunk;
    _currentBytes += utf8.encode(chunk).length;
    if (_currentBytes > maxBytes) _overflow = true;
  }

  /// 处理 end 帧：校验 `count == total && crc32 == crc32`，返回组装后的文本。
  ///
  /// 失败时抛 [BandChunkException]（`E_TOOLARGE` / `E_CRC`）。
  String onEnd(Map<String, dynamic> payload) {
    if (_overflow) {
      throw const BandChunkException(
          'E_TOOLARGE', 'assembled payload exceeds assembleMaxBytes');
    }
    final n = total ?? -1;
    if (n < 0) {
      throw const BandChunkException('E_CRC', 'missing header');
    }
    final miss = missingSeqs;
    if (miss.isNotEmpty) {
      throw BandChunkException('E_CRC', 'missing chunks: $miss',
          missingSeqs: miss);
    }
    final sb = StringBuffer();
    for (var i = 0; i < n; i++) {
      sb.write(_parts[i]);
    }
    final text = sb.toString();
    final bytes = utf8.encode(text);
    final actual = BandChunkCodec.crc32Hex(bytes);
    final expect = (payload['crc32'] as String?) ?? expectedCrc;
    if (expect != null && actual != expect) {
      throw BandChunkException(
          'E_CRC', 'crc mismatch: calc=$actual expect=$expect');
    }
    return text;
  }

  /// 便捷入口：按 `phase` 分发单帧；`end` 时返回组装结果，否则返回 null。
  String? onFrame(Map<String, dynamic> payload) {
    final phase = payload['phase'];
    switch (phase) {
      case 'header':
        onHeader(payload);
        return null;
      case 'data':
        onData(payload);
        return null;
      case 'end':
        return onEnd(payload);
      default:
        return null;
    }
  }

  /// 复位，便于复用。
  void reset() {
    tid = null;
    kind = null;
    total = null;
    expectedBytes = 0;
    expectedCrc = null;
    _parts.clear();
    _currentBytes = 0;
    _overflow = false;
  }
}

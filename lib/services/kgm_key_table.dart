import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'kgm_tables.dart';

/// 酷狗新版 KGM 的 16 字节块密钥表。
///
/// 旧版（KGM v2）是**逐字节**掩码，用 `kgm_tables.dart` 里三张 272 字节表；
/// 新版改成**按 16 字节块异或**，每个块还要查一张巨大的 `pub` 表。
/// 社区实现公开的原始表为 70 MB（覆盖约 1.1 GB 音频），
/// 这里只取前 4 MiB（gzip 674 KB），可覆盖 64 MB 以内的音频文件。
class KgmKeyTable {
  KgmKeyTable._();

  static Uint8List? _cache;

  /// 读取内置密钥表（首次解压，之后走内存缓存）。
  static Future<Uint8List> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final data = await rootBundle.load('assets/kugou_key.bin.gz');
    final raw = Uint8List.fromList(gzip.decode(data.buffer.asUint8List()));
    _cache = raw;
    return raw;
  }

  /// 单测注入（跳过 asset 加载）。
  static void setForTest(Uint8List table) => _cache = table;

  static void reset() => _cache = null;
}

/// 新版 KGM 解密（16 字节块）。
///
/// 逐块处理：
/// 1. `pk = key[i % 17] ^ maskV2[i % 272]` —— 272 字节派生密钥（17 组 × 16 字节）；
/// 2. 第 `r` 块每字节异或 `pk[(r % 17) * 16 + j] ^ pub[r]`；
/// 3. 结果再做一次 `x ^ ((x & 0x0F) << 4)`。
///
/// [basePos] 是 [data] 在**整段音频**中的起始偏移，必须是 16 的倍数
/// （分块解密时每块 1 MiB，满足该条件）。
Uint8List transformChunkV3(
  Uint8List data,
  Uint8List key,
  int basePos,
  Uint8List pub,
) {
  final pk = Uint8List(272);
  for (var i = 0; i < 272; i++) {
    pk[i] = key[i % 17] ^ maskV2PreDef[i % 272];
  }

  final n = data.length;
  var i = 0;
  var block = basePos >> 4;
  var offsetInBlock = basePos & 15;

  while (i < n && block < pub.length) {
    final remain = n - i;
    final room = 16 - offsetInBlock;
    final step = room < remain ? room : remain;
    final p = (block % 17) * 16 + offsetInBlock;
    final b = pub[block];
    for (var j = 0; j < step; j++) {
      final x = (data[i + j] ^ pk[p + j] ^ b) & 0xFF;
      data[i + j] = x ^ ((x & 0x0F) << 4);
    }
    i += step;
    block++;
    offsetInBlock = 0;
  }
  return data;
}

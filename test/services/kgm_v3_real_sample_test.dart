import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/kgm_key_table.dart';

/// 用酷狗真实文件做端到端验证。
///
/// 样本来自社区公开的测试集：
/// - `test_kugou_kgm.dat`：加密的 KGM 文件（标准魔数 + 头长 0x400）；
/// - `test_kugou_kgm_right.dat`：官方参考实现解出的明文（ID3/MP3）。
///
/// 只有「解出的字节与参考输出完全一致」才算通过——不做任何模糊判定。
void main() {
  final fixtures = Directory('test/fixtures');

  Uint8List read(String name) =>
      Uint8List.fromList(File('${fixtures.path}/$name').readAsBytesSync());

  late Uint8List pub;
  late Uint8List enc;
  late Uint8List right;

  setUpAll(() {
    pub = Uint8List.fromList(
      gzip.decode(File('assets/kugou_key.bin.gz').readAsBytesSync()),
    );
    enc = read('test_kugou_kgm.dat');
    right = read('test_kugou_kgm_right.dat');
  });

  group('新版 KGM（16 字节块 + pub 表）', () {
    test('真实样本解出的字节与官方参考输出完全一致', () {
      final hlen =
          ByteData.sublistView(enc, 0x10, 0x14).getUint32(0, Endian.little);
      expect(hlen, 0x400);

      final key = Uint8List(17);
      key.setRange(0, 16, enc, 0x1C);
      key[16] = 0;

      final audio = Uint8List.fromList(enc.sublist(hlen));
      final out = transformChunkV3(audio, key, 0, pub);

      expect(out.length, right.length);
      expect(out, equals(right), reason: '解密结果必须逐字节等于参考输出');
      // 明文是 ID3 容器
      expect(out.sublist(0, 3), equals([0x49, 0x44, 0x33]));
    });

    test('分块解密与整块解密结果一致（basePos 参与块序号计算）', () {
      final hlen =
          ByteData.sublistView(enc, 0x10, 0x14).getUint32(0, Endian.little);
      final key = Uint8List(17);
      key.setRange(0, 16, enc, 0x1C);
      key[16] = 0;
      final audio = Uint8List.fromList(enc.sublist(hlen));

      final whole = transformChunkV3(Uint8List.fromList(audio), key, 0, pub);

      // 按 1 KiB 切块：1 KiB 是 16 的整数倍，符合解码器的分块前提
      final chunked = Uint8List(audio.length);
      var offset = 0;
      const step = 1024;
      while (offset < audio.length) {
        final end =
            offset + step > audio.length ? audio.length : offset + step;
        final piece = Uint8List.fromList(audio.sublist(offset, end));
        final part = transformChunkV3(piece, key, offset, pub);
        chunked.setRange(offset, end, part);
        offset = end;
      }

      expect(chunked, equals(whole));
    });

    test('密钥表足以覆盖样本（块索引不越界）', () {
      expect(pub.length, greaterThanOrEqualTo((enc.length - 0x400) ~/ 16));
    });

    test('错密钥解不出 ID3（防止误判为成功）', () {
      final hlen =
          ByteData.sublistView(enc, 0x10, 0x14).getUint32(0, Endian.little);
      final wrong = Uint8List(17)..fillRange(0, 17, 0x5A);
      final out = transformChunkV3(
        Uint8List.fromList(enc.sublist(hlen)),
        wrong,
        0,
        pub,
      );
      expect(out.sublist(0, 3), isNot(equals([0x49, 0x44, 0x33])));
    });
  });
}

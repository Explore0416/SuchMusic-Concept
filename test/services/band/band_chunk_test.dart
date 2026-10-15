// 手环分片 / CRC32 单测（ARCH §3.8）：切分·组装往返、CRC 校验、缺片、超限。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/band/band_chunk.dart';

void main() {
  group('CRC32', () {
    test('标准向量：utf8("123456789") = 0xCBF43926', () {
      final bytes = utf8.encode('123456789');
      expect(BandChunkCodec.crc32(bytes), 0xCBF43926);
      expect(BandChunkCodec.crc32Hex(bytes), 'cbf43926');
    });

    test('空输入 crc32 = 0', () {
      expect(BandChunkCodec.crc32(const <int>[]), 0);
      expect(BandChunkCodec.crc32Hex(const <int>[]), '00000000');
    });
  });

  group('split / assemble 往返', () {
    test('短文本：单分片内联', () {
      final frames = BandChunkCodec.splitText(
          tid: 't-1', kind: 'lyric_window', text: '{"a":1}');
      expect(frames.first['phase'], 'header');
      expect(frames.last['phase'], 'end');
      expect(frames.first['total'], 1);
      expect(frames.length, 3); // header + 1 data + end
    });

    test('长中文文本跨多分片：组装后与原文本逐字节相等', () {
      // 约 4.8KB：既跨多个分片（>900B），又在 8KB 组装上限内
      final text = List.generate(150, (i) => '第 $i 行抒情歌词内容测试').join('\n');
      final frames = BandChunkCodec.splitText(
          tid: 't-2', kind: 'lyric_window', text: text, meta: {'start': 5});
      final dataFrames = frames.where((f) => f['phase'] == 'data').toList();
      expect(dataFrames.length, greaterThan(1), reason: '应被切分为多个分片');
      // 每个 data 分片的 UTF-8 字节数不超过上限
      for (final f in dataFrames) {
        expect(utf8.encode(f['txt'] as String).length,
            lessThanOrEqualTo(BandChunkCodec.chunkMaxBytes));
      }

      final assembler = BandChunkAssembler();
      String? out;
      for (final f in frames) {
        out = assembler.onFrame(f);
      }
      expect(out, text);
    });

    test('emoji（代理对）不被拆散', () {
      final text = '😀' * 300; // 每个 4 字节
      final frames = BandChunkCodec.splitText(
          tid: 't-3', kind: 'raw', text: text);
      final assembler = BandChunkAssembler();
      String? out;
      for (final f in frames) {
        out = assembler.onFrame(f);
      }
      expect(out, text);
    });
  });

  group('组装校验', () {
    test('缺片 → E_CRC 且 missingSeqs 正确', () {
      final text = List.generate(200, (i) => '内容$i').join('，');
      final frames = BandChunkCodec.splitText(
          tid: 't-4', kind: 'raw', text: text);
      final dataIndex = frames.indexWhere((f) => f['phase'] == 'data');
      final removedSeq = frames[dataIndex]['seq'] as int;
      frames.removeAt(dataIndex); // 丢掉首个 data 分片

      final assembler = BandChunkAssembler();
      late BandChunkException err;
      try {
        for (final f in frames) {
          assembler.onFrame(f);
        }
        fail('应因缺片抛异常');
      } on BandChunkException catch (e) {
        err = e;
      }
      expect(err.code, 'E_CRC');
      expect(err.missingSeqs, contains(removedSeq));
    });

    test('分片被篡改 → CRC 不匹配 E_CRC', () {
      final text = List.generate(200, (i) => '内容$i').join('，');
      final frames = BandChunkCodec.splitText(
          tid: 't-5', kind: 'raw', text: text);
      // 篡改第一个 data 分片内容
      final idx = frames.indexWhere((f) => f['phase'] == 'data');
      frames[idx] = Map<String, dynamic>.from(frames[idx])..['txt'] = '被篡改的内容';

      final assembler = BandChunkAssembler();
      expect(
        () {
          String? out;
          for (final f in frames) {
            out = assembler.onFrame(f);
          }
          return out;
        },
        throwsA(isA<BandChunkException>()
            .having((e) => e.code, 'code', 'E_CRC')),
      );
    });

    test('超过组装上限 → E_TOOLARGE', () {
      final text = 'a' * (BandChunkCodec.assembleMaxBytes + 100);
      final frames = BandChunkCodec.splitText(
          tid: 't-6', kind: 'raw', text: text);
      final assembler = BandChunkAssembler();
      expect(
        () {
          String? out;
          for (final f in frames) {
            out = assembler.onFrame(f);
          }
          return out;
        },
        throwsA(isA<BandChunkException>()
            .having((e) => e.code, 'code', 'E_TOOLARGE')),
      );
    });

    test('b64 分片可正确解码组装', () {
      final assembler = BandChunkAssembler();
      assembler.onHeader({
        'tid': 't-7',
        'phase': 'header',
        'total': 1,
        'bytes': 3,
        'crc32': BandChunkCodec.crc32Hex(utf8.encode('abc')),
      });
      assembler.onData({
        'tid': 't-7',
        'phase': 'data',
        'seq': 0,
        'b64': base64.encode(utf8.encode('abc')),
      });
      final out = assembler.onEnd({'tid': 't-7', 'phase': 'end', 'total': 1});
      expect(out, 'abc');
    });
  });
}

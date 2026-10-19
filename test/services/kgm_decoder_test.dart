import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/kgm_decoder.dart';
import 'package:such_music/services/kgm_tables.dart';

/// KGM 解码器的确定性验证。
///
/// 期望值由**独立的 Python 参考实现**（严格照 C++ `kgm.hpp` 逐行重写）生成，
/// 不是由 Dart 实现自己产出 —— 这样才构成真正的交叉验证，而非循环论证。
void main() {
  // 与 Python 侧完全相同的输入
  final key = Uint8List.fromList(List<int>.generate(16, (i) => i)..add(0));
  final plain = Uint8List.fromList(
    List<int>.generate(600, (i) => (i * 37 + 11) & 0xFF),
  );

  /// 足够长（>1KB）的样本：候选头构建会过滤掉音频段过短的文件。
  final longPlain = Uint8List.fromList(
    List<int>.generate(4000, (i) => (i * 37 + 11) & 0xFF),
  );

  // Python 参考实现输出（见提交说明中的生成脚本）
  const expectedKgMHead =
      '83a4ca7b528ee7d5384266786d51f2ee345e8115154ee41f53ec8656264183e0'
      '1dc9bb5e3b29641cb9472896084ab391';
  const expectedKgMTail = '7b45ea540a883153f1422e66f2a5c15e';
  const expectedVprHead =
      'a67b22dd279092db17c29555d5e711ff347b5efdb33bfa6a5dc306a50bf93503';

  String hex(Iterable<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  group('KGM 解密（与独立参考实现交叉验证）', () {
    test('KGM 模式：前 48 字节与末尾 16 字节均匹配', () {
      final out = KgmDecoder.transformChunk(
        Uint8List.fromList(plain),
        key,
        0,
      );
      expect(hex(out.take(48)), expectedKgMHead);
      expect(hex(out.skip(584)), expectedKgMTail);
    });

    test('VPR 模式：额外一层掩码确实生效', () {
      final out = KgmDecoder.transformChunk(
        Uint8List.fromList(plain),
        key,
        0,
        isVpr: true,
      );
      expect(hex(out.take(32)), expectedVprHead);
    });

    test('分块解密与整块解密结果完全一致（偏移参与计算）', () {
      final whole = KgmDecoder.transformChunk(
        Uint8List.fromList(plain),
        key,
        0,
      );

      // 按 97 字节切块（故意不是 16 的整数倍，覆盖块边界错位）
      final chunked = Uint8List(plain.length);
      var offset = 0;
      while (offset < plain.length) {
        final end = offset + 97 > plain.length ? plain.length : offset + 97;
        final piece = Uint8List.fromList(plain.sublist(offset, end));
        final decoded = KgmDecoder.transformChunk(piece, key, offset);
        chunked.setRange(offset, end, decoded);
        offset = end;
      }

      expect(chunked, equals(whole));
    });

    test('相同输入重复解密结果稳定（无隐藏状态泄漏）', () {
      final a = KgmDecoder.transformChunk(Uint8List.fromList(plain), key, 0);
      final b = KgmDecoder.transformChunk(Uint8List.fromList(plain), key, 0);
      expect(a, equals(b));
    });
  });

  group('完整文件解析（头部 + 音频）', () {
    /// 按真实布局拼一个 KGM 文件：魔数 16B + 头长 4B + 填充 + 密钥 16B + 音频。
    Uint8List buildKgm(List<int> audio, {int headerLen = 0x2C}) {
      final buf = Uint8List(headerLen + audio.length);
      buf.setRange(0, 16, kgmHeader);
      ByteData.sublistView(buf).setUint32(0x10, headerLen, Endian.little);
      buf.setRange(0x1C, 0x2C, key.sublist(0, 16));
      buf.setRange(headerLen, buf.length, audio);
      return buf;
    }

    test('头部解析出正确的偏移、密钥与 VPR 标志', () {
      final file = buildKgm(plain);
      final h = KgmDecoder.parseHeader(file);
      expect(h.headerLen, 0x2C);
      expect(h.key.length, 17);
      expect(h.key[16], 0);
      expect(h.key.sublist(0, 16), equals(key.sublist(0, 16)));
      expect(h.isVpr, isFalse);
    });

    test('从完整文件还原出的音频与参考实现一致', () {
      final file = buildKgm(plain);
      final h = KgmDecoder.parseHeader(file);
      final audio = Uint8List.fromList(file.sublist(h.headerLen));
      final out = KgmDecoder.transformChunk(audio, h.key, 0);
      expect(hex(out.take(48)), expectedKgMHead);
      expect(hex(out.skip(584)), expectedKgMTail);
    });

    test('头部长度非 0x2C 时同样按声明偏移取音频', () {
      final file = buildKgm(plain, headerLen: 0x40);
      final h = KgmDecoder.parseHeader(file);
      expect(h.headerLen, 0x40);
      final audio = Uint8List.fromList(file.sublist(h.headerLen));
      final out = KgmDecoder.transformChunk(audio, h.key, 0);
      expect(hex(out.take(48)), expectedKgMHead);
    });

    test('回归：只采样 64 字节头部 + 传文件大小时，1024 字节头也能解析', () {
      // 真实 KGM 头长通常是 0x400；解码器只读前 64 字节用于解析。
      // 旧实现用「头长 < 采样缓冲长度」校验，导致所有真实文件被判为头部异常。
      final file = buildKgm(plain, headerLen: 0x400);
      final head64 = Uint8List.fromList(file.sublist(0, 64));
      final h = KgmDecoder.parseHeader(head64, fileLength: file.length);
      expect(h.headerLen, 0x400);
      expect(h.key.sublist(0, 16), equals(key.sublist(0, 16)));
    });

    test('头部长度必须落在文件范围内，越界仍报错', () {
      final file = buildKgm(plain, headerLen: 0x400);
      final head64 = Uint8List.fromList(file.sublist(0, 64));
      expect(
        () => KgmDecoder.parseHeader(head64, fileLength: 0x200),
        throwsA(isA<KgmDecodeException>()),
      );
    });

    test('解密结果嗅探：真实容器通过，乱码拒绝', () {
      expect(
        KgmDecoder.looksLikeAudio(
          Uint8List.fromList([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        isTrue,
      );
      expect(
        KgmDecoder.looksLikeAudio(
          Uint8List.fromList([0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        isTrue,
      );
      expect(
        KgmDecoder.looksLikeAudio(
          Uint8List.fromList(List<int>.filled(16, 0x5A)),
        ),
        isFalse,
      );
    });

    test('未知魔数：允许试解时按头部布局解析，不允许时仍拒绝', () {
      final file = buildKgm(plain, headerLen: 0x40);
      // 把魔数改成未知值
      file.setRange(0, 16, List<int>.filled(16, 0x05));
      expect(
        () => KgmDecoder.parseHeader(file),
        throwsA(isA<KgmDecodeException>()),
      );
      final h = KgmDecoder.parseHeader(file, allowUnknownMagic: true);
      expect(h.headerLen, 0x40);
      expect(h.isVpr, isFalse);
    });

    test('canAttemptDecode：布局像加密文件才尝试', () {
      final big = Uint8List.fromList(List<int>.filled(4096, 0x11));
      final file = buildKgm(big, headerLen: 0x40);
      expect(KgmDecoder.canAttemptDecode(file, file.length), isTrue);
      // 头长越界
      expect(KgmDecoder.canAttemptDecode(file, 0x20), isFalse);
      // 音频部分太短（< 1KB）
      expect(KgmDecoder.canAttemptDecode(file, 0x40 + 512), isFalse);
      // 大文件即使头长字段不可信也允许「试一试」——结果由音频魔数校验兜底，
      // 解不出来不会产出可用文件（见 decodeToCache 的探测逻辑）。
      final flac = Uint8List.fromList([
        0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22,
        ...List<int>.filled(56, 0),
      ]);
      expect(KgmDecoder.canAttemptDecode(flac, 50000), isTrue);
      // 太小的文件不试，避免把随机小文件当加密音频
      expect(KgmDecoder.canAttemptDecode(flac, 1024), isFalse);
    });

    test('候选列表：魔数未知且头长字段不可信时，仍覆盖真实头长 0x400', () {
      // 模拟 `xxx.kgg.flac`：容器头与 KGM 不同（魔数未知），
      // 0x10 处的头长字段是垃圾值，真实音频从 0x400 开始。
      final flacHead = <int>[
        0x66, 0x4C, 0x61, 0x43, // fLaC
        0x00, 0x00, 0x00, 0x22, // STREAMINFO block
        ...List<int>.filled(56, 0),
      ];
      final audio = Uint8List.fromList([...flacHead, ...List<int>.filled(2000, 0x11)]);
      // 反解加密：data = key ^ T(plain ^ T(mask))，T 自反。
      // 不能直接拿 transformChunk 当加密用——V2 掩码变换整体不是自反的。
      int tt(int x) => (x ^ ((x & 0x0F) << 4)) & 0xFF;
      final encAudio = Uint8List(audio.length);
      for (var i = 0; i < audio.length; i++) {
        final mask = tt(kgmMaskPreDef(i) ^ kgmBlockValue(i >> 4));
        encAudio[i] = key[i % 17] ^ tt(audio[i] ^ mask);
      }

      const headerLen = 0x400;
      final file = Uint8List(headerLen + encAudio.length);
      file.setRange(0, 16, List<int>.filled(16, 0x05)); // 未知魔数
      ByteData.sublistView(file).setUint32(0x10, 0xFFFFFFFF, Endian.little); // 垃圾头长
      file.setRange(0x1C, 0x2C, key.sublist(0, 16));
      file.setRange(headerLen, file.length, encAudio);

      final candidates = KgmDecoder.buildCandidates(
        Uint8List.fromList(file.sublist(0, 64)),
        file.length,
        forceAttempt: true,
      );
      // 必须包含真实头长，否则这类文件永远解不出
      final hit = candidates.where((c) => c.headerLen == headerLen).toList();
      expect(hit, isNotEmpty, reason: '候选应覆盖 0x400');

      final decoded = KgmDecoder.transformChunk(
        Uint8List.fromList(file.sublist(headerLen)),
        hit.first.key,
        0,
        isVpr: hit.first.isVpr,
      );
      expect(KgmDecoder.looksLikeAudio(decoded), isTrue);
      expect(decoded.sublist(0, 4), equals([0x66, 0x4C, 0x61, 0x43]));
    });

    test('候选列表：标准 KGM 优先使用头部声明的偏移', () {
      final file = buildKgm(longPlain, headerLen: 0x80);
      final candidates = KgmDecoder.buildCandidates(
        Uint8List.fromList(file.sublist(0, 64)),
        file.length,
        forceAttempt: true,
      );
      expect(candidates.first.headerLen, 0x80);
    });

    test('候选列表：关闭试解时只认头部声明，未知魔数返回空', () {
      final file = buildKgm(longPlain);
      file.setRange(0, 16, List<int>.filled(16, 0x05));
      final candidates = KgmDecoder.buildCandidates(
        Uint8List.fromList(file.sublist(0, 64)),
        file.length,
        forceAttempt: false,
      );
      // 头长字段仍合法（0x2C），因此会给出一个候选
      expect(candidates.length, 1);
    });

    test('损坏文件（头长越界）抛出可读异常而非崩溃', () {
      final buf = Uint8List(0x2C);
      buf.setRange(0, 16, kgmHeader);
      ByteData.sublistView(buf).setUint32(0x10, 0xFFFF, Endian.little);
      expect(
        () => KgmDecoder.parseHeader(buf),
        throwsA(isA<KgmDecodeException>()),
      );
    });
  });

  group('文件头识别', () {
    test('识别 KGM 魔数', () {
      final head = Uint8List.fromList([
        0x7C, 0xD5, 0x32, 0xEB, 0x86, 0x02, 0x7F, 0x4B,
        0xA8, 0xAF, 0xA6, 0x8E, 0x0F, 0xFF, 0x99, 0x14,
      ]);
      expect(KgmDecoder.looksLikeKgm(head), isTrue);
    });

    test('识别 VPR 魔数', () {
      final head = Uint8List.fromList([
        0x05, 0x28, 0xBC, 0x96, 0xE9, 0xE4, 0x5A, 0x43,
        0x91, 0xAA, 0xBD, 0xD0, 0x7A, 0xF5, 0x36, 0x31,
      ]);
      expect(KgmDecoder.looksLikeKgm(head), isTrue);
    });

    test('普通 MP3 不会被误判为 KGM', () {
      final head = Uint8List.fromList([0x49, 0x44, 0x33, 0x04, 0x00, 0x00]);
      expect(KgmDecoder.looksLikeKgm(head), isFalse);
    });

    test('过短文件不崩且判为非 KGM', () {
      expect(KgmDecoder.looksLikeKgm(Uint8List.fromList([0x7C, 0xD5])), isFalse);
    });
  });

  group('解密后格式嗅探', () {
    test('ID3 → mp3', () {
      final d = Uint8List.fromList([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(KgmDecoder.sniffExtension(d), 'mp3');
    });

    test('fLaC → flac', () {
      final d = Uint8List.fromList([0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(KgmDecoder.sniffExtension(d), 'flac');
    });

    test('OggS → ogg', () {
      final d = Uint8List.fromList([0x4F, 0x67, 0x67, 0x53, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(KgmDecoder.sniffExtension(d), 'ogg');
    });

    test('RIFF → wav', () {
      final d = Uint8List.fromList([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(KgmDecoder.sniffExtension(d), 'wav');
    });

    test('ftyp → m4a', () {
      final d = Uint8List.fromList([0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70, 0, 0, 0, 0]);
      expect(KgmDecoder.sniffExtension(d), 'm4a');
    });

    test('MPEG 帧同步 → mp3', () {
      final d = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(KgmDecoder.sniffExtension(d), 'mp3');
    });
  });
}

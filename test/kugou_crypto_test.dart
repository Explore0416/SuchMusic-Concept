// 酷狗加解密黄金向量（对齐 KuGouMusicApi util/crypto.js 的 Node 端输出）。
//
// 向量来源：node 脚本用固定输入生成，Dart 实现必须逐字节一致，
// 否则 register_dev 的 body/p 无法被服务端解密 → 拿不到 dfid → 取直链失败。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sources/kugou_config.dart';
import 'package:such_music/services/sources/kugou_crypto.dart';

void main() {
  group('KugouCrypto', () {
    test('md5Hex 黄金值', () {
      expect(KugouCrypto.md5Hex('abc123'),
          'e99a18c428cb38d5f260853678922e03');
    });

    test('AES-CBC/PKCS7 黄金向量（key=abc123, 明文 {"a":1}）', () {
      final md5key = KugouCrypto.md5Hex('abc123');
      final encKey = Uint8List.fromList(utf8.encode(md5key.substring(0, 16)));
      final iv = Uint8List.fromList(utf8.encode(md5key.substring(16, 32)));
      final out = KugouCrypto.aesCbcEncrypt(
          Uint8List.fromList(utf8.encode('{"a":1}')), encKey, iv);
      expect(base64.encode(out), 'yywIyMHjBI3COREyEfp/JQ==');
    });

    test('AES 解密可还原', () {
      final md5key = KugouCrypto.md5Hex('abc123');
      final encKey = Uint8List.fromList(utf8.encode(md5key.substring(0, 16)));
      final iv = Uint8List.fromList(utf8.encode(md5key.substring(16, 32)));
      final dec = KugouCrypto.aesCbcDecrypt(
          base64.decode('yywIyMHjBI3COREyEfp/JQ=='), encKey, iv);
      expect(utf8.decode(dec), '{"a":1}');
    });

    test('RSA PKCS#1 加密输出结构合法（概念版公钥，1024 位）', () {
      // PKCS#1 v1.5 含随机填充，密文每次不同 → 只做结构断言；
      // 正确性由「设备注册联网冒烟」端到端验证（服务端需能解密）。
      final hex = KugouCrypto.rsaPkcs1EncryptHex(
          {'aes': 'abc123', 'uid': 0, 'token': ''},
          KugouConfig.liteRsaPublicKeyPem);
      expect(hex.length, 256); // 1024-bit = 128 bytes = 256 hex
      expect(RegExp(r'^[0-9a-f]{256}$').hasMatch(hex), isTrue);
    });

    test('randomAlnum 字符池与长度', () {
      final s = KugouCrypto.randomAlnum(6);
      expect(s.length, 6);
      expect(RegExp(r'^[1-9A-Z0]{6}$').hasMatch(s), isTrue);
    });
  });
}

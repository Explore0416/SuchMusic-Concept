import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// 酷狗设备注册所需加解密（对齐 KuGouMusicApi `util/crypto.js`）。
///
/// 仅实现 `register_dev` 用到的三个原语：
/// - [playlistAesEncrypt] / [playlistAesDecrypt]：AES-CBC/PKCS7，密钥由 6 位随机串的
///   MD5 前 16/后 16 位十六进制字符（UTF-8 视作字节）派生；
/// - [rsaPkcs1EncryptHex]：RSA PKCS#1 v1.5 加密（概念版公钥）；
/// - [randomAlnum]：与上游 `randomString` 同字符池（`1-9A-Z`）。
class KugouCrypto {
  KugouCrypto._();

  /// 上游 `randomString` 的字符池（36 字符，无字母 O？——沿用原样）。
  static const String _alnumPool = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';

  static final Random _rng = Random.secure();

  /// 与上游同字符池的随机串。
  static String randomAlnum(int len) {
    final sb = StringBuffer();
    for (var i = 0; i < len; i++) {
      sb.write(_alnumPool[_rng.nextInt(_alnumPool.length)]);
    }
    return sb.toString();
  }

  static String md5Hex(String input) =>
      md5.convert(utf8.encode(input)).toString();

  static String bytesToHex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  // ── AES-CBC / PKCS7 ───────────────────────────────────────

  /// AES-CBC/PKCS7 加密；[key]/[iv] 为 UTF-8 字节（长度 16）。
  static Uint8List aesCbcEncrypt(
      Uint8List plain, Uint8List key, Uint8List iv) {
    final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(), CBCBlockCipher(AESEngine()));
    cipher.init(
        true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
    return cipher.process(plain);
  }

  /// AES-CBC/PKCS7 解密。
  static Uint8List aesCbcDecrypt(
      Uint8List cipherBytes, Uint8List key, Uint8List iv) {
    final cipher = PaddedBlockCipherImpl(
        PKCS7Padding(), CBCBlockCipher(AESEngine()));
    cipher.init(
        false, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(key), iv), null));
    return cipher.process(cipherBytes);
  }

  // ── 歌单式 AES（register_dev body）────────────────────────

  /// 结果：`str` = Base64(密文)，`key` = 6 位随机密钥串（解密用）。
  static ({String key, String str}) playlistAesEncrypt(Object data) {
    final key = randomAlnum(6).toLowerCase();
    final md5key = md5Hex(key);
    final encKey = utf8.encode(md5key.substring(0, 16));
    final iv = utf8.encode(md5key.substring(16, 32));
    final out = aesCbcEncrypt(
        Uint8List.fromList(utf8.encode(jsonEncode(data))),
        Uint8List.fromList(encKey),
        Uint8List.fromList(iv));
    return (key: key, str: base64.encode(out));
  }

  /// 解密 register_dev 响应体（原始字节）。
  static dynamic playlistAesDecrypt(Uint8List cipherBytes, String key) {
    final md5key = md5Hex(key);
    final encKey = utf8.encode(md5key.substring(0, 16));
    final iv = utf8.encode(md5key.substring(16, 32));
    final out = aesCbcDecrypt(
        cipherBytes, Uint8List.fromList(encKey), Uint8List.fromList(iv));
    final text = utf8.decode(out, allowMalformed: true);
    try {
      return jsonDecode(text);
    } catch (_) {
      return text;
    }
  }

  // ── RSA PKCS#1 v1.5 ───────────────────────────────────────

  /// RSA PKCS#1 v1.5 加密，返回小写十六进制。
  ///
  /// [pem] 为标准 SubjectPublicKeyInfo PEM；内部用 ASN.1 解析出 (n, e)。
  static String rsaPkcs1EncryptHex(Object data, String pem) {
    final pub = parseRsaPublicKeyFromPem(pem);
    final engine = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(pub));
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
    return bytesToHex(engine.process(bytes));
  }

  /// 解析 PEM（SubjectPublicKeyInfo）为 [RSAPublicKey]。
  static RSAPublicKey parseRsaPublicKeyFromPem(String pem) {
    final b64 = pem
        .replaceAll(RegExp(r'-----[^-]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    final der = base64.decode(b64);
    final top = ASN1Parser(der).nextObject() as ASN1Sequence;
    final bitString = top.elements![1] as ASN1BitString;
    final inner = ASN1Parser(Uint8List.fromList(bitString.stringValues!))
        .nextObject() as ASN1Sequence;
    final n = (inner.elements![0] as ASN1Integer).integer!;
    final e = (inner.elements![1] as ASN1Integer).integer!;
    return RSAPublicKey(n, e);
  }
}

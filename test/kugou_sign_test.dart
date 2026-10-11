// 酷狗签名 / key 的黄金值单元测试。
//
// 期望值由独立 Python 脚本按「ARCH-二改.md §4.6」描述的算法算出：
//   signature = md5(SECRET + (按 key 字母序拼接的 "k=v"，无分隔符) + SECRET)
//   playKey   = md5(hash + pidVersionSecret + appid + mid + userId)
// 断言为固定常量（黄金值），从而锁死拼接顺序与 MD5 结果，防止后续误改。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sources/kugou_sign.dart';

void main() {
  group('KugouSign.md5Hex', () {
    test('MD5 黄金值：abc', () {
      expect(KugouSign.md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
    });

    test('MD5 黄金值：空串', () {
      expect(KugouSign.md5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });

    test('MD5 输出恒为 32 位小写十六进制', () {
      final h = KugouSign.md5Hex('周杰伦 - 晴天');
      expect(h.length, 32);
      expect(h, matches(RegExp(r'^[0-9a-f]{32}$')));
    });
  });

  group('KugouSign.signature（拼接顺序 + MD5 黄金值）', () {
    test('单组参数：按 key 字母序拼接、外层包 SECRET', () {
      // 原始串: SECRET + "appid=1005keyword=周杰伦page=1" + SECRET
      expect(
        KugouSign.signature({'keyword': '周杰伦', 'appid': 1005, 'page': 1}),
        '6ba9eb4661188c97b2336017d2d85671',
      );
    });

    test('入参顺序无关：字典序拼接，结果一致', () {
      final a = KugouSign.signature(
          {'keyword': '周杰伦', 'appid': 1005, 'page': 1});
      final b = KugouSign.signature(
          {'page': 1, 'keyword': '周杰伦', 'appid': 1005});
      expect(a, b);
    });

    test('多组参数（模拟 complexsearch）黄金值', () {
      final params = <String, dynamic>{
        'appid': 1005,
        'clientver': '20989',
        'clienttime': 1700000000000,
        'dfid': 'dfid1234',
        'keyword': 'test',
        'mid': 'mid456',
        'page': 1,
        'pagesize': 30,
        'platid': 4,
        'uuid': 'UUID789',
      };
      expect(KugouSign.signature(params), '15e315d6277e3edfdc46e204570d449d');
    });

    test('值为 null 的键被跳过，不影响结果', () {
      expect(
        KugouSign.signature(
            {'appid': 1005, 'keyword': '周杰伦', 'page': 1, 'x': null}),
        '6ba9eb4661188c97b2336017d2d85671',
      );
    });

    test('拼接使用 "k=v" 直连（无 & 分隔符）—— 固化当前实现语义', () {
      // 若某次改动在拼接中插入 '&'，本断言会失败，提示与 ARCH 文档表述不一致需复核
      final two = KugouSign.signature({'a': 1, 'b': 2});
      // a=1b=2 → SECRET + "a=1b=2" + SECRET
      expect(two,
          KugouSign.md5Hex('LnT6xpN3khm36zse0QzvmgTZ3waWdRSAa=1b=2LnT6xpN3khm36zse0QzvmgTZ3waWdRSA'));
    });
  });

  group('KugouSign.playKey（拼接顺序 + MD5 黄金值）', () {
    test('playKey = md5(hash + pidVersionSecret + appid + mid + userId)', () {
      expect(
        KugouSign.playKey(
            hash: 'abcdef', mid: 'M0123456789', userId: '123456'),
        '23cd3f7bb1096cc2f82723fa1868654d',
      );
    });

    test('hash 大小写敏感（不做归一化，由调用方处理）', () {
      final lower = KugouSign.playKey(hash: 'abc', mid: 'm', userId: 'u');
      final upper = KugouSign.playKey(hash: 'ABC', mid: 'm', userId: 'u');
      expect(lower == upper, isFalse);
    });
  });
}

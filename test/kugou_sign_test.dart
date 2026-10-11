// 酷狗签名 / key 的黄金值单元测试。
//
// 期望值由独立 Python 脚本按「ARCH-二改.md §4.6」描述的算法算出：
//   signature = md5(SECRET + (按 key 字母序拼接的 "k=v"，无分隔符) + SECRET)
//   playKey   = md5(hash + pidVersionSecret + appid + mid + userId)
// 断言为固定常量（黄金值），从而锁死拼接顺序与 MD5 结果，防止后续误改。
import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sources/kugou_config.dart';
import 'package:such_music/services/sources/kugou_device.dart';
import 'package:such_music/services/sources/kugou_sign.dart';

// 固定输入（可复现）：
//   mid = uuid = "0123456789abcdef0123456789abcdef"
//   dfid = "0jAbCdEfGhIjKlMnOpQrSt"
//   clienttime = "1700000000000", srcappid="2919"
//   概念版(lite): clientver="11440", appid="3116"
//   （登录签名向量采用概念版 lite 参数，与应用实际请求一致）
const String _mid = '0123456789abcdef0123456789abcdef';
const String _dfid = '0jAbCdEfGhIjKlMnOpQrSt';
const String _clienttime = '1700000000000';

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
        'b4fdf41ac0798d69220cfa14e8a1d1bf',
      );
    });

    test('hash 大小写敏感（不做归一化，由调用方处理）', () {
      final lower = KugouSign.playKey(hash: 'abc', mid: 'm', userId: 'u');
      final upper = KugouSign.playKey(hash: 'ABC', mid: 'm', userId: 'u');
      expect(lower == upper, isFalse);
    });
  });

  group('KugouSign.loginSignature（扫码登录 · 真实黄金向量）', () {
    test('取码签名 = 4c505c49c0a687f352f48994361ecff2', () {
      final params = <String, dynamic>{
        'appid': 3116,
        'srcappid': 2919,
        'clientver': 11440,
        'clienttime': _clienttime,
        'mid': _mid,
        'uuid': _mid,
        'dfid': _dfid,
        'type': 1,
        'plat': 4,
        'qrcode_txt':
            'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=3116&',
      };
      expect(KugouSign.loginSignature(params),
          '4c505c49c0a687f352f48994361ecff2');
    });

    test('轮询签名 = 22a8093d2e5a7c4b86cf6b06d4ce37fa', () {
      final params = <String, dynamic>{
        'plat': 4,
        'appid': 3116,
        'srcappid': 2919,
        'clientver': 11440,
        'clienttime': _clienttime,
        'mid': _mid,
        'uuid': _mid,
        'dfid': _dfid,
        'qrcode': '2c009c8af2d64383e0983172796f9ec21005',
      };
      expect(KugouSign.loginSignature(params),
          '22a8093d2e5a7c4b86cf6b06d4ce37fa');
    });

    test('登录盐 ≠ 搜索盐：同一参数集结果不同（防混用）', () {
      final params = <String, dynamic>{
        'appid': 3116,
        'clienttime': _clienttime,
      };
      final login = KugouSign.loginSignature(params);
      final search = KugouSign.signature(params);
      expect(login, isNot(equals(search)));
      expect(KugouConfig.loginSecret, isNot(equals(KugouConfig.secret)));
    });

    test('config.qrTxt 与概念版取码参数逐字节一致', () {
      expect(KugouConfig.qrTxt,
          'https://h5.kugou.com/apps/loginQRCode/html/index.html?appid=3116&');
    });
  });

  group('KugouSign.playKey（双平台盐值 · 真实黄金向量）', () {
    const hash = 'b3a52a7a958bf0aed0ebfba2e9a818b7';
    const uid = '0';

    test('概念版 lite 盐 → 5705999901a2c225ef73923914995aa3', () {
      expect(
        KugouSign.playKey(
            hash: hash,
            mid: _mid,
            userId: uid,
            salt: KugouConfig.keySaltLite),
        '5705999901a2c225ef73923914995aa3',
      );
    });

    test('标准版盐 → 429cee3cbae7363ea0d14d8975bfdcb0', () {
      expect(
        KugouSign.playKey(
            hash: hash,
            mid: _mid,
            userId: uid,
            salt: KugouConfig.keySaltStandard),
        '429cee3cbae7363ea0d14d8975bfdcb0',
      );
    });

    test('缺省盐 = 标准版（既有语义不变）', () {
      expect(
        KugouSign.playKey(hash: hash, mid: _mid, userId: uid),
        '429cee3cbae7363ea0d14d8975bfdcb0',
      );
    });
  });

  group('KugouDevice', () {
    test('mid 为 32 位小写 hex', () {
      expect(KugouDevice.mid, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('uuid == mid', () {
      expect(KugouDevice.uuid, KugouDevice.mid);
    });

    test('dfid 匹配 ^0j[A-Za-z0-9]{20}\$', () {
      expect(KugouDevice.dfid, matches(RegExp(r'^0j[A-Za-z0-9]{20}$')));
    });
  });
}

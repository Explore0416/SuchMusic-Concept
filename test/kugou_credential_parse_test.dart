import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sources/kugou_credential_parser.dart';

void main() {
  group('parseCredentialText（粘贴凭证解析）', () {
    test('cookie 风格 token=…; userid=…', () {
      final r = parseCredentialText('token=abc123; userid=88');
      expect(r.token, 'abc123');
      expect(r.userId, '88');
    });

    test('JSON {"token":"…","userid":123}', () {
      final r = parseCredentialText('{"token":"abc123","userid":123}');
      expect(r.token, 'abc123');
      expect(r.userId, '123');
    });

    test('别名 user_id / uid', () {
      expect(parseCredentialText('user_id=456').userId, '456');
      expect(parseCredentialText('uid=789').userId, '789');
    });

    test('多行 + 混入其它 cookie 字段', () {
      const raw = '''
mid=0123abcdef
dfid=0jAbCdEfGhIjKlMnOpQrSt
token=tk_1.2-3
userid=456
''';
      final r = parseCredentialText(raw);
      expect(r.token, 'tk_1.2-3');
      expect(r.userId, '456');
    });

    test('大小写不敏感', () {
      final r = parseCredentialText('TOKEN=ABC; UserID=9');
      expect(r.token, 'ABC');
      expect(r.userId, '9');
    });

    test('带引号与空格', () {
      final r = parseCredentialText('token : "xyz_9" , userid : "7"');
      expect(r.token, 'xyz_9');
      expect(r.userId, '7');
    });

    test('空串 → 均为 null', () {
      final r = parseCredentialText('   ');
      expect(r.token, isNull);
      expect(r.userId, isNull);
    });

    test('无关文本 → 均为 null（不抛）', () {
      final r = parseCredentialText('hello world, no credential here');
      expect(r.token, isNull);
      expect(r.userId, isNull);
    });

    test('不误匹配 my_userid 之类前缀', () {
      expect(parseCredentialText('my_userid=5').userId, isNull);
    });
  });

  group('parseCredentialText 值字符集放宽（Base64 / URL-safe）', () {
    test('值含 + / = 不被截断', () {
      final r = parseCredentialText('token=ab+cd/ef==; userid=42');
      expect(r.token, 'ab+cd/ef==');
      expect(r.userId, '42');
    });

    test('值含 URL 编码 %2B 保留完整', () {
      expect(parseCredentialText('token=a%2Bb%3D').token, 'a%2Bb%3D');
    });

    test('带引号的 Base64 值正确截断在引号处', () {
      expect(parseCredentialText('token="Ab+/==cd"').token, 'Ab+/==cd');
    });

    test('带 MUSIC_U= / token= / userid= 混合 cookie 串', () {
      final r = parseCredentialText(
          'MUSIC_U=9a8b7c; token=AA+/==BB; userid=10086');
      expect(r.token, 'AA+/==BB');
      expect(r.userId, '10086');
    });

    test('多行 cookie 串逐行解析', () {
      const raw = '''
MUSIC_U=zzz==
mid=0123abcd
token=Tk+/1.2-3==
userid=456
''';
      final r = parseCredentialText(raw);
      expect(r.token, 'Tk+/1.2-3==');
      expect(r.userId, '456');
    });

    test('分隔符处截断：& 不会被吞进值', () {
      final r = parseCredentialText('token=aa+/==&userid=7');
      expect(r.token, 'aa+/==');
      expect(r.userId, '7');
    });

    test('非法输入 → null（空值 / 噪声 / 仅前缀）', () {
      expect(parseCredentialText('token=; userid=').token, isNull);
      expect(parseCredentialText('<html>nope</html>').token, isNull);
      expect(parseCredentialText('token=').token, isNull);
      expect(parseCredentialText('   ').token, isNull);
    });
  });
}

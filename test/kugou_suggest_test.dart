import 'package:flutter_test/flutter_test.dart';
import 'package:such_music/services/sources/kugou_source.dart';

void main() {
  group('parseKugouSuggest（酷狗搜索联想响应解析）', () {
    test('标准结构：取出 HintInfo 提示词（去重、保序）', () {
      final data = {
        'status': 1,
        'error_code': 0,
        'data': [
          {
            'RecordDatas': [
              {'HintInfo': '东风破 周杰伦'},
              {'HintInfo': '东风破'},
              {'HintInfo': '东风破 伴奏'},
              {'HintInfo': '东风破'}, // 重复项应被去重
            ],
          },
        ],
      };
      expect(parseKugouSuggest(data), ['东风破 周杰伦', '东风破', '东风破 伴奏']);
    });

    test('字符串 JSON 输入同样可解析', () {
      const json = '{"data":[{"RecordDatas":[{"HintInfo":"晴天 周杰伦"}]}]}';
      expect(parseKugouSuggest(json), ['晴天 周杰伦']);
    });

    test('多段 data 合并', () {
      final data = {
        'data': [
          {
            'RecordDatas': [
              {'HintInfo': 'a'},
            ],
          },
          {
            'RecordDatas': [
              {'HintInfo': 'b'},
            ],
          },
        ],
      };
      expect(parseKugouSuggest(data), ['a', 'b']);
    });

    test('limit 生效（最多返回 limit 条）', () {
      final data = {
        'data': [
          {
            'RecordDatas': List.generate(20, (i) => {'HintInfo': 'k$i'}),
          },
        ],
      };
      expect(parseKugouSuggest(data, limit: 3), ['k0', 'k1', 'k2']);
    });

    test('异常形态不抛异常：null / 非 JSON / 结构不符', () {
      expect(parseKugouSuggest(null), isEmpty);
      expect(parseKugouSuggest('not-a-json'), isEmpty);
      expect(parseKugouSuggest({}), isEmpty);
      expect(parseKugouSuggest({'data': 'oops'}), isEmpty);
      expect(parseKugouSuggest({'data': [1, 2, 3]}), isEmpty);
    });

    test('字段缺失 / 类型不符时跳过非法项，保留合法项', () {
      final data = {
        'data': [
          {
            'RecordDatas': [
              {'HintInfo': 123}, // 非字符串
              {'no_hint': 'x'}, // 缺字段
              {'HintInfo': 'ok'},
            ],
          },
        ],
      };
      expect(parseKugouSuggest(data), ['ok']);
    });

    test('空白提示词被过滤', () {
      final data = {
        'data': [
          {
            'RecordDatas': [
              {'HintInfo': '   '},
              {'HintInfo': '有效词'},
            ],
          },
        ],
      };
      expect(parseKugouSuggest(data), ['有效词']);
    });
  });
}

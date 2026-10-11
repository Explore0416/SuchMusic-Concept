/// 从用户粘贴的整段文本中提取酷狗凭证（兜底渠道，回应用户「怎么搞 token」）。
///
/// 支持多种形态：
/// - cookie 风格：`token=xxx; userid=yyy`；
/// - 多行 / 混合文本；
/// - JSON：`{"token":"...","userid":123}`；
/// - 别名：`user_id` / `uid`。
///
/// 提取不到对应字段返回 `null`，**不抛异常**。
library;

/// 提取结果（字段可空）。
typedef ParsedCredential = ({String? token, String? userId});

/// 解析粘贴文本 → `(token, userId)`。
ParsedCredential parseCredentialText(String raw) {
  if (raw.trim().isEmpty) return (token: null, userId: null);
  final token = _extract(raw, r'token');
  final userId = _extract(raw, r'userid|user_id|uid');
  return (token: token, userId: userId);
}

String? _extract(String raw, String keyPattern) {
  // 前置边界：行首或非单词字符（避免误匹配 my_userid 之类）。
  // 取值字符集放宽到覆盖 URL-safe / Base64（`+ / = %`），避免真实 token
  // 被截断；分隔符（`;`、`&`、空白、`,`、换行、引号等）仍在集合之外，
  // 因此仍会正确截断，不会把后续参数吞进来。
  final re = RegExp(
    '(?:^|[^A-Za-z0-9_])(?:$keyPattern)["\']?\\s*[:=]\\s*["\']?([A-Za-z0-9._\\-+/=%]+)',
    caseSensitive: false,
  );
  final m = re.firstMatch(raw);
  return m?.group(1);
}

import 'kugou_config.dart';

/// 扫码登录状态机（与接口 `data.status` 映射见 ARCH-酷狗登录 §2.3）。
enum QrLoginState {
  /// 0 = 二维码过期 → 上层自动重新取码。
  expired,

  /// 1 = 等待扫码。
  waiting,

  /// 2 = 已扫码，待手机确认。
  scanned,

  /// 3 = （预留，接口未见）。
  confirmed,

  /// 4 = 授权成功，携带 token + userid。
  success,

  /// 本地判定：超时 / 连续错误 / 取码失败。
  failed,
}

/// 一次扫码会话（取码结果）。
class KugouQrSession {
  const KugouQrSession({
    required this.key,
    required this.imageDataUri,
    required this.expiresAt,
  });

  /// 接口 `qrcode` 字段，轮询主键。
  final String key;

  /// `"data:image/png;base64,..."`；可能为空串（走 `qr_flutter` 备选）。
  final String imageDataUri;

  /// 本地推算 = `now + sessionTtl`。
  final DateTime expiresAt;

  /// `qr_flutter` 备选渲染源（无 `qrcode_img` 时使用）。
  String get placeholderUrl => '${KugouConfig.qrH5Base}?qrcode=$key';

  /// 是否已过期（本地 TTL 判定）。
  bool isExpiredAt(DateTime now) => !now.isBefore(expiresAt);
}

/// 一次轮询 / 自动登录的更新事件（流元素）。
class KugouQrPollResult {
  const KugouQrPollResult({
    required this.state,
    this.token,
    this.userId,
    this.session,
    this.message,
  });

  final QrLoginState state;

  /// 仅 [QrLoginState.success]。
  final String? token;

  /// 仅 [QrLoginState.success]。
  final String? userId;

  /// 非 success 时附带「当前有效码」（换码后为新码）。
  final KugouQrSession? session;

  /// 失败 / 提示文案（可空）。
  final String? message;

  /// 失败事件。
  factory KugouQrPollResult.failed(String reason) =>
      KugouQrPollResult(state: QrLoginState.failed, message: reason);

  /// 过期事件（换码后带回新 session）。
  factory KugouQrPollResult.expired(KugouQrSession? next) =>
      KugouQrPollResult(state: QrLoginState.expired, session: next);
}

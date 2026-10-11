/// 酷狗概念版接口常量（集中配置，便于接口轮换时热修）。
///
/// 全为第三方逆向接口参数，见 `docs/ARCH-二改.md` §4.6 与
/// `docs/ARCH-酷狗登录.md`（增量：扫码登录 + 双盐值）。
class KugouConfig {
  KugouConfig._();

  // ── 签名密钥 ──────────────────────────────────────────────

  /// Web 端接口签名盐值：**搜索（`complexsearch/v2/search/song`）
  /// 与登录（`login-user.kugou.com`）共用**。
  ///
  /// ⚠️ 实测：complexsearch 是 Web 端接口，必须用本盐值；误用
  /// [androidSecretLite] 会被服务端拒绝（`error_code=20006`）→ 搜索恒为空。
  static const String webSecret = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

  /// Android 端接口签名盐值（概念版 / lite）：用于 gateway 取播放地址。
  static const String androidSecretLite = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

  /// 历史命名别名，等价于 [webSecret]（Web 端登录 / 搜索盐值）。
  ///
  /// 保留仅为兼容既有调用点，新代码请直接使用 [webSecret]。
  static const String loginSecret = webSecret;

  /// 历史命名别名，等价于 [androidSecretLite]（Android 端取地址盐值）。
  ///
  /// ⚠️ 与 [webSecret] 是**两套独立签名体系**，混用会得到错误签名
  /// （实测返回 `error_code=20006`）。新代码请直接使用 [androidSecretLite]。
  static const String secret = androidSecretLite;

  /// 播放地址 key 盐值：概念版（lite）。
  static const String keySaltLite = '185672dd44712f60bb1736df5a377e82';

  /// 播放地址 key 盐值：标准版。
  static const String keySaltStandard = '57ae12eb6890223e355ccfcb74edf70d';

  /// @Deprecated 历史命名，保留兼容，指向标准版盐值。
  @Deprecated('请使用 keySaltStandard / keySaltLite 明确平台归属')
  static const String pidVersionSecret = keySaltStandard;

  /// appkey
  static const String appkey = 'OIlwieks28dk2k092lksi2UIkp';

  // ── 接口 Host ─────────────────────────────────────────────

  /// 主搜索接口（需签名）。
  static const String complexSearchHost = 'https://complexsearch.kugou.com';

  /// 免签名兜底搜索（**仅**在主路径返回空时使用）。
  static const String mobileCdnHost = 'https://mobilecdn.kugou.com';

  /// 播放地址网关（需 Header x-router: tracker.kugou.com）。
  static const String gatewayHost = 'https://gateway.kugou.com';

  /// 歌词检索。
  static const String krcsHost = 'https://krcs.kugou.com';

  /// 歌词下载。
  static const String lyricsHost = 'https://lyrics.kugou.com';

  // ── 登录接口（扫码）───────────────────────────────────────

  /// 登录接口 Host。
  static const String loginHost = 'https://login-user.kugou.com';

  /// 取二维码路径。
  static const String loginQrPath = '/v2/qrcode';

  /// 轮询扫码状态路径。
  static const String loginStatusPath = '/v2/get_userinfo_qrcode';

  /// H5 扫码页（`qr_flutter` 备选渲染源）。
  static const String qrH5Base =
      'https://h5.kugou.com/apps/loginQRCode/html/index.html';

  /// 登录接口客户端版本（≠ 搜索的 [clientver]）。
  static const int loginClientver = 20489;

  /// 登录二维码 type 固定值。
  static const int qrcodeType = 1;

  /// 登录平台标识（Web）。
  static const int platWeb = 4;

  /// 登录请求 Referer。
  static const String loginReferer = 'https://www.kugou.com/';

  /// 登录请求 Origin。
  static const String loginOrigin = 'https://www.kugou.com/';

  /// 取码请求 `qrcode_txt` 参数（实测固定值，参与签名，**逐字节敏感**）。
  static String get qrTxt => '$qrH5Base?appid=$appid&';

  // ── 固定参数 ──────────────────────────────────────────────

  static const int appid = 1005;
  static const String clientver = '20989';

  /// Web 端签名固定参数（概念版 WebFilter）。
  static const int srcappid = 2919;

  /// 概念版 VIP 音质标识（失败回退 mtype=2）。
  static const int vipType = 6;

  /// 通用 User-Agent。
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36';
}

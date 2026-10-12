import '../../models/kugou_platform.dart';

// 便于既有调用点（import kugou_config 处）直接拿到平台枚举。
export '../../models/kugou_platform.dart';

/// 酷狗接口常量（集中配置，便于接口轮换时热修）。
///
/// 全为第三方逆向接口参数，见 `docs/ARCH-二改.md` §4.6 与
/// `docs/ARCH-酷狗登录.md`（增量：扫码登录 + 双盐值）。
/// 平台变体枚举见 `models/kugou_platform.dart`。
class KugouConfig {
  KugouConfig._();

  // ── 平台参数查询（standard / lite）────────────────────────
  //
  // 参照 KuGouMusicApi 双版本架构（util/config.json + util/helper.js）。
  // 【关键】请求 `appid` 决定服务端按哪个平台校验身份与权益：
  //   - 1005（标准版）→ 「酷狗音乐」权益；
  //   - 3116（概念版）→ 「酷狗概念版」权益与播放凭证。

  /// 按平台取 appid。
  static int appidOf(KugouPlatform p) =>
      p == KugouPlatform.lite ? liteAppid : standardAppid;

  /// 按平台取 clientver（字符串形式，用于签名拼接）。
  static String clientverOf(KugouPlatform p) =>
      p == KugouPlatform.lite ? '11440' : '20489';

  /// 按平台取 **Android 端接口签名盐值**（gateway / 取直链 / 每日推荐等）。
  static String androidSaltOf(KugouPlatform p) =>
      p == KugouPlatform.lite ? androidSecretLite : androidSecretStandard;

  /// 按平台取 **播放地址 key 盐值**。
  static String keySaltOf(KugouPlatform p) =>
      p == KugouPlatform.lite ? keySaltLite : keySaltStandard;

  /// 按平台取 **设备注册 RSA 公钥**（PKCS#1 v1.5 会话串加密）。
  static String rsaPublicKeyOf(KugouPlatform p) =>
      p == KugouPlatform.lite ? liteRsaPublicKeyPem : standardRsaPublicKeyPem;

  /// 按平台取登录客户端版本号。
  static int loginClientverOf(KugouPlatform p) => p == KugouPlatform.lite
      ? liteClientver
      : standardClientver;

  /// 按平台取取直链 `version` 参数（对齐各平台客户端）。
  static int playVersionOf(KugouPlatform p) =>
      p == KugouPlatform.lite ? 11430 : 20489;

  // ── 签名密钥 ──────────────────────────────────────────────

  /// Web 端接口签名盐值：**搜索（`complexsearch/v2/search/song`）
  /// 与登录（`login-user.kugou.com`）共用**。
  ///
  /// ⚠️ 实测：complexsearch 是 Web 端接口，必须用本盐值；误用
  /// 概念版 android 盐会被服务端拒绝（`error_code=20006`）→ 搜索恒为空。
  /// 该盐值**两个平台共用**（实测）。
  static const String webSecret = 'NVPh5oo715z5DIWAeQlhMDsWXXQV4hwt';

  /// Android 端接口签名盐值（概念版 / lite）：用于 gateway 取播放地址。
  static const String androidSecretLite = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

  /// Android 端接口签名盐值（标准版 / 酷狗音乐）。
  static const String androidSecretStandard = 'OIlwieks28dk2k092lksi2UIkp';

  /// 历史命名别名，等价于 [webSecret]（Web 端登录 / 搜索盐值）。
  ///
  /// 保留仅为兼容既有调用点，新代码请直接使用 [webSecret]。
  static const String loginSecret = webSecret;

  /// 历史命名别名，等价于 [androidSecretLite]（Android 端取地址盐值，概念版）。
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

  /// appkey（标准版，Android 端）。
  static const String appkey = 'OIlwieks28dk2k092lksi2UIkp';

  // ── 平台差异：概念版(lite) vs 标准版(standard) ──────────────

  /// 概念版（lite）应用标识。
  static const int liteAppid = 3116;

  /// 概念版（lite）客户端版本号。
  static const int liteClientver = 11440;

  /// 标准版（标准/普通酷狗音乐）应用标识。
  static const int standardAppid = 1005;

  /// 标准版客户端版本号。
  static const int standardClientver = 20489;


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

  /// 登录接口客户端版本（**概念版 lite**）。
  static const int loginClientver = liteClientver;

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

  /// 按平台取 `qrcode_txt`（其内 appid 决定扫码授权到哪个平台）。
  static String qrTxtOf(KugouPlatform p) =>
      '$qrH5Base?appid=${appidOf(p)}&';

  // ── 固定参数 ──────────────────────────────────────────────

  /// 默认平台（概念版）的 appid。
  static const int appid = liteAppid;

  /// 默认平台（概念版）的 clientver。
  static const String clientver = '11440';

  /// Web 端签名固定参数（概念版 WebFilter）。
  static const int srcappid = 2919;

  /// 概念版 VIP 音质标识（失败回退 mtype=2）。
  static const int vipType = 6;

  /// 通用 User-Agent。
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36';

  /// Android 客户端 UA（取直链 / 设备注册等 Android 端接口用）。
  static const String androidUserAgent =
      'Android15-1070-11083-46-0-DiscoveryDRADProtocol-wifi';

  /// 移动端 Web UA（解析歌单分享页用）。
  static const String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 13; M2012K11AC) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  // ── 设备注册（register_dev，取直链前置）────────────────────
  //
  // ⚠️ 关键：酷狗取播放直链接口对**未注册设备**返回 `20028 本次请求需要验证`
  // （风控）。必须先经 `register_dev` 拿到真实 `dfid` 并持久化，取直链才可用。

  /// 设备注册接口 Host。
  static const String registerHost = 'https://userservice.kugou.com';

  /// 设备注册路径。
  static const String registerPath = '/risk/v2/r_register_dev';

  /// 概念版 RSA 公钥（PEM，PKCS#1 v1.5 加密会话串用）。
  static const String liteRsaPublicKeyPem =
      '-----BEGIN PUBLIC KEY-----\n'
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDECi0Np2UR87scwrvTr72L6oO01rBbbBPriSDFPxr3Z5syug0O24QyQO8bg27+0+4kBzTBTBOZ/WWU0WryL1JSXRTXLgFVxtzIY41Pe7lPOgsfTCn5kZcvKhYKJesKnnJDNr5/abvTGf+rHG3YRwsCHcQ08/q6ifSioBszvb3QiwIDAQAB\n'
      '-----END PUBLIC KEY-----';

  /// 标准版（酷狗音乐）RSA 公钥（PKCS#1 v1.5）。
  static const String standardRsaPublicKeyPem =
      '-----BEGIN PUBLIC KEY-----\n'
      'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDIAG7QOELSYoIJvTFJhMpe1s/gbjDJX51HBNnEl5HXqTW6lQ7LC8jr9fWZTwusknp+sVGzwd40MwP6U5yDE27M/X1+UR4tvOGOqp94TJtQ1EPnWGWXngpeIW5GxoQGao1rmYWAu6oi1z9XkChrsUdC6DJE5E221wf/4WLFxwAtRQIDAQAB\n'
      '-----END PUBLIC KEY-----';

  // ── 取播放直链（/v5/url，x-router: trackercdn）────────────

  /// 取直链路径（经网关，x-router 路由到 trackercdn.kugou.com）。
  static const String playUrlPath = '/v5/url';

  /// 取直链请求 x-router。
  static const String playUrlRouter = 'trackercdn.kugou.com';

  /// 取直链固定参数（概念版 lite 取值，见 KuGouMusicApi module/song_url.js）。
  static const int playVersion = 11430;
  static const int playPageId = 967177915;
  static const int playPid = 411;
  static const int playCmd = 26;
  static const int playPidVersion = 3001;
  static const String playPpageId = '356753938,823673182,967485191';

  /// 按平台取 `page_id`（标准版不同，错用 → `31833 illegal key`）。
  static int playPageIdOf(KugouPlatform p) =>
      p == KugouPlatform.lite ? 967177915 : 151369488;

  /// 按平台取 `pid`（标准版为 2）。
  static int playPidOf(KugouPlatform p) => p == KugouPlatform.lite ? 411 : 2;

  /// 按平台取 `ppage_id`。
  static String playPpageIdOf(KugouPlatform p) => p == KugouPlatform.lite
      ? '356753938,823673182,967485191'
      : '463467626,350369493,788954147';

  /// 设备注册 / 取直链 通用请求头（对齐上游 createRequest）。
  static const Map<String, String> androidCommonHeaders = {
    'kg-rc': '1',
    'kg-thash': '5d816a0',
    'kg-rec': '1',
    'kg-rf': 'B9EDA08A64250DEFFBCADDEE00F8F25F',
  };

  // ── 排行榜（榜单）────────────────────────────────────────

  /// 排行榜列表路径（GET，经网关）。
  static const String rankListPath = '/ocean/v6/rank/list';

  /// 排行榜歌曲路径（POST，经网关）。
  static const String rankAudioPath = '/openapi/kmr/v2/rank/audio';

  /// 排行榜歌曲请求头。
  static const Map<String, String> rankAudioHeaders = {'kg-tid': '369'};

  // ── 每日推荐 ─────────────────────────────────────────────

  /// 每日推荐路径（POST，x-router 到 everydayrec 服务）。
  static const String dailyRecommendPath = '/everyday_song_recommend';

  /// 每日推荐 x-router。
  static const String dailyRecommendRouter = 'everydayrec.service.kugou.com';

  // ── 私人FM（需登录态 token）──────────────────────────────
  //
  // ⚠️ 该接口需 `userid` + `token`（未登录返回空/失败），故登录态下才可用；
  // 未登录时上层以「每日推荐随机取曲」兜底。

  /// 私人FM 路径（POST，x-router 到 persnfm 服务）。
  static const String personalFmPath = '/v2/personal_recommend';

  /// 私人FM x-router。
  static const String personalFmRouter = 'persnfm.service.kugou.com';

  // ── 用户歌单 / 歌单导入 ──────────────────────────────────

  /// 用户歌单列表路径（POST，x-router cloudlist），需 userid + token。
  static const String userPlaylistPath = '/v7/get_all_list';

  /// 用户歌单列表 x-router。
  static const String userPlaylistRouter = 'cloudlist.service.kugou.com';

  /// 歌单详情路径（POST，x-router pubsongs，按 global_collection_id）。
  static const String playlistDetailPath = '/v3/get_list_info';

  /// 歌单详情 x-router。
  static const String playlistDetailRouter = 'pubsongs.kugou.com';

  /// 歌单歌曲路径（GET，x-router pubsongs），按 global_collection_id。
  static const String playlistSongsPath = '/pubsongs/v2/get_other_list_file_nofilt';

  /// 歌单歌曲 x-router。
  static const String playlistSongsRouter = 'pubsongs.kugou.com';

  /// 推荐歌单路径（POST，x-router specialrec），无需登录。
  static const String topPlaylistPath = '/v2/special_recommend';

  /// 推荐歌单 x-router。
  static const String topPlaylistRouter = 'specialrec.service.kugou.com';
}

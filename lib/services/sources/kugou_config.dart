/// 酷狗概念版接口常量（集中配置，便于接口轮换时热修）。
///
/// 全部为第三方逆向接口参数，见 docs/ARCH-二改.md §4.6。
class KugouConfig {
  KugouConfig._();

  // ── 签名密钥 ──────────────────────────────────────────────

  /// signature 计算密钥（默认 LDDC 值）
  static const String secret = 'LnT6xpN3khm36zse0QzvmgTZ3waWdRSA';

  /// 播放地址 key 计算用
  static const String pidVersionSecret = '57ae12eb6890223e355ccfcb74edf70d';

  /// appkey
  static const String appkey = 'OIlwieks28dk2k092lksi2UIkp';

  // ── 接口 Host ─────────────────────────────────────────────

  /// 主搜索接口（需签名）
  static const String complexSearchHost = 'https://complexsearch.kugou.com';

  /// 免签名兜底搜索（优先使用）
  static const String mobileCdnHost = 'https://mobilecdn.kugou.com';

  /// 播放地址网关（需 Header x-router: tracker.kugou.com）
  static const String gatewayHost = 'https://gateway.kugou.com';

  /// 歌词检索
  static const String krcsHost = 'https://krcs.kugou.com';

  /// 歌词下载
  static const String lyricsHost = 'https://lyrics.kugou.com';

  // ── 固定参数 ──────────────────────────────────────────────

  static const int appid = 1005;
  static const String clientver = '20989';

  /// Web 端搜索签名固定参数（概念版 WebFilter）
  static const int srcappid = 2919;

  /// 概念版 VIP 音质标识（失败回退 mtype=2）
  static const int vipType = 6;

  /// 通用 User-Agent
  static const String userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36';
}

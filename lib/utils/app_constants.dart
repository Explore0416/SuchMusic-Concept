/// 全局常量与 SharedPreferences key 的集中定义处。
///
/// 约定（见 `docs/ARCH-二改.md` §12）：
/// - 尺寸 / 断点 → `lib/utils/responsive.dart`
/// - prefs key 与业务常量 → 本文件
/// - 酷狗密钥 / 接口常量 → `lib/services/sources/kugou_config.dart`
///
/// 所有读取失败的 prefs 一律走默认值，不抛异常。
class AppConstants {
  AppConstants._();

  // ── SharedPreferences key（统一 snake_case）──────────────────

  /// 与其他应用同时播放（既有键，勿改）
  static const String allowMixWithOthers = 'allowMixWithOthers';

  /// 通知 / 灵动岛显示歌词总开关（REQ-06，默认开）
  static const String notifyLyricEnabled = 'notify_lyric_enabled';

  /// 小米超级岛增强开关（能力检测不通过仍静默禁用，默认开）
  static const String miuiIslandEnabled = 'miui_island_enabled';

  /// 当前音源（netease / kugou）
  static const String musicSource = 'music_source';

  /// 主音源失败时是否自动回退网易云
  static const String kugouFallbackEnabled = 'kugou_fallback_enabled';

  /// 酷狗凭证 token
  static const String kugouToken = 'kugou_token';

  /// 酷狗凭证 userid
  static const String kugouUserid = 'kugou_userid';

  /// 酷狗昵称（展示用）
  static const String kugouNickname = 'kugou_nickname';

  /// 酷狗设备 mid（数字串，持久化——dfid 与之绑定，必须跨启动稳定）
  static const String kugouMid = 'kugou_mid';

  /// 酷狗设备 GUID（UUID v4，注册时作 uuid/imei）
  static const String kugouGuid = 'kugou_guid';

  /// 酷狗设备 dfid（设备注册所得，取直链必需）
  static const String kugouDfid = 'kugou_dfid';

  /// 「猜你想听」曲风档案独立键（当前实现已将 tagIndex/artistIndex 并入
  /// `play_history_v1` 的 v2 JSON，本键作为「独立档案」的备选预留，不写入）。
  static const String recommendationProfile = 'recommendation_profile_v1';

  /// 「猜你想听」参数覆盖键（预留：可从 prefs 覆盖 RecommendationConfig）。
  static const String recommendationConfigOverride =
      'recommendation_config_override';

  // ── 默认值 ────────────────────────────────────────────────

  /// 通知歌词开关默认开
  static const bool defaultNotifyLyricEnabled = true;

  /// 超级岛增强默认开
  static const bool defaultMiuiIslandEnabled = true;

  /// 失败自动回退默认开
  static const bool defaultKugouFallbackEnabled = true;

  // ── 脱敏工具 ──────────────────────────────────────────────

  /// token / userid 一律脱敏为 `前4****后4`。
  ///
  /// 长度不足 8 时整体以 `*` 遮盖，避免泄露短串。空串返回空串。
  static String maskToken(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    if (raw.length <= 8) {
      return '*' * raw.length;
    }
    final head = raw.substring(0, 4);
    final tail = raw.substring(raw.length - 4);
    return '$head****$tail';
  }
}

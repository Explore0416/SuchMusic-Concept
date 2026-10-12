/// 酷狗平台变体（领域枚举，独立于接口常量，供 models / services 共用）。
///
/// - [lite]：酷狗概念版（appid=3116 / clientver=11440）
/// - [standard]：酷狗音乐（原版，appid=1005 / clientver=20489）
///
/// **不同平台的 token 与权益不通用**，故凭证 / 设备标识按平台分区。
/// 对应的接口参数见 `services/sources/kugou_config.dart`。
enum KugouPlatform {
  lite('lite', '酷狗概念版'),
  standard('standard', '酷狗音乐');

  const KugouPlatform(this.code, this.label);

  /// 持久化标识。
  final String code;

  /// UI 展示名。
  final String label;

  static KugouPlatform fromCode(String? code) =>
      KugouPlatform.values.firstWhere(
        (e) => e.code == code,
        orElse: () => KugouPlatform.lite,
      );
}

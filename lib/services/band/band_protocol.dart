/// SuchMusic 手环通信 · 统一信封与协议协商（纯逻辑，无 IO、无平台依赖）。
///
/// 严格遵循 `docs/ARCH-手环通信.md` §3：
/// - 统一信封 `{v,id,type,method|event,payload,ts}`（字段名已冻结）；
/// - 版本协商取交集最大值；交集为空 → `E_UNSUPPORTED{E_PROTO}`；
/// - 能力令牌 `playback·queue·search·lyric·playmode·volume·cover·transfer`；
/// - 错误码表见 §3.7。
///
/// 本文件不含任何状态与副作用，便于确定性单测。
library;

import 'dart:convert';

/// 协议主版本（本端支持）。
const int kProtocolVersion = 1;

/// 本端支持的协议版本集合。
const List<int> kSupportedProtocols = [1];

/// 合法信封 `type` 取值。
const List<String> kEnvelopeTypes = ['req', 'res', 'evt', 'err'];

/// 全部能力令牌（§3.3 最终值）。
const List<String> kAllCaps = [
  'playback',
  'queue',
  'search',
  'lyric',
  'playmode',
  'volume',
  'cover',
  'transfer',
];

/// 方法 → 所需能力（无能力要求的方法不在此表内）。
const Map<String, String> kMethodCaps = {
  'playback.play': 'playback',
  'playback.pause': 'playback',
  'playback.toggle': 'playback',
  'playback.next': 'playback',
  'playback.prev': 'playback',
  'playback.seek': 'playback',
  'playback.setMode': 'playmode',
  'playback.setVolume': 'volume',
  'queue.play': 'queue',
  'queue.clear': 'queue',
  'search.song': 'search',
  'search.suggest': 'search',
  'search.hot': 'search',
  'lyric.window': 'lyric',
  'cover.get': 'cover',
  'xfer.nack': 'transfer',
};

/// 事件 → 所需能力（无能力要求的事件不在此表内）。
const Map<String, String> kEventCaps = {
  'player.state': 'playback',
  'player.progress': 'playback',
  'player.mode': 'playmode',
  'player.volume': 'volume',
  'player.queue': 'queue',
  'lyric.line': 'lyric',
  'lyric.meta': 'lyric',
  'search.result': 'search',
  'search.preset': 'search',
  'xfer.chunk': 'transfer',
};

/// 协议错误码（§3.7 冻结）。
class BandErrorCode {
  BandErrorCode._();

  static const String badReq = 'E_BADREQ';
  static const String unsupported = 'E_UNSUPPORTED';
  static const String timeout = 'E_TIMEOUT';
  static const String notReady = 'E_NOT_READY';
  static const String empty = 'E_EMPTY';
  static const String notFound = 'E_NOT_FOUND';
  static const String link = 'E_LINK';
  static const String tooLarge = 'E_TOOLARGE';
  static const String crc = 'E_CRC';
  static const String internal = 'E_INTERNAL';
}

/// 信封非法时抛出的异常（携带协议错误码）。
class BandEnvelopeException implements Exception {
  const BandEnvelopeException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BandEnvelopeException($code: $message)';
}

/// 统一信封（字段名冻结）。
class BandEnvelope {
  const BandEnvelope({
    required this.v,
    this.id,
    required this.type,
    this.method,
    this.event,
    this.payload = const {},
    this.ts,
    this.target,
  });

  /// 协议主版本。
  final int v;

  /// 消息 id，格式 `{origin}-{bootId}-{seq}`；evt 可空。
  final String? id;

  /// `req` / `res` / `evt` / `err`。
  final String type;

  /// 仅 `req` 使用。
  final String? method;

  /// 仅 `evt` 使用。
  final String? event;

  /// 恒存在，可为空对象。
  final Map<String, dynamic> payload;

  /// 发送时间戳（ms），可空。
  final int? ts;

  /// **内部路由提示**（不参与序列化，协议字段仍冻结）：本帧应投递的目标会话 id。
  ///
  /// - `null` → 全局事件（如 `player.*` 状态变化），传输层**广播**给全部在线会话；
  /// - 非 `null` → 定向帧（如某次请求触发的 `xfer.chunk` 分片、`sys.hello_ack`），
  ///   传输层**仅投递给该会话**。
  ///
  /// 仅在下行 `evt` 上使用；不影响 [encode] / [toJson] 的输出，[decode] 也不会设置它
  /// （避免改动已冻结的线上协议）。见 §4.3.1「定向投递」。
  final String? target;

  /// 请求构造。
  factory BandEnvelope.request(String id, String method,
          {Map<String, dynamic> payload = const {}, int? ts}) =>
      BandEnvelope(
          v: kProtocolVersion,
          id: id,
          type: 'req',
          method: method,
          payload: payload,
          ts: ts);

  /// 成功响应构造（复用请求 id）。
  factory BandEnvelope.response(String id,
          {Map<String, dynamic> payload = const {}}) =>
      BandEnvelope(v: kProtocolVersion, id: id, type: 'res', payload: payload);

  /// 错误响应构造（复用请求 id）。
  factory BandEnvelope.error(String id, String code, String message) =>
      BandEnvelope(v: kProtocolVersion, id: id, type: 'err', payload: {
        'code': code,
        'message': message,
      });

  /// 事件构造（id 可空）。
  ///
  /// [target] 为内部路由提示（不参与序列化）：非空表示定向投递给该会话。
  factory BandEnvelope.event(String event,
          {Map<String, dynamic> payload = const {},
          String? id,
          int? ts,
          String? target}) =>
      BandEnvelope(
          v: kProtocolVersion,
          id: id,
          type: 'evt',
          event: event,
          payload: payload,
          ts: ts,
          target: target);

  /// 序列化为 UTF-8 JSON 字符串（字段顺序稳定，便于抓包对照）。
  String encode() => jsonEncode(toJson());

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{'v': v};
    if (id != null) map['id'] = id;
    map['type'] = type;
    if (method != null) map['method'] = method;
    if (event != null) map['event'] = event;
    map['payload'] = payload;
    if (ts != null) map['ts'] = ts;
    return map;
  }

  /// 解析 JSON 字符串为信封；非法时抛 [BandEnvelopeException]。
  static BandEnvelope decode(String raw) {
    final dynamic obj = jsonDecode(raw);
    return fromMap(obj);
  }

  /// 从已解析对象构造并校验；非法时抛 [BandEnvelopeException]。
  static BandEnvelope fromMap(Object? obj) {
    if (obj is! Map) {
      throw const BandEnvelopeException(
          BandErrorCode.badReq, 'envelope must be a JSON object');
    }

    final v = obj['v'];
    if (v is! int) {
      throw const BandEnvelopeException(BandErrorCode.badReq, 'v must be int');
    }

    final type = obj['type'];
    if (type is! String || !kEnvelopeTypes.contains(type)) {
      throw BandEnvelopeException(
          BandErrorCode.badReq, 'type must be one of $kEnvelopeTypes');
    }

    final rawId = obj['id'];
    if (rawId != null && rawId is! String) {
      throw const BandEnvelopeException(
          BandErrorCode.badReq, 'id must be string');
    }
    final id = rawId as String?;

    final method = obj['method'];
    if (method != null && method is! String) {
      throw const BandEnvelopeException(
          BandErrorCode.badReq, 'method must be string');
    }
    final event = obj['event'];
    if (event != null && event is! String) {
      throw const BandEnvelopeException(
          BandErrorCode.badReq, 'event must be string');
    }

    if (type == 'req' && (method == null || method.isEmpty)) {
      throw const BandEnvelopeException(
          BandErrorCode.badReq, 'req requires non-empty method');
    }
    if (type == 'evt' && (event == null || event.isEmpty)) {
      throw const BandEnvelopeException(
          BandErrorCode.badReq, 'evt requires non-empty event');
    }
    if (type != 'evt' && (id == null || id.isEmpty)) {
      throw BandEnvelopeException(
          BandErrorCode.badReq, '$type requires non-empty id');
    }

    final rawPayload = obj['payload'];
    if (rawPayload != null && rawPayload is! Map) {
      throw const BandEnvelopeException(
          BandErrorCode.badReq, 'payload must be an object');
    }
    final payload = rawPayload == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(rawPayload);

    final rawTs = obj['ts'];
    if (rawTs != null && rawTs is! int) {
      throw const BandEnvelopeException(BandErrorCode.badReq, 'ts must be int');
    }

    return BandEnvelope(
      v: v,
      id: id,
      type: type,
      method: method as String?,
      event: event as String?,
      payload: payload,
      ts: rawTs as int?,
    );
  }

  /// 便捷校验：合法返回 null，否则返回错误描述。
  static String? validate(String raw) {
    try {
      decode(raw);
      return null;
    } on BandEnvelopeException catch (e) {
      return e.message;
    } on FormatException catch (e) {
      return 'invalid JSON: ${e.message}';
    }
  }
}

/// 播放模式（协议侧，与 `AudioPlayerService.PlayMode` 一一对应）。
enum BandPlayMode {
  loop('loop'),
  single('single'),
  shuffle('shuffle');

  const BandPlayMode(this.code);

  final String code;

  /// 由协议字符串解析；未知值回退 [BandPlayMode.loop]（§4.4 D1 兜底策略）。
  static BandPlayMode fromCode(String? code) {
    for (final m in BandPlayMode.values) {
      if (m.code == code) return m;
    }
    return BandPlayMode.loop;
  }
}

/// 版本 / 能力协商（纯函数）。
class BandProtocol {
  BandProtocol._();

  /// 版本协商：取两版集合交集的**最大值**；交集为空返回 null（→ `E_UNSUPPORTED{E_PROTO}`）。
  static int? negotiateVersion(List<int> band, List<int> phone) {
    final phoneSet = phone.toSet();
    final common = band.where(phoneSet.contains).toList()..sort();
    return common.isEmpty ? null : common.last;
  }

  /// 能力协商：交集（去重 + 排序，保证确定性输出）。
  static List<String> negotiateCaps(List<String> band, List<String> phone) {
    final phoneSet = phone.toSet();
    final common = band.where(phoneSet.contains).toSet().toList()..sort();
    return common;
  }

  /// 方法所需能力（无要求返回 null）。
  static String? methodCap(String method) => kMethodCaps[method];

  /// 事件所需能力（无要求返回 null）。
  static String? eventCap(String event) => kEventCaps[event];

  /// 方法是否被声明（用于区分「未知方法」与「能力缺失」）。
  static bool isKnownMethod(String method) =>
      kMethodCaps.containsKey(method) ||
      const {'sys.hello', 'sys.ping', 'state.get', 'song.info'}.contains(method);

  /// **会话就绪闸门**：会话 READY（已成功 `sys.hello`）之前允许的方法。
  ///
  /// 仅放行 `sys.*`（`sys.hello` / `sys.ping` 及必要的系统方法）；其余一律由
  /// [BandRouter] 拒绝并回 `E_NOT_READY`（§3.3「交集为空 → 仅允许 `sys.*`」的推广）。
  static bool isPreReadyMethod(String method) => method.startsWith('sys.');
}

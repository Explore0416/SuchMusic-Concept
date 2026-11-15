import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// 纯 Dart Ed25519 验签（只验签，不签名），按 RFC 8032 §5.1.7 实现。
///
/// 为什么不用 pointycastle：`pointycastle` 3.9.1 的 `lib/signers/` 实际只有
/// `rsa_signer.dart` / `ecdsa_signer.dart` / `pss_signer.dart`，**没有任何
/// Ed25519 实现**（已核对本地 pub-cache 的真实文件列表，不凭记忆）。项目约束
/// 不允许新增 pub 依赖（ed25519_edwards / tweetnacl 等都用不了），因此这里
/// 直接实现「解码公钥 → 还原点 → 双标量乘 → 比较」的最小验签路径。
///
/// 性能：一次验签约 2 次 256 bit 标量乘（约 512 次点加 / 倍点），
/// 冷启动只跑一次，耗时可忽略。
///
/// 安全边界：本文件只做数学验签，**不做信任决策**；
/// 「哪些 key_id 可信」由 [RemoteClients] 的白名单决定。
class Ed25519PublicKey {
  /// 从 raw 32 字节公钥构造。
  ///
  /// 长度不为 32 时抛 [ArgumentError]（调用方负责 catch 后视为验签失败）。
  Ed25519PublicKey(Iterable<int> raw)
    : _raw = Uint8List.fromList(List<int>.from(raw)) {
    if (_raw.length != 32) {
      throw ArgumentError.value(_raw.length, 'raw', 'Ed25519 公钥必须是 32 字节');
    }
    _point = _decodePoint(_raw);
  }

  /// 从 base64（标准字母表，允许缺省 padding）构造。
  factory Ed25519PublicKey.fromBase64(String base64Text) =>
      Ed25519PublicKey(base64Decode(_normalizeBase64(base64Text)));

  final Uint8List _raw;

  /// 解码后的公钥点；公钥本身非法时为 null（此后一切验签直接失败）。
  _EdwardsPoint? _point;

  /// 公钥原始字节（32 字节，只读）。
  Uint8List get bytes => Uint8List.fromList(_raw);

  /// 对 [message] 与 64 字节 [signature] 做验签。
  ///
  /// 任何形状不合法（签名长度、S 越界、R / A 无法解码）都返回 false，
  /// **不抛异常**——网络来的数据一律按不可信处理。
  bool verify({required List<int> message, required List<int> signature}) {
    final publicPoint = _point;
    if (publicPoint == null) return false;
    if (signature.length != 64) return false;

    final signatureBytes = Uint8List.fromList(signature);
    final rBytes = signatureBytes.sublist(0, 32);
    final sBytes = signatureBytes.sublist(32, 64);

    // S 必须是 mod L 的规范编码（RFC 8032 §5.1.7 强校验）。
    final s = _fromLittleEndian(sBytes);
    if (s >= _orderL) return false;

    final rPoint = _decodePoint(rBytes);
    if (rPoint == null) return false;

    // h = SHA-512(R || A || M) mod L
    final digestSink = _BytesBuilder32();
    digestSink.add(rBytes);
    digestSink.add(_raw);
    digestSink.add(Uint8List.fromList(List<int>.from(message)));
    final h =
        _fromLittleEndian(
          Uint8List.fromList(
            crypto.sha512.convert(digestSink.takeBytes()).bytes,
          ),
        ) %
        _orderL;

    // 验签等式：[S]B == R + [h]A
    final left = _scalarMultiply(_basePoint, s);
    final right = _pointAdd(rPoint, _scalarMultiply(publicPoint, h));
    return _pointEquals(left, right);
  }

  @override
  String toString() =>
      'Ed25519PublicKey(${base64Encode(_raw).substring(0, 8)}…)';
}

/// 把 base64url / 标准 base64（可能缺 padding）统一成标准 base64 再解码。
String _normalizeBase64(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return '';
  final normalized = trimmed.replaceAll('-', '+').replaceAll('_', '/');
  final remainder = normalized.length % 4;
  if (remainder == 0) return normalized;
  return normalized + '=' * (4 - remainder);
}

/// 解码一段 base64url 文本为字节；非法时抛 [FormatException]。
Uint8List decodeBase64UrlBytes(String text) =>
    Uint8List.fromList(base64Decode(_normalizeBase64(text)));

// ── 曲线参数（edwards25519） ────────────────────────────────────

/// p = 2^255 - 19
final BigInt _fieldP = (BigInt.one << 255) - BigInt.from(19);

/// L = 2^252 + 27742317777372353535851937790883648493（子群阶）
final BigInt _orderL =
    (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');

/// d = -121665 / 121666 mod p
final BigInt _curveD = _mod(
  BigInt.from(-121665) * BigInt.from(121666).modInverse(_fieldP),
);

/// sqrt(-1) = 2^((p-1)/4) mod p，用于 x^2 无解时换另一个根。
final BigInt _sqrtMinusOne = _modPow(BigInt.two, (_fieldP - BigInt.one) >> 2);

/// 基点 B 的 x / y（RFC 8032 §5.1 标准值）。
final BigInt _baseX = BigInt.parse(
  '15112221349535400772501151409588531511454012693041857206046113283949847762202',
);
final BigInt _baseY = BigInt.parse(
  '46316835694926478169428394003475163141307993866256225615783033603165251855960',
);

/// 基点 B（扩展坐标 Z = 1，T = x*y）。
final _EdwardsPoint _basePoint = _EdwardsPoint(
  _baseX,
  _baseY,
  BigInt.one,
  _mod(_baseX * _baseY),
);

/// 群的单位元（0, 1）。
final _EdwardsPoint _identity = _EdwardsPoint(
  BigInt.zero,
  BigInt.one,
  BigInt.one,
  BigInt.zero,
);

// ── 点运算 ─────────────────────────────────────────────────────

/// 扩展扭曲爱德华兹坐标 (X : Y : Z : T)，x = X/Z, y = Y/Z, T = XY/Z。
class _EdwardsPoint {
  const _EdwardsPoint(this.x, this.y, this.z, this.t);

  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;
}

/// 点加（a = -1 的完整公式，add-2008-hwcd-3）。
_EdwardsPoint _pointAdd(_EdwardsPoint p, _EdwardsPoint q) {
  final a = _mod((p.y - p.x) * (q.y - q.x));
  final b = _mod((p.y + p.x) * (q.y + q.x));
  final c = _mod(p.t * BigInt.two * _curveD * q.t);
  final d = _mod(p.z * BigInt.two * q.z);
  final e = _mod(b - a);
  final f = _mod(d - c);
  final g = _mod(d + c);
  final h = _mod(b + a);
  return _EdwardsPoint(_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h));
}

/// 倍点（dbl-2008-hwcd，a = -1）。
_EdwardsPoint _pointDouble(_EdwardsPoint p) {
  final a = _mod(p.x * p.x);
  final b = _mod(p.y * p.y);
  final c = _mod(BigInt.two * p.z * p.z);
  final d = _mod(-a);
  final e = _mod((p.x + p.y) * (p.x + p.y) - a - b);
  final g = _mod(d + b);
  final f = _mod(g - c);
  final h = _mod(d - b);
  return _EdwardsPoint(_mod(e * f), _mod(g * h), _mod(f * g), _mod(e * h));
}

/// 标量乘（double-and-add，标量按二进制从低位到高位）。
_EdwardsPoint _scalarMultiply(_EdwardsPoint point, BigInt scalar) {
  var result = _identity;
  var addend = point;
  var k = scalar;
  while (k > BigInt.zero) {
    if (k.isOdd) result = _pointAdd(result, addend);
    addend = _pointDouble(addend);
    k >>= 1;
  }
  return result;
}

/// 射影相等：X1/Z1 == X2/Z2 且 Y1/Z1 == Y2/Z2。
bool _pointEquals(_EdwardsPoint p, _EdwardsPoint q) {
  final z1z2 = _mod(p.z * q.z);
  final x1z2 = _mod(p.x * q.z);
  final x2z1 = _mod(q.x * p.z);
  final y1z2 = _mod(p.y * q.z);
  final y2z1 = _mod(q.y * p.z);
  // 用 z1*z2 交叉相乘避免 Z 为 0 之外的极端情况（真实点 Z 不会为 0）。
  return _mod(x1z2 - x2z1) == BigInt.zero &&
      _mod(y1z2 - y2z1) == BigInt.zero &&
      z1z2 != BigInt.zero;
}

/// 从 32 字节压缩编码还原点（RFC 8032 §5.1.3）。
///
/// 返回 null 表示编码非法（y >= p、x 无解、x=0 但符号位为 1）。
_EdwardsPoint? _decodePoint(Uint8List encoded) {
  if (encoded.length != 32) return null;
  final buffer = Uint8List.fromList(encoded);
  final signBit = (buffer[31] >> 7) & 1;
  buffer[31] &= 0x7f;
  final y = _fromLittleEndian(buffer);
  if (y >= _fieldP) return null;

  // x^2 = (y^2 - 1) / (d*y^2 + 1)
  final ySquared = _mod(y * y);
  final u = _mod(ySquared - BigInt.one);
  final v = _mod(_curveD * ySquared + BigInt.one);
  if (v == BigInt.zero) return null;

  var x = _modPow(u * v.modInverse(_fieldP), (_fieldP + BigInt.from(3)) >> 3);
  if (_mod(v * x * x) != _mod(u)) {
    x = _mod(x * _sqrtMinusOne);
  }
  if (_mod(v * x * x) != _mod(u)) return null;
  if (x == BigInt.zero && signBit == 1) return null;
  if ((x.isOdd ? 1 : 0) != signBit) {
    x = _fieldP - x;
  }
  return _EdwardsPoint(x, y, BigInt.one, _mod(x * y));
}

// ── 大数辅助 ───────────────────────────────────────────────────

/// 取模并归一化到 [0, p)。
BigInt _mod(BigInt value) {
  final reduced = value % _fieldP;
  return reduced.isNegative ? reduced + _fieldP : reduced;
}

/// 模幂（快速幂）。
BigInt _modPow(BigInt base, BigInt exponent) {
  var result = BigInt.one;
  var b = _mod(base);
  var e = exponent;
  while (e > BigInt.zero) {
    if (e.isOdd) result = _mod(result * b);
    b = _mod(b * b);
    e >>= 1;
  }
  return result;
}

/// 32 字节小端 → BigInt。
BigInt _fromLittleEndian(Uint8List bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i] & 0xff);
  }
  return value;
}

/// 简单的字节累加器（避免依赖 dart:typed_data 之外的工具）。
class _BytesBuilder32 {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  void add(List<int> bytes) => _builder.add(bytes);

  Uint8List takeBytes() => _builder.takeBytes();
}

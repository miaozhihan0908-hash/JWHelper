/// Ed25519 签名校验（RFC 8032 §5.1.7），只做 verify，不做签名。
///
/// **为什么要自己写**：pointycastle 3.9 只带 ecdsa/rsa/pss，没有 ed25519；
/// 再引一个包只为验一个签名不合算。这里只用 BigInt + pointycastle 的 SHA-512，
/// 不新增任何依赖，而且能脱离 Flutter 单独跑。
///
/// 和 `sign_gate.py`（PyNaCl）互为两端：Python 签名、Dart 验签，
/// 两边跑通才算接线成功。
library;

import 'dart:typed_data';

import 'package:pointycastle/digests/sha512.dart';

/// 2^255 - 19
final BigInt _p = (BigInt.one << 255) - BigInt.from(19);

/// 群的阶 L = 2^252 + 27742317777372353535851937790883648493
final BigInt _l = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');

/// 曲线常数 d = -121665/121666 mod p
final BigInt _d =
    (BigInt.from(-121665) * BigInt.from(121666).modInverse(_p)) % _p;

/// 基点 B（y = 4/5，x 取偶数那一支）。
final BigInt _bx = BigInt.parse(
  '15112221349535400772501151409588531511454012693041857206046113283949847762202',
);
final BigInt _by = BigInt.parse(
  '46316835694926478169428394003475163141307993866256225615783033603165251855960',
);

BigInt _mod(BigInt v) => ((v % _p) + _p) % _p;

class _Point {
  final BigInt x;
  final BigInt y;
  const _Point(this.x, this.y);
}

final _Point _identity = _Point(BigInt.zero, BigInt.one);
final _Point _base = _Point(_bx, _by);

/// 仿射坐标下的点加（Ed25519 扭曲爱德华兹曲线）。
_Point _add(_Point a, _Point b) {
  final x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y;
  final t = _mod(_d * x1 * x2 % _p * y1 % _p * y2 % _p);
  final x3 = _mod(
    (x1 * y2 + x2 * y1) % _p * (BigInt.one + t).modInverse(_p) % _p,
  );
  final y3 = _mod(
    (y1 * y2 + x1 * x2) % _p * (BigInt.one - t).modInverse(_p) % _p,
  );
  return _Point(x3, y3);
}

_Point _mul(BigInt k, _Point p) {
  var r = _identity;
  var q = p;
  var kk = k % _l;
  while (kk > BigInt.zero) {
    if (kk.isOdd) r = _add(r, q);
    q = _add(q, q);
    kk = kk >> 1;
  }
  return r;
}

/// 32 字节小端 → BigInt（最高位单独取，用作 x 的符号位）。
BigInt _decodeInt(List<int> bytes) {
  var v = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    v = (v << 8) | BigInt.from(bytes[i] & 0xFF);
  }
  return v;
}

/// 从 32 字节编码解出点；非法返回 null。
_Point? _decompress(List<int> enc) {
  if (enc.length != 32) return null;
  final raw = Uint8List.fromList(enc);
  final sign = (raw[31] >> 7) & 1;
  raw[31] &= 0x7F;
  final y = _decodeInt(raw);
  if (y >= _p) return null;
  // x^2 = (y^2 - 1) / (d*y^2 + 1)
  final y2 = y * y % _p;
  final u = _mod(y2 - BigInt.one);
  final v = _mod(_d * y2 + BigInt.one);
  if (v == BigInt.zero) return null;
  final x2 = u * v.modInverse(_p) % _p;
  // sqrt：p ≡ 5 (mod 8)，先算候选根再校正
  var x = _pow(x2, (_p + BigInt.from(3)) >> 3);
  if (_mod(x * x - x2) != BigInt.zero) {
    x = _mod(x * _pow(BigInt.two, (_p - BigInt.one) >> 2));
  }
  if (_mod(x * x - x2) != BigInt.zero) return null;
  if (x == BigInt.zero && sign == 1) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _mod(-x);
  return _Point(x, y);
}

BigInt _pow(BigInt base, BigInt exp) {
  var result = BigInt.one;
  var b = _mod(base);
  var e = exp;
  while (e > BigInt.zero) {
    if (e.isOdd) result = result * b % _p;
    b = b * b % _p;
    e = e >> 1;
  }
  return result;
}

List<int> _sha512(List<int> data) =>
    SHA512Digest().process(Uint8List.fromList(data));

/// 校验 Ed25519 签名。任何长度不对、编码非法、点不合法都返回 false。
bool ed25519Verify({
  required List<int> message,
  required List<int> signature,
  required List<int> publicKey,
}) {
  if (signature.length != 64 || publicKey.length != 32) return false;
  final a = _decompress(publicKey);
  if (a == null) return false;

  final rBytes = signature.sublist(0, 32);
  final sBytes = signature.sublist(32, 64);
  final s = _decodeInt(sBytes);
  if (s >= _l) return false;

  final rPoint = _decompress(rBytes);
  if (rPoint == null) return false;

  final k = _decodeInt(_sha512([...rBytes, ...publicKey, ...message])) % _l;

  final lhs = _mul(s, _base);
  final rhs = _add(rPoint, _mul(k, a));
  return lhs.x == rhs.x && lhs.y == rhs.y;
}

/// `"42881F0C…"` → 32 字节。长度不是偶数、含非法字符时抛 [FormatException]。
Uint8List hexToBytes(String hex) {
  final clean = hex.trim();
  if (clean.length.isOdd) {
    throw const FormatException('hex 长度必须是偶数');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

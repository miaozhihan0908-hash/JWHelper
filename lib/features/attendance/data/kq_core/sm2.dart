/// SM2 加解密（GB/T 32918），C1C3C2 模式，与前端 sm-crypto（mode=1）一致。
/// 密文传输格式：04 || X(32B) || Y(32B) || C3(32B) || C2。
library;

import 'dart:math';
import 'dart:typed_data';

import 'sm3.dart';

final BigInt sm2P = BigInt.parse(
    'FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFF',
    radix: 16);
final BigInt _a = BigInt.parse(
    'FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000FFFFFFFFFFFFFFFC',
    radix: 16);
// SM2 曲线参数 b（校验证书点时用，此处保留常量以便核对参数）
// ignore: unused_element
final BigInt _b = BigInt.parse(
    '28E9FA9E9D9F5E344D5A9E4BCF6509A7F39789F515AB8F92DDBCBD414D940E93',
    radix: 16);
final BigInt sm2N = BigInt.parse(
    'FFFFFFFEFFFFFFFFFFFFFFFFFFFFFFFF7203DF6B21C6052B53BBF40939D54123',
    radix: 16);
final BigInt _gx = BigInt.parse(
    '32C4AE2C1F1981195F9904466A39C9948FE30BBFF2660BE1715A4589334C74C7',
    radix: 16);
final BigInt _gy = BigInt.parse(
    'BC3736A2F4F6779C59BDCEE36B692153D0A9877CC62A474002DF32E52139F0A0',
    radix: 16);

/// 仿射点，null 表示无穷远点。
class EcPoint {
  final BigInt x;
  final BigInt y;
  const EcPoint(this.x, this.y);
}

final EcPoint sm2G = EcPoint(_gx, _gy);

EcPoint? _add(EcPoint? p1, EcPoint? p2) {
  if (p1 == null) return p2;
  if (p2 == null) return p1;
  if (p1.x == p2.x && (p1.y + p2.y) % sm2P == BigInt.zero) return null;
  BigInt lam;
  if (p1.x == p2.x) {
    final num = (BigInt.from(3) * p1.x * p1.x + _a) % sm2P;
    final den = (BigInt.two * p1.y) % sm2P;
    lam = num * den.modInverse(sm2P) % sm2P;
  } else {
    final num = (p2.y - p1.y) % sm2P;
    final den = (p2.x - p1.x) % sm2P;
    lam = num * den.modInverse(sm2P) % sm2P;
  }
  final x3 = (lam * lam - p1.x - p2.x) % sm2P;
  final y3 = (lam * (p1.x - x3) - p1.y) % sm2P;
  return EcPoint((x3 + sm2P) % sm2P, (y3 + sm2P) % sm2P);
}

EcPoint? _mul(BigInt k, EcPoint p) {
  EcPoint? r;
  var base = p;
  var kk = k;
  while (kk > BigInt.zero) {
    if (kk.isOdd) r = _add(r, base);
    base = _add(base, base)!;
    kk = kk >> 1;
  }
  return r;
}

BigInt _toBigInt(List<int> bytes) => bytes.isEmpty
    ? BigInt.zero
    : BigInt.parse(bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
        radix: 16);

Uint8List _be(BigInt v, [int len = 32]) {
  final s = v.toRadixString(16).padLeft(len * 2, '0');
  final out = Uint8List(len);
  for (int i = 0; i < len; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

List<int> _kdf(List<int> z, int klen) {
  final out = <int>[];
  var ct = 1;
  while (out.length < klen) {
    final input = <int>[
      ...z,
      (ct >> 24) & 0xFF,
      (ct >> 16) & 0xFF,
      (ct >> 8) & 0xFF,
      ct & 0xFF,
    ];
    out.addAll(sm3(input));
    ct++;
  }
  return out.sublist(0, klen);
}

/// 由私钥推导公钥（未压缩，04 前缀，130 个十六进制字符）。
String derivePublicKey(String privHex) {
  final d = BigInt.parse(privHex, radix: 16);
  final p = _mul(d, sm2G)!;
  return '04${_be(p.x).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}'
      '${_be(p.y).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
}

EcPoint _normPub(String pubHex) {
  var h = pubHex.trim();
  if (h.startsWith('04')) h = h.substring(2);
  if (h.length > 128) h = h.substring(h.length - 128);
  return EcPoint(
      BigInt.parse(h.substring(0, 64), radix: 16),
      BigInt.parse(h.substring(64, 128), radix: 16));
}

final Random _rng = Random.secure();

BigInt _randK() {
  final bytes = Uint8List(32);
  for (int i = 0; i < 32; i++) {
    bytes[i] = _rng.nextInt(256);
  }
  var k = _toBigInt(bytes) % (sm2N - BigInt.one) + BigInt.one;
  return k;
}

/// 加密，返回 "04"+X+Y+C3+C2 的十六进制串。
String encrypt(List<int> msg, String pubHex) {
  final pub = _normPub(pubHex);
  while (true) {
    final k = _randK();
    final c1 = _mul(k, sm2G)!;
    final s = _mul(k, pub)!;
    final t = _kdf([..._be(s.x), ..._be(s.y)], msg.length);
    var allZero = true;
    for (final b in t) {
      if (b != 0) {
        allZero = false;
        break;
      }
    }
    if (allZero) continue;
    final c2 = List<int>.generate(msg.length, (i) => msg[i] ^ t[i]);
    final c3 = sm3([..._be(s.x), ...msg, ..._be(s.y)]);
    return '04${hex(_be(c1.x))}${hex(_be(c1.y))}${hex(c3)}${hex(c2)}';
  }
}

/// 解密，输入 "04"+X+Y+C3+C2（04 可省略）。
List<int> decrypt(String cipherHex, String privHex) {
  var h = cipherHex.trim();
  if (h.startsWith('04')) h = h.substring(2);
  if (h.length < 192) throw FormatException('密文太短: ${h.length}');
  final c1 = EcPoint(BigInt.parse(h.substring(0, 64), radix: 16),
      BigInt.parse(h.substring(64, 128), radix: 16));
  final c3 = <int>[
    for (int i = 0; i < 32; i++)
      int.parse(h.substring(128 + i * 2, 130 + i * 2), radix: 16)
  ];
  final body = h.substring(192);
  final c2 = <int>[
    for (int i = 0; i + 1 < body.length; i += 2)
      int.parse(body.substring(i, i + 2), radix: 16)
  ];
  final d = BigInt.parse(privHex, radix: 16);
  final s = _mul(d, c1)!;
  final t = _kdf([..._be(s.x), ..._be(s.y)], c2.length);
  final msg = List<int>.generate(c2.length, (i) => c2[i] ^ t[i]);
  final check = sm3([..._be(s.x), ...msg, ..._be(s.y)]);
  for (int i = 0; i < 32; i++) {
    if (check[i] != c3[i]) throw StateError('SM2 校验失败(C3 不匹配)');
  }
  return msg;
}

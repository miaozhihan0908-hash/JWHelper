/// SM3 摘要（GB/T 32905），纯 Dart 实现。
library;

import 'dart:typed_data';

const List<int> _iv = [
  0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
  0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
];

const int _m32 = 0xFFFFFFFF;

int _rotl(int x, int n) {
  n %= 32;
  x &= _m32;
  if (n == 0) return x;
  return (((x << n) & _m32) | (x >> (32 - n))) & _m32;
}

int _p0(int x) => (x ^ _rotl(x, 9) ^ _rotl(x, 17)) & _m32;
int _p1(int x) => (x ^ _rotl(x, 15) ^ _rotl(x, 23)) & _m32;

int _ff(int x, int y, int z, int j) =>
    j < 16 ? ((x ^ y ^ z) & _m32) : ((x & y) | (x & z) | (y & z)) & _m32;

int _gg(int x, int y, int z, int j) =>
    j < 16 ? ((x ^ y ^ z) & _m32) : ((x & y) | ((~x) & _m32 & z)) & _m32;

/// 计算 SM3 摘要，返回 32 字节。
Uint8List sm3(List<int> data) {
  final bitLen = data.length * 8;
  final msg = <int>[...data, 0x80];
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  for (int i = 7; i >= 0; i--) {
    msg.add((bitLen >> (i * 8)) & 0xFF);
  }

  var v = List<int>.from(_iv);
  for (int off = 0; off < msg.length; off += 64) {
    final w = List<int>.filled(68, 0);
    for (int j = 0; j < 16; j++) {
      final b = off + j * 4;
      w[j] = (msg[b] << 24) | (msg[b + 1] << 16) | (msg[b + 2] << 8) | msg[b + 3];
    }
    for (int j = 16; j < 68; j++) {
      w[j] = (_p1(w[j - 16] ^ w[j - 9] ^ _rotl(w[j - 3], 15)) ^
              _rotl(w[j - 13], 7) ^
              w[j - 6]) &
          _m32;
    }
    final w1 = List<int>.filled(64, 0);
    for (int j = 0; j < 64; j++) {
      w1[j] = (w[j] ^ w[j + 4]) & _m32;
    }

    var a = v[0], b = v[1], c = v[2], d = v[3];
    var e = v[4], f = v[5], g = v[6], h = v[7];

    for (int j = 0; j < 64; j++) {
      final t = j < 16 ? 0x79CC4519 : 0x7A879D8A;
      final a12 = _rotl(a, 12);
      final ss1 = _rotl((a12 + e + _rotl(t, j)) & _m32, 7);
      final ss2 = (ss1 ^ a12) & _m32;
      final tt1 = (_ff(a, b, c, j) + d + ss2 + w1[j]) & _m32;
      final tt2 = (_gg(e, f, g, j) + h + ss1 + w[j]) & _m32;
      d = c;
      c = _rotl(b, 9);
      b = a;
      a = tt1;
      h = g;
      g = _rotl(f, 19);
      f = e;
      e = _p0(tt2);
    }

    v = [
      (v[0] ^ a) & _m32,
      (v[1] ^ b) & _m32,
      (v[2] ^ c) & _m32,
      (v[3] ^ d) & _m32,
      (v[4] ^ e) & _m32,
      (v[5] ^ f) & _m32,
      (v[6] ^ g) & _m32,
      (v[7] ^ h) & _m32,
    ];
  }

  final out = Uint8List(32);
  for (int i = 0; i < 8; i++) {
    out[i * 4] = (v[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (v[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (v[i] >> 8) & 0xFF;
    out[i * 4 + 3] = v[i] & 0xFF;
  }
  return out;
}

/// 十六进制小写串。
String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

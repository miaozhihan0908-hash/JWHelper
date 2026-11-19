/// 授权码的规范化与指纹。
///
/// 码长这个样子（25 位，Crockford Base32，去掉了容易看错的 I L O U）：
///
/// ```text
/// K7M2Q-9XB3T-VRD8N-HW4PJ-6CYZF
/// ```
///
/// 这里**只做两件事**：把人手抄进来的东西规整成标准形态，再算一个指纹。
/// 不做解码、不做校验位——两套语言各写一份编解码，迟早会漂移；输错一位就
/// 报"无效授权码"已经够清楚了。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/digests/sha256.dart';

/// Crockford Base32：没有 I、L、O、U。
const String licenceAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// 码的字符数（5 组 × 5 位 = 125 bit）。
const int licenceKeyLength = 25;

/// 每组的位数。
const int _groupSize = 5;

/// 把用户输入规整成标准形态；不像一个码就返回 null。
///
/// * 全角字符先转半角（手机中文输入法很容易打出全角）
/// * 去掉横杠、空格、换行等一切非字母数字
/// * 转大写
/// * `O→0`、`I→1`、`L→1`（Crockford 规定的易混映射）
String? normalizeLicenceKey(String raw) {
  if (raw.isEmpty) return null;
  final buf = StringBuffer();
  for (final rune in raw.runes) {
    var c = rune;
    // 全角 ASCII（！～）转半角
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    if (c == 0x3000) c = 0x20; // 全角空格
    final ch = String.fromCharCode(c).toUpperCase();
    if (ch.isEmpty) continue;
    final code = ch.codeUnitAt(0);
    final isDigit = code >= 0x30 && code <= 0x39;
    final isUpper = code >= 0x41 && code <= 0x5A;
    if (!isDigit && !isUpper) continue; // 横杠、空格、标点全部丢弃
    switch (ch) {
      case 'O':
        buf.write('0');
      case 'I':
      case 'L':
        buf.write('1');
      default:
        buf.write(ch);
    }
  }
  final out = buf.toString();
  if (out.length != licenceKeyLength) return null;
  // 每个字符都必须在字母表里（U 之类的属于抄错）
  for (var i = 0; i < out.length; i++) {
    if (!licenceAlphabet.contains(out[i])) return null;
  }
  return out;
}

/// 码的指纹：sha256 前 16 位十六进制大写。
///
/// 公开的配置文件里只存这个值。100 bit 的随机空间，从指纹反推不出码。
String kidOf(String normalizedKey) {
  final digest = SHA256Digest().process(
    Uint8List.fromList(utf8.encode(normalizedKey)),
  );
  final buf = StringBuffer();
  for (var i = 0; i < 8; i++) {
    buf.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString().toUpperCase();
}

/// 顺手判断一串输入是不是一个形状正确的码（不做表查询）。
bool looksLikeLicenceKey(String raw) => normalizeLicenceKey(raw) != null;

/// 展示用：把规整后的码切成 5 组，每组 5 位。
String formatLicenceKey(String normalizedKey) {
  if (normalizedKey.length != licenceKeyLength) return normalizedKey;
  final parts = <String>[];
  for (var i = 0; i < normalizedKey.length; i += _groupSize) {
    final end = (i + _groupSize).clamp(0, normalizedKey.length);
    parts.add(normalizedKey.substring(i, end));
  }
  return parts.join('-');
}

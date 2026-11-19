import 'package:flutter_test/flutter_test.dart';
import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

/// 黄金向量：`kq/issue_key.py` 里也有同一对，两边必须一模一样。
/// 改动任何一侧的算法（字母表、规范化、哈希长度）都会让这条测试红掉。
const String _goldenKey = 'K7M2Q9XB3TVRD8NHW4PJ6CYZF';
const String _goldenKid = '2FA266553D7EAEBA';

void main() {
  test('黄金向量：同一个码算出同一个指纹', () {
    final norm = normalizeLicenceKey(_goldenKey);
    expect(norm, _goldenKey);
    expect(kidOf(norm!), _goldenKid);
  });

  test('横杠、空格、换行都不影响', () {
    expect(normalizeLicenceKey('k7m2q-9xb3t-vrd8n-hw4pj-6cyzf'), _goldenKey);
    expect(normalizeLicenceKey(' K7M2Q 9XB3T VRD8N HW4PJ 6CYZF '), _goldenKey);
    expect(normalizeLicenceKey('K7M2Q\n9XB3T\tVRD8N-HW4PJ-6CYZF'), _goldenKey);
  });

  test('全角字符转半角', () {
    expect(
      normalizeLicenceKey('Ｋ７Ｍ２Ｑ－９ＸＢ３Ｔ－ＶＲＤ８Ｎ－ＨＷ４ＰＪ－６ＣＹＺＦ'),
      _goldenKey,
    );
  });

  test('易混字符按 Crockford 规则映射', () {
    // 末尾 O 会变成 0，I/L 会变成 1
    expect(normalizeLicenceKey('K7M2Q9XB3TVRD8NHW4PJ6CYZO'), isNotNull);
    expect(normalizeLicenceKey('K7M2Q9XB3TVRD8NHW4PJ6CYZO')!.endsWith('0'), isTrue);
    expect(normalizeLicenceKey('K7M2Q9XB3TVRD8NHW4PJ6CYZI')!.endsWith('1'), isTrue);
    expect(normalizeLicenceKey('K7M2Q9XB3TVRD8NHW4PJ6CYZL')!.endsWith('1'), isTrue);
  });

  test('形状不对的直接判无效', () {
    expect(normalizeLicenceKey(''), isNull);
    expect(normalizeLicenceKey('K7M2Q'), isNull); // 太短
    expect(normalizeLicenceKey('${_goldenKey}0'), isNull); // 太长
    expect(normalizeLicenceKey('K7M2Q9XB3TVRD8NHW4PJ6CYZU'), isNull); // U 不在字母表
    expect(looksLikeLicenceKey(_goldenKey), isTrue);
    expect(looksLikeLicenceKey('hello'), isFalse);
  });

  test('展示时切成 5 组', () {
    expect(formatLicenceKey(_goldenKey), 'K7M2Q-9XB3T-VRD8N-HW4PJ-6CYZF');
    expect(formatLicenceKey('短码'), '短码');
  });

  test('指纹长度固定 16 位大写十六进制', () {
    final kid = kidOf(_goldenKey);
    expect(kid.length, 16);
    expect(RegExp(r'^[0-9A-F]{16}$').hasMatch(kid), isTrue);
  });
}

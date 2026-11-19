import 'package:flutter_test/flutter_test.dart';
import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

/// 生产公钥。私钥在 kq/gate_private.key，只在本机和 GitHub Secret 里。
const String _publicKeyHex =
    '42881F0C923B6F35EC432258EE83E8861DE73332CFCC837489246F3BE6529D8A';

GateClient _client() => GateClient(
  appId: 'jwhelper',
  publicKeyHex: _publicKeyHex,
  mirrors: const <String>[],
  readCache: () async => '',
  writeCache: (_) async {},
);

/// 真签名样本（kq/sign_gate.py 生成）。字段顺序和缩进都故意打乱过：
/// 验签只认「去掉 sig、所有层级按 key 排序、无空格」的紧凑 JSON。
const String _signed = r'''
{
    "sig": "0D0kDgZRhxZEvKEKyncv30j3MkTgErOZ03jF6b9p0ej+ahP9yZMAv3IX0/Sdzj26G6+E9JYhdyONNYv8Wg6DBQ==",
    "expiresAt": "2036-11-16T08:04:33Z",
    "apps": {
        "jwhelper": {
            "killAll": true,
            "features": {
                "autoSign": false,
                "manualSign": true
            },
            "notice": {
                "title": "这版已停用",
                "body": "第一行\n第二行",
                "confirm": "好吧"
            }
        }
    },
    "v": 2,
    "issuedAt": "2026-11-18T08:04:33Z"
}
''';

/// 同一把key签的、给另一个 App 的配置。
const String _otherApp = r'''
{
    "sig": "XbP7jBAgJU+jNC24zE+L+NkzMn390Cg9fiYB4L7N7RFWcs/5plMMa2fEcerKUc7LZx6SAT24mgjU2IZHtFHKDA==",
    "expiresAt": "2036-11-16T08:04:33Z",
    "apps": {
        "otherapp": {
            "killAll": false,
            "features": {
                "autoSign": false
            }
        }
    },
    "v": 2,
    "issuedAt": "2026-11-18T08:04:33Z"
}
''';

void main() {
  test('真签名能验过，字段全部解析出来', () {
    final state = _client().parseSigned(_signed);
    expect(state, isNotNull);
    expect(state!.flags.killAll, isTrue);
    expect(state.flags.on('autoSign'), isFalse);
    // 配置里手动签到本身是开的，但总闸拉着，所以对外一律是关。
    expect(state.flags.features['manualSign'], isTrue);
    expect(state.flags.on('manualSign'), isFalse);
    expect(state.notice.title, '这版已停用');
    expect(state.notice.body, '第一行\n第二行');
    expect(state.notice.confirm, '好吧');
    expect(state.issuedAt, isNotNull);
    expect(state.expiresAt, isNotNull);
  });

  test('改一个字节就整份丢弃', () {
    final broken = _signed.replaceFirst('"killAll": true', '"killAll": false');
    expect(broken, isNot(_signed));
    expect(_client().parseSigned(broken), isNull);
  });

  test('没有签名直接丢弃', () {
    final noSig = _signed.replaceFirst(RegExp(r'"sig": "[^"]*"'), '"sig": ""');
    expect(noSig, isNot(_signed));
    expect(_client().parseSigned(noSig), isNull);
  });

  test('给别的 App 的配置不认', () {
    final state = _client().parseSigned(_otherApp);
    expect(state, isNull);
  });

  test('未声明的功能默认开，killAll 压过一切', () {
    expect(const GateFlags().on('whatever'), isTrue);
    const killed = GateFlags(features: {'autoSign': true}, killAll: true);
    expect(killed.on('autoSign'), isFalse);
    const sparse = GateFlags(features: {'autoSign': false});
    expect(sparse.on('autoSign'), isFalse);
    expect(sparse.on('manualSign'), isTrue);
  });

  test('文案缺字段就落回默认值', () {
    final n = GateNotice.fromJson({'title': '只给标题'});
    expect(n.title, '只给标题');
    expect(n.body, GateNotice.fallback.body);
    expect(n.confirm, GateNotice.fallback.confirm);
    expect(n.isCustom, isTrue);
    expect(GateNotice.fromJson(const {}).isCustom, isFalse);
  });

  test('状态缓存能原样绕一圈', () {
    final state = _client().parseSigned(_signed)!;
    final again = GateState.fromJson(state.toJson());
    expect(again.flags.killAll, state.flags.killAll);
    expect(again.notice.title, state.notice.title);
    expect(again.issuedAt, state.issuedAt);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

const String _publicKeyHex =
    '42881F0C923B6F35EC432258EE83E8861DE73332CFCC837489246F3BE6529D8A';

GateClient _client() => GateClient(
  appId: 'jwhelper',
  publicKeyHex: _publicKeyHex,
  mirrors: const <String>[],
  readCache: () async => '',
  writeCache: (_) async {},
  defaultLicencePolicy: const GateLicencePolicy(
    required: true,
    features: {'autoSign', 'manualSign', 'forceSign'},
  ),
);

/// 真签名样本：带 licences / licence / allowedStudents 三块。
const String _signed = r'''
{
    "sig": "nFzkenaAaOLXPigtoWSllegISAYAgcwgvGXNovRfEzP2ofSPlwakKNO1EPFookiSzvNwVkxJPlKtDZ6ud6PLCQ==",
    "apps": {
        "jwhelper": {
            "killAll": false,
            "features": {
                "autoSign": true,
                "manualSign": true
            },
            "licence": {
                "required": true,
                "features": [
                    "autoSign",
                    "manualSign",
                    "forceSign"
                ]
            },
            "allowedStudents": [
                "A7E77B85EBF12034903A2F686935C50D"
            ],
            "licences": [
                {
                    "kid": "2FA266553D7EAEBA",
                    "days": 7,
                    "sub": "202608140075",
                    "iat": "2026-11-18T09:13:21Z",
                    "note": "测试"
                },
                {
                    "kid": "F2A13C7BD4333F4D",
                    "days": 0,
                    "sub": "*"
                },
                {
                    "kid": "AAAABBBBCCCCDDDD",
                    "days": 30,
                    "sub": "999",
                    "strict": true
                }
            ]
        }
    },
    "expiresAt": "2036-11-16T09:13:21Z",
    "v": 2,
    "issuedAt": "2026-11-18T09:13:21Z"
}
''';

void main() {
  test('签名配置里的授权表能解析出来', () {
    final state = _client().parseSigned(_signed);
    expect(state, isNotNull);
    expect(state!.licences.length, 3);

    final first = state.licences.first;
    expect(first.kid, '2FA266553D7EAEBA');
    expect(first.days, 7);
    expect(first.sub, '202608140075');
    expect(first.forever, isFalse);

    final forever = state.licenceOf('F2A13C7BD4333F4D');
    expect(forever, isNotNull);
    expect(forever!.forever, isTrue);
    expect(forever.sub, '*');

    final strict = state.licenceOf('AAAABBBBCCCCDDDD');
    expect(strict!.strict, isTrue);
    expect(strict.days, 30);

    expect(state.licencePolicy.required, isTrue);
    expect(state.licencePolicy.needs('autoSign'), isTrue);
    expect(state.licencePolicy.needs('manualSign'), isTrue);
    expect(state.licencePolicy.needs('forceSign'), isTrue);
    expect(state.licencePolicy.needs('selfTest'), isFalse);

    expect(state.allowedStudents.length, 1);
    expect(state.allowedStudents.first, 'A7E77B85EBF12034903A2F686935C50D');
    expect(state.hasNoConfig, isFalse);
  });

  test('改一个字，整份作废（授权表也跟着作废）', () {
    final broken = _signed.replaceFirst('"days": 0', '"days": 36500');
    expect(broken, isNot(_signed));
    expect(_client().parseSigned(broken), isNull);
  });

  test('不传策略时按宿主给的默认（fail-closed 三档全要码）', () {
    final client = GateClient(
      appId: 'jwhelper',
      publicKeyHex: _publicKeyHex,
      mirrors: const <String>[],
      readCache: () async => '',
      writeCache: (_) async {},
    );
    final state = client.parseSigned(_signed);
    expect(state, isNotNull);
    // 签名文档里写了 licence，所以用文档里的；文档没写时才会用构造参数。
    expect(state!.licencePolicy.required, isTrue);
  });
}

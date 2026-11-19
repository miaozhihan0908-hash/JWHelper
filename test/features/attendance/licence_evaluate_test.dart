import 'package:flutter_test/flutter_test.dart';
import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

const String _kid = '2FA266553D7EAEBA';
const String _student = '202608140075';

GateState _gate(List<GateLicence> list, {String source = 'cache'}) => GateState(
  licences: list,
  licencePolicy: const GateLicencePolicy(
    required: true,
    features: {'autoSign', 'manualSign', 'forceSign'},
  ),
  source: source,
  issuedAt: DateTime.utc(2026, 11, 19),
);

LicenceEvaluation _eval({
  required GateState gate,
  required LicenceActivation? act,
  String studentNo = _student,
  required DateTime now,
}) => evaluateLicence(
  gate: gate,
  activation: act,
  studentNo: studentNo,
  now: now,
);

void main() {
  final now = DateTime.utc(2026, 11, 19, 12);
  final sevenDay = GateLicence(
    kid: _kid,
    days: 7,
    sub: _student,
    iat: DateTime.utc(2026, 11, 19),
  );
  final activated = LicenceActivation(
    kid: _kid,
    activatedAt: now,
    lastSeenAt: now,
  );

  test('从没拉到配置 → noTable（宁可锁着也不放行）', () {
    final e = _eval(gate: GateState.open, act: null, now: now);
    expect(e.status, LicenceStatus.noTable);
    expect(e.ok, isFalse);
  });

  test('有配置但没激活 → none', () {
    final e = _eval(gate: _gate([sevenDay]), act: null, now: now);
    expect(e.status, LicenceStatus.none);
    expect(e.label, '未激活');
  });

  test('7 天码：刚激活正好剩 7 天', () {
    final e = _eval(gate: _gate([sevenDay]), act: activated, now: now);
    expect(e.status, LicenceStatus.active);
    expect(e.daysLeft, 7);
    expect(e.expiresAt, now.add(const Duration(days: 7)));
    expect(e.ok, isTrue);
  });

  test('7 天码：差 1 小时算剩 1 天，不是 0 天', () {
    final e = _eval(
      gate: _gate([sevenDay]),
      act: activated,
      now: now.add(const Duration(days: 6, hours: 23)),
    );
    expect(e.daysLeft, 1);
  });

  test('7 天码：满 7 天即过期', () {
    final e = _eval(
      gate: _gate([sevenDay]),
      act: activated,
      now: now.add(const Duration(days: 7)),
    );
    expect(e.status, LicenceStatus.expired);
    expect(e.ok, isFalse);
  });

  test('绑了别的学号 → wrongSub', () {
    final e = _eval(
      gate: _gate([sevenDay]),
      act: activated,
      studentNo: '111111111111',
      now: now,
    );
    expect(e.status, LicenceStatus.wrongSub);
  });

  test('作者从名单里删掉 → unknown（撤销）', () {
    final e = _eval(gate: _gate(const []), act: activated, now: now);
    expect(e.status, LicenceStatus.unknown);
  });

  test('永久码永远有效', () {
    final gate = _gate([
      GateLicence(kid: _kid, days: 0, sub: _student, iat: DateTime.utc(2020)),
    ]);
    final e = _eval(gate: gate, act: activated, now: DateTime.utc(2040, 1, 1));
    expect(e.status, LicenceStatus.forever);
    expect(e.ok, isTrue);
    expect(e.label, '永久授权');
  });

  test('系统时间回拨 → clockBack', () {
    final rolled = LicenceActivation(
      kid: _kid,
      activatedAt: now,
      lastSeenAt: now.add(const Duration(days: 10)),
    );
    final e = _eval(gate: _gate([sevenDay]), act: rolled, now: now);
    expect(e.status, LicenceStatus.clockBack);
    expect(e.ok, isFalse);
  });

  test('strict 的码从签发那天算，不从激活算', () {
    final gate = _gate([
      GateLicence(
        kid: _kid,
        days: 7,
        sub: '*',
        iat: DateTime.utc(2026, 11, 1),
        strict: true,
      ),
    ]);
    final e = _eval(
      gate: gate,
      act: LicenceActivation(
        kid: _kid,
        activatedAt: DateTime.utc(2026, 10, 1),
        lastSeenAt: DateTime.utc(2026, 10, 1),
      ),
      now: DateTime.utc(2026, 11, 10),
    );
    expect(e.status, LicenceStatus.expired);
  });

  test('sub 为 * 时不限学号', () {
    final gate = _gate([
      GateLicence(kid: _kid, days: 30, sub: '*', iat: DateTime.utc(2026)),
    ]);
    final e = _eval(gate: gate, act: activated, studentNo: '999', now: now);
    expect(e.status, LicenceStatus.active);
  });

  test('只有配置点名的那几个功能才要授权', () {
    final gate = _gate([sevenDay]);
    expect(gate.licencePolicy.needs('autoSign'), isTrue);
    expect(gate.licencePolicy.needs('manualSign'), isTrue);
    expect(gate.licencePolicy.needs('forceSign'), isTrue);
    expect(gate.licencePolicy.needs('selfTest'), isFalse);
  });

  test('快照能原样存进缓存再读回来', () {
    final gate = _gate([sevenDay, GateLicence(kid: 'AAAABBBBCCCCDDDD', days: 0)]);
    final again = GateState.fromJson(gate.toJson());
    expect(again.licences.length, 2);
    expect(again.licences.first.kid, _kid);
    expect(again.licences.first.days, 7);
    expect(again.licences.first.sub, _student);
    expect(again.licencePolicy.required, isTrue);
    expect(again.licencePolicy.features.length, 3);
  });
}

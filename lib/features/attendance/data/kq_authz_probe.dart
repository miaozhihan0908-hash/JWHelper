import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_core/authz_judge.dart';
import 'package:JWHelper/features/attendance/data/kq_core/kq_client.dart';

/// 一条探测结果。
class KqProbeResult {
  const KqProbeResult({
    required this.name,
    required this.endpoint,
    required this.http,
    required this.code,
    required this.msg,
    required this.verdict,
    this.note = '',
  });

  final String name;
  final String endpoint;
  final int? http;
  final String code;
  final String msg;

  /// 开 / 关 / 不明
  final String verdict;
  final String note;

  bool get open => verdict == '开';

  String get line {
    final h = http == null ? '-' : '$http';
    final c = code.isEmpty ? '-' : code;
    return '$verdict  $name  HTTP=$h code=$c ${msg.isEmpty ? '' : '· $msg'}';
  }
}

/// 判断"学生身份能不能调教师端接口"，全部实验都不改动任何记录。
///
/// 三个只读探测看数据会不会泄露，一个写探测故意用**不存在的记录 id**：
/// 服务端若先校验角色，会回"权限不足"；若先查数据，会回"记录不存在"——
/// 后者说明角色校验这一关是通的，真实 id 大概率能改。
class KqAuthzProbe {
  KqAuthzProbe({required this.cookie, required this.studentNo, this.onLog});

  final String cookie;
  final String studentNo;
  final void Function(String message)? onLog;

  KqClient? _client;
  KqClient get _c => _client ??= KqClient(cookie: cookie);

  void close() => _client?.close();

  static const String _ghostId = '00000000000000000000000000dead01';

  Future<List<KqProbeResult>> run({required String paikeId}) async {
    final out = <KqProbeResult>[];
    await _log('=== 权限探测开始 paikeId=$paikeId ===');

    out.add(await _get(
      name: '考勤名单',
      endpoint: 'GET /studentSign/checkList',
      call: () => _c.checkList(paikeId),
      note: '返回名单 = 能读到同学的考勤数据',
    ));

    out.add(await _get(
      name: '考勤记录',
      endpoint: 'GET /studentPaike/findKqAttendanceList',
      call: () => _c.findKqAttendanceList(paikeId),
      note: '返回四类列表 = 能读到历史记录与 signId',
    ));

    out.add(await _post(
      name: '改结果(幽灵id)',
      endpoint: 'POST /studentPaike/updateKqAttendanceResult',
      call: () => _c.updateKqAttendanceResult(_ghostId, '1'),
      note: '回"记录不存在"= 角色已放行；回"权限/授权"= 门关着',
    ));

    out.add(await _post(
      name: '代签到(幽灵id)',
      endpoint: 'POST /studentSign/signByTeacher',
      call: () => _c.signByTeacher({
        'id': _ghostId,
        'teacherNo': studentNo,
        'signInGps': '117.000000,36.000000',
      }),
      note: '同上',
    ));

    for (final r in out) {
      await _log('  ${r.line}${r.note.isEmpty ? '' : '  (${r.note})'}');
    }
    final open = out.where((r) => r.open).length;
    await _log('=== 探测结束：$open/${out.length} 条显示门是开的 ===');
    return out;
  }

  Future<KqProbeResult> _get({
    required String name,
    required String endpoint,
    required Future<dynamic> Function() call,
    String note = '',
  }) async {
    try {
      final resp = await call();
      return _toResult(name, endpoint, resp, note);
    } catch (e) {
      return KqProbeResult(
        name: name,
        endpoint: endpoint,
        http: _c.http.lastStatus,
        code: '',
        msg: '异常 $e',
        verdict: '不明',
        note: note,
      );
    }
  }

  Future<KqProbeResult> _post({
    required String name,
    required String endpoint,
    required Future<dynamic> Function() call,
    String note = '',
  }) async {
    try {
      final resp = await call();
      return _toResult(name, endpoint, resp, note);
    } catch (e) {
      return KqProbeResult(
        name: name,
        endpoint: endpoint,
        http: _c.http.lastStatus,
        code: '',
        msg: '异常 $e',
        verdict: '不明',
        note: note,
      );
    }
  }

  KqProbeResult _toResult(
    String name,
    String endpoint,
    dynamic resp,
    String note,
  ) {
    final http = _c.http.lastStatus;
    final code = resp is Map ? '${resp['code'] ?? ''}' : '';
    final msg = resp is Map
        ? '${resp['msg'] ?? resp['message'] ?? ''}'
        : _trim('$resp');
    return KqProbeResult(
      name: name,
      endpoint: endpoint,
      http: http,
      code: code,
      msg: _trim(msg),
      verdict: judgeProbe(http: http, code: code, msg: msg),
      note: note,
    );
  }

  static String _trim(String s) {
    var t = s.trim();
    if (t.length > 120) t = '${t.substring(0, 120)}…';
    return t;
  }

  Future<void> _log(String m) async {
    await KqAutoStore.appendLog(m);
    onLog?.call(m);
  }
}

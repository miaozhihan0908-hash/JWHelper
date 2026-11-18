import 'dart:async';

import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_core/kq_client.dart';

/// 考勤结果的异常标记。接口里是逗号串：1=迟到 2=早退 3=旷课。
enum KqFlag {
  late('1', '迟到'),
  early('2', '早退'),
  absenteeism('3', '旷课');

  const KqFlag(this.code, this.label);
  final String code;
  final String label;

  static KqFlag? byCode(String c) {
    for (final f in KqFlag.values) {
      if (f.code == c) return f;
    }
    return null;
  }
}

/// 一条考勤记录。字段名照抄服务端返回，缺的留空。
class KqAttendanceRecord {
  const KqAttendanceRecord({
    required this.signId,
    required this.studentNo,
    required this.studentName,
    required this.courseName,
    required this.paikeId,
    required this.category,
    required this.date,
    required this.classTime,
    required this.signInTime,
    required this.signOutTime,
    required this.raw,
  });

  final String signId;
  final String studentNo;
  final String studentName;
  final String courseName;
  final String paikeId;

  /// 请假 / 正常 / 异常 / 待考勤
  final String category;
  final String date;
  final String classTime;
  final String signInTime;
  final String signOutTime;
  final Map<String, dynamic> raw;

  bool get hasSignId => signId.isNotEmpty;

  String get title => classTime.isEmpty ? courseName : '$courseName $classTime';

  String get subtitle {
    final parts = <String>[category];
    if (date.isNotEmpty) parts.add(date);
    if (signInTime.isNotEmpty) parts.add('签 $signInTime');
    if (signOutTime.isNotEmpty) parts.add('退 $signOutTime');
    return parts.join(' · ');
  }

  @override
  String toString() => '[$category] $courseName $classTime 签到=$signInTime 签退=$signOutTime';
}

class KqApplyResult {
  const KqApplyResult({
    required this.ok,
    required this.message,
    this.confirmed = false,
  });
  final bool ok;
  final String message;
  final bool confirmed;

  @override
  String toString() => message;
}

/// 一次按天拉取的结果：记录 + 每门课的服务端回话。
class KqDayFetch {
  const KqDayFetch({required this.records, required this.notes});
  final List<KqAttendanceRecord> records;
  final List<String> notes;
}

/// 把 `findKqAttendanceList` 的 data 摊平成记录列表。
///
/// 四类列表在服务端是分开返回的，标签写死在这里，便于界面按分类展示。
List<KqAttendanceRecord> parseAttendanceRecords(
  Map<String, dynamic> data, {
  required String paikeId,
  String courseName = '',
}) {
  const buckets = {
    'qingJiaList': '请假',
    'zhengChangList': '正常',
    'yiChangList': '异常',
    'daiKaoQinList': '待考勤',
  };
  final out = <KqAttendanceRecord>[];
  buckets.forEach((key, label) {
    final list = data[key];
    if (list is! List) return;
    for (final row in list) {
      if (row is! Map) continue;
      final m = Map<String, dynamic>.from(row);
      out.add(KqAttendanceRecord(
        signId: _firstOf(m, const ['signId', 'studentSignId', 'id']),
        studentNo: _firstOf(m, const ['studentNo', 'staffCode']),
        studentName: _firstOf(m, const ['studentName', 'name']),
        courseName:
            courseName.isNotEmpty ? courseName : _firstOf(m, const ['courseName']),
        paikeId: paikeId,
        category: label,
        date: _firstOf(m, const ['date', 'classDate']),
        classTime: _firstOf(m, const ['classTime', 'classTimeRange']),
        signInTime: _firstOf(m, const ['signInTime', 'firstSignInTime']),
        signOutTime: _firstOf(m, const ['signOutTime']),
        raw: m,
      ));
    }
  });
  return out;
}

String _firstOf(Map<String, dynamic> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    final s = '$v'.trim();
    if (s.isNotEmpty && s != 'null') return s;
  }
  return '';
}

/// 历史考勤记录的读取与修改。
///
/// 服务端这几个接口都写在教师端代码里，学生身份能不能调得动由服务端决定；
/// 本类只负责把请求发对、把回话如实带回来。
class KqRecordTool {
  KqRecordTool({
    required this.cookie,
    required this.studentNo,
    this.onLog,
  });

  final String cookie;
  final String studentNo;
  final void Function(String message)? onLog;

  KqClient? _client;

  KqClient get _c => _client ??= KqClient(cookie: cookie);

  void close() => _client?.close();

  Future<void> _log(String m) async {
    await KqAutoStore.appendLog(m);
    onLog?.call(m);
  }

  /// 取某天的课（拿 paikeId），日期为空则今天。
  Future<List<Map<String, dynamic>>> coursesOn(DateTime day) async {
    final resp = await _c.schedule(ymd(day), studentNo);
    return coursesOf(resp);
  }

  /// 拉某节课的考勤名单，返回四类摊平后的记录。
  Future<List<KqAttendanceRecord>> listByPaike(
    String paikeId, {
    String courseName = '',
  }) async {
    final resp = await _c.findKqAttendanceList(paikeId);
    final code = resp is Map ? '${resp['code']}' : '';
    if (code != '200') {
      await _log('× 记录接口 code=$code ${_brief(resp)}');
      return const [];
    }
    final data = (resp is Map ? resp['data'] : null);
    if (data is! Map) return const [];
    final out = parseAttendanceRecords(
      Map<String, dynamic>.from(data),
      paikeId: paikeId,
      courseName: courseName,
    );
    await _log('记录 $paikeId：${out.length} 条（'
        '${const ['qingJiaList', 'zhengChangList', 'yiChangList', 'daiKaoQinList'].map((k) => '$k=${(data[k] as List?)?.length ?? 0}').join(' ')}）');
    return out;
  }

  /// 拉某天全部课的记录，并把每门课的服务端回话逐条记下来。
  ///
  /// 之前这里把失败原因只写进共享日志，界面上只看到"没有记录"，
  /// 分不清是没课、没权限还是参数不对。现在原因跟着结果一起返回。
  Future<KqDayFetch> fetchDay(DateTime day) async {
    final notes = <String>[];
    dynamic resp;
    try {
      resp = await _c.schedule(ymd(day), studentNo);
    } catch (e) {
      notes.add('课表请求异常：$e');
      await _log('× 课表请求异常：$e');
      return KqDayFetch(records: const [], notes: notes);
    }

    final courses = coursesOf(resp);
    if (courses.isEmpty) {
      final code = resp is Map ? '${resp['code']}' : '';
      final msg = resp is Map
          ? '${resp['msg'] ?? resp['message'] ?? ''}'
          : '$resp';
      notes.add('课表为空  code=$code  msg=${_brief(msg)}');
      await _log('× 课表为空 code=$code ${_brief(msg)}');
      return KqDayFetch(records: const [], notes: notes);
    }
    notes.add('课表 ${courses.length} 门课（${ymd(day)}）');

    final out = <KqAttendanceRecord>[];
    for (final c in courses) {
      final id = '${c['id'] ?? ''}';
      final name = '${c['courseName'] ?? '课程'}';
      if (id.isEmpty) {
        notes.add('$name：没有 paikeId，跳过');
        continue;
      }
      dynamic r;
      try {
        r = await _c.findKqAttendanceList(id);
      } catch (e) {
        notes.add('$name：记录请求异常 $e');
        continue;
      }
      final code = r is Map ? '${r['code']}' : '';
      final msg = r is Map ? '${r['msg'] ?? r['message'] ?? ''}' : '$r';
      if (code != '200') {
        notes.add('$name：code=$code  msg=${_brief(msg)}');
        await _log('× $name 记录 code=$code ${_brief(msg)}');
      } else {
        final data = r is Map ? r['data'] : null;
        if (data is! Map) {
          notes.add('$name：data 不是对象  ${_brief(data)}');
        } else {
          final rows = parseAttendanceRecords(
            Map<String, dynamic>.from(data),
            paikeId: id,
            courseName: name,
          );
          out.addAll(rows);
          final counts = {
            '请假': (data['qingJiaList'] as List?)?.length ?? 0,
            '正常': (data['zhengChangList'] as List?)?.length ?? 0,
            '异常': (data['yiChangList'] as List?)?.length ?? 0,
            '待考勤': (data['daiKaoQinList'] as List?)?.length ?? 0,
          };
          notes.add('$name：ok  ${counts.entries.map((e) => '${e.key}${e.value}').join(' ')}');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return KqDayFetch(records: out, notes: notes);
  }

  /// 兼容旧调用：只要记录本身。
  Future<List<KqAttendanceRecord>> listByDay(DateTime day) async =>
      (await fetchDay(day)).records;

  /// 只保留自己的记录（按学号比对）。学号为空时全部保留。
  List<KqAttendanceRecord> mine(List<KqAttendanceRecord> rows) {
    if (studentNo.isEmpty) return rows;
    final keep = <KqAttendanceRecord>[];
    for (final r in rows) {
      if (r.studentNo.isEmpty || r.studentNo == studentNo) keep.add(r);
    }
    return keep;
  }

  static String flagsToResultStr(Set<KqFlag> flags) {
    final codes = flags.map((f) => f.code).toSet().toList()..sort();
    return codes.join(',');
  }

  /// 改一条记录的考勤结果。dryRun 只打 payload，不发请求。
  Future<KqApplyResult> applyResult(
    KqAttendanceRecord record,
    Set<KqFlag> flags, {
    bool dryRun = true,
  }) async {
    if (!record.hasSignId) {
      return const KqApplyResult(ok: false, message: '这条记录没有 signId，没法改');
    }
    if (flags.isEmpty) {
      return const KqApplyResult(ok: false, message: '至少选一个标记（迟到/早退/旷课）');
    }
    final resultStr = flagsToResultStr(flags);
    final payload = {
      'studentSignId': record.signId,
      'attendanceResultStr': resultStr,
    };
    if (dryRun) {
      await _log('演练 updateKqAttendanceResult ${_brief(payload)}');
      return KqApplyResult(
        ok: true,
        message: '演练模式：将要发送 $payload',
      );
    }

    await _log('提交 updateKqAttendanceResult ${_brief(payload)}');
    dynamic resp;
    try {
      resp = await _c.updateKqAttendanceResult(record.signId, resultStr);
    } catch (e) {
      final msg = '× 提交异常：$e';
      await _log(msg);
      return KqApplyResult(ok: false, message: msg);
    }
    final code = resp is Map ? '${resp['code']}' : '';
    final msg = resp is Map ? '${resp['msg'] ?? resp['message'] ?? ''}' : '$resp';
    if (code != '200') {
      await _log('× 提交失败 code=$code $msg');
      return KqApplyResult(ok: false, message: '失败 code=$code $msg');
    }

    // 回读确认：重新拉同一节课，看这条记录还在不在原分类里。
    final after = await listByPaike(record.paikeId, courseName: record.courseName);
    final hit = after.where((r) => r.signId == record.signId).toList();
    if (hit.isEmpty) {
      await _log('! 回 200 但没在名单里找到这条记录');
      return const KqApplyResult(ok: true, message: '接口回 200，但回读没找到这条记录');
    }
    final now = hit.first;
    await _log('✓ 回读确认：${now.category} ${now.signInTime}/${now.signOutTime}');
    return KqApplyResult(
      ok: true,
      confirmed: true,
      message: '已提交并回读确认：${now.category}',
    );
  }

  static String _first(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v == null) continue;
      final s = '$v'.trim();
      if (s.isNotEmpty && s != 'null') return s;
    }
    return '';
  }

  String _brief(dynamic v) {
    var s = '$v';
    if (s.length > 200) s = '${s.substring(0, 200)}…';
    return s;
  }
}

/// 业务层：课表、签到、签退、人脸结果、设备日志。
library;

import 'dart:convert';

import 'envelope.dart';

class KqClient {
  final KqHttp http;
  KqClient({String? token, String? cookie})
      : http = KqHttp(token: token, cookie: cookie);

  Future<dynamic> myInfo() => http.post('/myinfoApp', {});

  Future<dynamic> schedule(String classDate, String studentNo) =>
      http.post('/studentPaike/mySchedule', {
        'classDate': classDate,
        'studentNo': studentNo,
      });

  Future<dynamic> doSign(Map<String, dynamic> payload) =>
      http.post('/studentSign/doSign', payload);

  Future<dynamic> doSignOut(Map<String, dynamic> payload) =>
      http.post('/studentSign/doSignOut', payload);

  Future<dynamic> faceReport(Map<String, dynamic> payload) =>
      http.post('/faceSign/report', payload);

  Future<dynamic> mobileLog(Map<String, dynamic> payload) =>
      http.post('/mobileLog/add', payload);

  /// 用统一认证的 userToken 换 JWT（前端 redirect-login 走的就是这个）。
  Future<dynamic> getAccessToken(String code) =>
      http.post('/edu/login/getAccessToken', {'code': code, 'loginType': 'h5'});

  /// 取 SSO 登录跳转地址。
  Future<dynamic> getLoginCode() =>
      http.get('/edu/login/getLoginCode?loginType=h5');

  // ------------------------------------------------------------------
  // 考勤记录（这几个名字都在教师端代码里，服务端角色校验成不成立要看实测）
  // ------------------------------------------------------------------

  /// 按排课拉考勤名单：返回 qingJiaList / zhengChangList / yiChangList / daiKaoQinList。
  Future<dynamic> checkList(String teacherPaikeId) =>
      http.get('/studentSign/checkList', {'teacherPaikeId': teacherPaikeId});

  /// 考勤查询列表（同上四类，另一个入口）。
  Future<dynamic> findKqAttendanceList(String teacherPaikeId) =>
      http.get('/studentPaike/findKqAttendanceList',
          {'teacherPaikeId': teacherPaikeId});

  /// 改某条考勤结果。attendanceResultStr 是逗号串：1=迟到 2=早退 3=旷课。
  Future<dynamic> updateKqAttendanceResult(
          String studentSignId, String attendanceResultStr) =>
      http.post('/studentPaike/updateKqAttendanceResult', {
        'studentSignId': studentSignId,
        'attendanceResultStr': attendanceResultStr,
      });

  /// 老师代签到。
  Future<dynamic> signByTeacher(Map<String, dynamic> payload) =>
      http.post('/studentSign/signByTeacher', payload);

  /// 老师代签退。
  Future<dynamic> signOutByTeacher(Map<String, dynamic> payload) =>
      http.post('/studentSign/signOutByTeacher', payload);

  /// 审核签到。
  Future<dynamic> signInCheckByTeacher(Map<String, dynamic> payload) =>
      http.post('/studentSign/signInCheckByTeacher', payload);

  /// 审核签退。
  Future<dynamic> signOutCheckByTeacher(Map<String, dynamic> payload) =>
      http.post('/studentSign/signOutCheckByTeacher', payload);

  /// 代请假。
  Future<dynamic> leaveSignByTeacher(Map<String, dynamic> payload) =>
      http.post('/studentSign/leaveSignByTeacher', payload);

  void close() => http.close();
}

/// 解析课表返回，取出课程数组。
List<Map<String, dynamic>> coursesOf(dynamic resp) {
  if (resp is Map && '${resp['code']}' == '200') {
    final data = resp['data'];
    if (data is List) {
      return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
  }
  return const [];
}

/// 解析 /myinfoApp 里的 staffCode。
String? staffCodeOf(dynamic resp) {
  final m = RegExp(r'"staffCode"\s*:\s*"([^"]+)"').firstMatch(jsonEncode(resp));
  return m?.group(1);
}

String ymd(DateTime d) =>
    '${d.year}-${_p(d.month)}-${_p(d.day)}';
String hm(DateTime d) => '${_p(d.hour)}:${_p(d.minute)}';
String stamp(DateTime d) => '${ymd(d)} ${hm(d)}:${_p(d.second)}';
String _p(int n) => n.toString().padLeft(2, '0');

/// "08:00" → DateTime（同一天）。
DateTime atTime(DateTime day, String hhmm) {
  final parts = hhmm.split(':');
  return DateTime(day.year, day.month, day.day,
      int.parse(parts[0]), int.parse(parts[1]), 0, 0);
}

/// 从任意时间字段里抠出 "HH:mm"：兼容 "08:00"、"08:00:00"、"2026-11-18 08:00:00"。
String? hhmmOf(dynamic v) {
  if (v == null) return null;
  final m = RegExp(r'(\d{1,2}):(\d{2})').firstMatch('$v');
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final mi = int.parse(m.group(2)!);
  if (h > 23 || mi > 59) return null;
  return '${_p(h)}:${_p(mi)}';
}

/// 取课程的上课/下课时间；优先用站点自己的 signInTimeRange / classTimeRange。
({DateTime start, DateTime end, String source}) courseWindow(
    Map<String, dynamic> c) {
  final day = DateTime.now();
  String? s, e, src;

  // signInTimeRange 形如 "07:50-10:00"：签到窗口本身就是它
  final r = c['signInTimeRange'];
  if (r != null && '$r'.contains('-')) {
    final parts = '$r'.split('-');
    final a = hhmmOf(parts.first);
    final b = hhmmOf(parts.last);
    if (a != null && b != null) return (start: atTime(day, a), end: atTime(day, b), source: 'signInTimeRange');
  }

  s = hhmmOf(c['startTime']);
  e = hhmmOf(c['endTime']);
  src = 'startTime/endTime';
  if (s == null || e == null) {
    final ctr = c['classTimeRange'];
    if (ctr != null && '$ctr'.contains('-')) {
      final parts = '$ctr'.split('-');
      s ??= hhmmOf(parts.first);
      e ??= hhmmOf(parts.last);
      src = 'classTimeRange';
    }
  }
  // 兜底：拿不到就当今天全天不可签（由调用方判断）
  return (
    start: s == null ? atTime(day, '23:59') : atTime(day, s),
    end: e == null ? atTime(day, '00:00') : atTime(day, e),
    source: src,
  );
}

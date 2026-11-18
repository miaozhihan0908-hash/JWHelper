import 'package:flutter_test/flutter_test.dart';

import 'package:JWHelper/features/attendance/data/kq_core/authz_judge.dart';
import 'package:JWHelper/features/attendance/data/kq_record_tool.dart';

void main() {
  group('KqFlag 与 attendanceResultStr', () {
    test('单个标记', () {
      expect(KqRecordTool.flagsToResultStr({KqFlag.late}), '1');
      expect(KqRecordTool.flagsToResultStr({KqFlag.early}), '2');
      expect(KqRecordTool.flagsToResultStr({KqFlag.absenteeism}), '3');
    });

    test('多选按 1,2,3 升序拼接（与站点 join(",") 一致）', () {
      expect(
        KqRecordTool.flagsToResultStr(
            {KqFlag.absenteeism, KqFlag.late}),
        '1,3',
      );
      expect(
        KqRecordTool.flagsToResultStr(KqFlag.values.toSet()),
        '1,2,3',
      );
    });

    test('code 反查', () {
      expect(KqFlag.byCode('2')?.label, '早退');
      expect(KqFlag.byCode('9'), isNull);
    });
  });

  group('parseAttendanceRecords', () {
    final data = <String, dynamic>{
      'qingJiaList': [
        {
          'signId': 'S-LEAVE',
          'studentNo': '202608140075',
          'studentName': '张三',
          'date': '2026-11-17',
          'classTime': '14:00-15:25',
          'signInTime': '',
          'signOutTime': '',
        }
      ],
      'zhengChangList': [
        {
          'studentSignId': 'S-OK',
          'studentNo': '202608140075',
          'studentName': '张三',
          'classTime': '15:45-17:10',
          'firstSignInTime': '15:42',
          'signOutTime': '17:05',
        }
      ],
      'yiChangList': [
        {
          'id': 'S-BAD',
          'studentNo': '202608140999',
          'studentName': '李四',
          'classTime': '08:00-09:25',
        }
      ],
      'daiKaoQinList': <dynamic>[],
    };

    test('四类摊平、字段兼容 signId/studentSignId/id', () {
      final rows = parseAttendanceRecords(data, paikeId: 'P1', courseName: '管理学');
      expect(rows.length, 3);
      expect(rows[0].signId, 'S-LEAVE');
      expect(rows[0].category, '请假');
      expect(rows[1].signId, 'S-OK');
      expect(rows[1].signInTime, '15:42');
      expect(rows[2].signId, 'S-BAD');
      expect(rows[2].category, '异常');
      expect(rows.every((r) => r.paikeId == 'P1'), isTrue);
      expect(rows.every((r) => r.courseName == '管理学'), isTrue);
    });

    test('缺少 signId 的行不能改', () {
      final rows = parseAttendanceRecords({
        'yiChangList': [
          {'studentNo': 'x', 'studentName': 'y'}
        ]
      }, paikeId: 'P1');
      expect(rows.single.hasSignId, isFalse);
    });

    test('只看自己的记录', () {
      final tool = KqRecordTool(cookie: 'c', studentNo: '202608140075');
      final rows = parseAttendanceRecords(data, paikeId: 'P1');
      final mine = tool.mine(rows);
      expect(mine.length, 2);
      expect(mine.any((r) => r.studentNo == '202608140999'), isFalse);
    });

    test('空数据不炸', () {
      expect(parseAttendanceRecords(const {}, paikeId: 'P1'), isEmpty);
      expect(
        parseAttendanceRecords({'yiChangList': null}, paikeId: 'P1'),
        isEmpty,
      );
    });
  });

  group('judgeProbe 判定', () {
    test('业务码 200 → 开', () {
      expect(judgeProbe(code: '200', msg: '操作成功'), '开');
    });

    test('权限类文案 → 关', () {
      expect(judgeProbe(code: '500', msg: '当前用户无此操作权限'), '关');
      expect(judgeProbe(code: '500', msg: '角色不允许'), '关');
      expect(judgeProbe(code: '500', msg: '禁止访问'), '关');
    });

    test('记录不存在 → 门已过（开）', () {
      expect(judgeProbe(code: '500', msg: '考勤记录不存在'), '开');
    });

    test('未登录 → 关', () {
      expect(judgeProbe(code: '', msg: '未找到授权信息，请重新登录！'), '关');
    });

    test('HTTP 403 → 关；其它 → 不明', () {
      expect(judgeProbe(http: 403, code: '', msg: 'forbidden'), '关');
      expect(judgeProbe(code: '', msg: '未知错误'), '不明');
    });
  });
}

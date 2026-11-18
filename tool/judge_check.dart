/// 纯 Dart 用例：判定规则必须能在没有 Flutter 的环境里跑通。
///
/// 运行：dart run tool/judge_check.dart
library;

import '../lib/features/attendance/data/kq_core/authz_judge.dart';

int _fail = 0;

void expect(String name, String actual, String want) {
  final ok = actual == want;
  if (!ok) _fail++;
  print('${ok ? 'PASS' : 'FAIL'}  $name  -> $actual${ok ? '' : ' (want $want)'}');
}

void main() {
  // 认证层优先级最高：这句话同时含「未找到」和「授权」
  expect('未登录', judgeProbe(code: '', msg: '未找到授权信息，请重新登录！'), '关');
  expect('令牌过期', judgeProbe(code: '500', msg: '登录已过期'), '关');
  // 授权层
  expect('无权限', judgeProbe(code: '500', msg: '当前用户无此操作权限'), '关');
  expect('角色不足', judgeProbe(code: '500', msg: '角色不允许该操作'), '关');
  expect('非法请求', judgeProbe(code: '500', msg: '非法请求'), '关');
  // 业务层：前两层过了
  expect('记录不存在', judgeProbe(code: '500', msg: '考勤记录不存在'), '开');
  expect('参数错误', judgeProbe(code: '500', msg: '缺少参数'), '开');
  // 成功
  expect('业务码 200', judgeProbe(code: '200', msg: '操作成功'), '开');
  // HTTP 兜底
  expect('HTTP 403', judgeProbe(http: 403, code: '', msg: 'forbidden'), '关');
  expect('未知', judgeProbe(code: '500', msg: '系统繁忙'), '不明');

  print(_fail == 0 ? '\nALL PASS' : '\n$_fail FAILED');
}

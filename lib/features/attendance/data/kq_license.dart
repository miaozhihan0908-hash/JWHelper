import 'dart:convert';

import 'kq_core/md5.dart';

/// 谁能用这套自动签到。
///
/// 包是发出去的，谁都能装；但签名请求本身绑学号，学号是这套系统里唯一的身份，
/// 所以用它当身份闸。存哈希不存明文——学号属于个人信息，没必要明文躺在 APK 里
/// 等着被 strings 扫出来。
class KqLicense {
  /// 允许使用的学号（md5 大写）。
  ///
  /// 202608140075
  static const Set<String> _allowed = {'A7E77B85EBF12034903A2F686935C50D'};

  /// 学号为空返回 true：交给「缺少登录态」那条提示去处理，别误报成未授权。
  static bool allows(String studentNo) {
    final no = studentNo.trim();
    if (no.isEmpty) return true;
    return _allowed.contains(md5Hex(utf8.encode(no)).toUpperCase());
  }

  static const String deniedMessage = '该版本仅限作者本人使用，自动签到已停用';
}

import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

import 'kq_gate.dart';
import 'kq_licence.dart';

/// 「这个功能现在能不能用」的唯一入口。
///
/// 三层判断按顺序来，第一层拦住就不往下问：
///   1. 远程开关（总闸 / 单个功能 / 学号白名单）
///   2. 授权码（只对配置里点名的那几个功能生效）
///
/// 各处调用前先 `await KqAccess.load()`，之后就可以同步问。
class KqAccess {
  /// 后台自动签到。
  static const String autoSign = 'autoSign';

  /// 手动签到 / 签退（不需要授权码）。
  static const String manualSign = 'manualSign';

  /// 强制签到（默认需要授权码：它无视时间窗，等于万能签到）。
  static const String forceSign = 'forceSign';

  static Future<void> load() async {
    await KqGate.load();
    await KqLicence.load();
  }

  static GateState get state => KqGate.state;

  static bool identityAllows(String studentNo) =>
      KqGate.identityAllows(studentNo);

  static bool featureOn(String feature) => KqGate.state.flags.on(feature);

  static LicenceEvaluation licence(String studentNo) =>
      KqLicence.evaluateSync(KqGate.state, studentNo);

  /// null = 能用；否则是不能用的原因（直接显示）。
  static String? blocker(String studentNo, String feature) {
    final gate = KqGate.state;
    final reason = KqGate.gateBlocker(studentNo, feature);
    if (reason != null) return reason;
    if (!gate.licencePolicy.needs(feature)) return null;
    final eval = KqLicence.evaluateSync(gate, studentNo);
    return eval.ok ? null : eval.message;
  }

  static bool allows(String studentNo, String feature) =>
      blocker(studentNo, feature) == null;

  /// 这个功能是不是"缺授权"而不是"被停用"——界面靠它决定要不要给"输入授权码"按钮。
  static bool missingLicence(String studentNo, String feature) {
    final gate = KqGate.state;
    if (!gate.licencePolicy.needs(feature)) return false;
    if (KqGate.gateBlocker(studentNo, feature) != null) return false;
    return !KqLicence.evaluateSync(gate, studentNo).ok;
  }

  /// 给"更多 → 远程状态"用的摘要。
  static String describe(String studentNo) {
    final eval = licence(studentNo);
    final policy = KqGate.state.licencePolicy;
    final features = policy.features.toList()..sort();
    return '授权要求: ${policy.required ? '开启' : '关闭'}   '
        '功能: ${features.isEmpty ? '（无）' : features.join(',')}\n'
        '本机授权: ${eval.label}   ${eval.message}\n'
        '已发码: ${KqGate.state.licences.length} 条\n'
        '${KqGate.describe()}';
  }
}

/// 把「身份白名单」和「远程开关」合成一道闸问句：能不能用这个功能。
///
/// 和 [GateClient] 分开是为了让业务只依赖这一个门面：业务侧不关心配置从哪个
/// 镜像来的、缓存存在哪，只问一句 `allows(identity, feature)`。
library;

import 'gate_client.dart';
import 'gate_config.dart';

class GateController {
  GateController({
    required this.client,
    this.identityAllowed,
    this.identityNotice,
  });

  final GateClient client;

  /// 身份白名单。返回 false 表示这个身份根本不该用这套功能。
  /// 传 null 表示不做身份限制，只看远程开关。
  final bool Function(String identity)? identityAllowed;

  /// 身份被拒时用的文案；不传就用配置里的。
  final GateNotice? identityNotice;

  GateState get state => client.current;

  /// 当前生效的文案：身份被拒时优先用 [identityNotice]。
  GateNotice get notice => state.notice;

  bool identityOk(String identity) => identityAllowed?.call(identity) ?? true;

  bool featureOn(String feature) => state.flags.on(feature);

  /// 身份和远程开关都过了才算能用。
  bool allows(String identity, String feature) =>
      identityOk(identity) && featureOn(feature);

  /// 不能用时返回一句原因，能用返回 null。界面直接拿去显示。
  String? blocker(String identity, String feature) {
    if (state.flags.killAll) return state.notice.body;
    if (!identityOk(identity)) {
      return (identityNotice ?? state.notice).body;
    }
    if (!featureOn(feature)) return state.notice.body;
    return null;
  }

  Future<void> init() => client.load();

  Future<GateState> refresh({bool force = false}) =>
      client.refresh(force: force);

  void refreshIfStale() => client.refreshIfStale();

  void refreshSoon() => client.refreshSoon();

  /// 给诊断面板用的一行摘要。
  String describe() {
    final s = state;
    final f = s.flags;
    final features = f.features.isEmpty
        ? '（未声明，全开）'
        : f.features.entries
              .map((e) => '${e.key}=${e.value ? '开' : '关'}')
              .join(' ');
    String two(int n) => n.toString().padLeft(2, '0');
    String stamp(DateTime? t) => t == null
        ? '-'
        : '${t.year}-${two(t.month)}-${two(t.day)} '
              '${two(t.hour)}:${two(t.minute)}';
    final src = s.source.length > 48
        ? '${s.source.substring(0, 48)}…'
        : s.source;
    return '来源: $src\n'
        '签发: ${stamp(s.issuedAt?.toLocal())}   '
        '到期: ${stamp(s.expiresAt?.toLocal())}\n'
        '同步: ${stamp(s.syncedAt?.toLocal())}\n'
        '总闸: ${f.killAll ? '已全停' : '正常'}   功能: $features';
  }
}

import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

import 'kq_auto_store.dart';
import 'kq_license.dart';

/// 考勤功能这一侧的远程开关接线。
///
/// 判定逻辑全在 [GateController] 里，这里只做三件事：认领 appId、写死公钥和
/// 镜像地址、把「学号」当身份喂给 [KqLicense]。
class KqGate {
  /// 配置里认领哪一节（`apps.jwhelper`）。
  static const String appId = 'jwhelper';

  static const String featureAutoSign = 'autoSign';
  static const String featureManualSign = 'manualSign';

  /// 镜像按序尝试，第一个验签通过的就用。
  ///
  /// 顺序考量：GitHub raw 更新最快（没有 CDN 长缓存），但在墙内经常连不上；
  /// jsDelivr 墙内可达性好，代价是 `@main` 可能被缓存十几小时。所以 raw 在前、
  /// jsDelivr 兜底——墙内只是多等一次超时。
  static const List<String> mirrors = <String>[
    'https://raw.githubusercontent.com/miaozhihan0908-hash/JWHelper/main/kq_gate.json',
    'https://cdn.jsdelivr.net/gh/miaozhihan0908-hash/JWHelper@main/kq_gate.json',
  ];

  /// Ed25519 公钥（32 字节）。私钥只在作者手里，丢了只能重新发版换公钥。
  static const String publicKeyHex =
      '42881F0C923B6F35EC432258EE83E8861DE73332CFCC837489246F3BE6529D8A';

  static final GateClient client = GateClient(
    appId: appId,
    publicKeyHex: publicKeyHex,
    mirrors: mirrors,
    readCache: KqAutoStore.readGateCache,
    writeCache: KqAutoStore.saveGateCache,
    // 进页面就要看得见新文案，所以界面这条路的节流只有一分钟；
    // 后台那条仍然走 ttl（6 小时），免得费电。
    minGap: const Duration(minutes: 1),
  );

  static final GateController controller = GateController(
    client: client,
    identityAllowed: KqLicense.allows,
    // 身份被拒时用这句，跟"作者停用"区分开，免得看着像自己乱点的结果。
    identityNotice: const GateNotice(
      title: '版本受限',
      body: KqLicense.deniedMessage,
      confirm: '知道了',
    ),
  );

  /// 当前快照。
  static GateState get state => client.current;

  /// 弹窗要显示的那段文案（可能来自远程配置，也可能是编译默认）。
  static GateNotice get notice => controller.notice;

  static bool get killAll => client.current.flags.killAll;

  /// 冷启动读缓存，不联网。重复调用无副作用。
  static Future<void> load() => controller.init();

  /// 联网拉一次。
  static Future<GateState> refresh({bool force = false}) =>
      controller.refresh(force: force);

  /// 后台用：隔 6 小时才回源。
  static void refreshIfStale() => controller.refreshIfStale();

  /// 界面用：进页面时调一次，隔一分钟才回源。
  static void touch() => controller.refreshSoon();

  /// 界面用：等一次回源，最多等 [cap]，拿不到就用缓存里的。
  ///
  /// 超时只是不再等它，网络请求本身不会被取消——它回来后状态照样会更新。
  static Future<GateState> refreshQuick({
    Duration cap = const Duration(seconds: 2),
  }) async {
    try {
      return await client.refresh(force: true).timeout(cap);
    } catch (_) {
      return client.current;
    }
  }

  static bool identityAllows(String studentNo) =>
      controller.identityOk(studentNo);

  static bool autoSignOn(String studentNo) =>
      controller.allows(studentNo, featureAutoSign);

  static bool manualSignOn(String studentNo) =>
      controller.allows(studentNo, featureManualSign);

  /// 自动签到被挡住的原因，能用返回 null。
  static String? autoBlocker(String studentNo) =>
      controller.blocker(studentNo, featureAutoSign);

  /// 手动签到被挡住的原因，能用返回 null。
  static String? manualBlocker(String studentNo) =>
      controller.blocker(studentNo, featureManualSign);

  /// 诊断面板里的一行摘要。
  static String describe() => controller.describe();
}

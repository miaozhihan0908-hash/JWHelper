import 'dart:convert';

import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

import 'kq_auto_store.dart';
import 'kq_core/md5.dart';

/// 考勤功能这一侧的远程开关接线。
///
/// 判定逻辑全在 [GateController] / [KqAccess] 里，这里只做三件事：认领 appId、
/// 写死公钥和镜像地址、把学号白名单从配置里读出来当身份闸。
class KqGate {
  /// 配置里认领哪一节（`apps.jwhelper`）。
  static const String appId = 'jwhelper';

  static const String featureAutoSign = 'autoSign';
  static const String featureManualSign = 'manualSign';
  static const String featureForceSign = 'forceSign';

  /// 镜像按序尝试，第一个验签通过的就用。
  ///
  /// 排序依据是**实测的墙内可达性**，不只是理论：
  /// * `raw.githubusercontent.com` 在模拟器/移动网络上 TCP 直接连不上（不是慢），
  ///   实测 3 秒超时；它更新最快但没有 CDN 长缓存，排第二位。
  /// * `api.github.com` 能连通，contents 接口没有 CDN 缓存，拿到的就是最新提交；
  ///   代价是匿名 60 次/小时——5 分钟一轮够用，临近上课拉得密会被限流，之后
  ///   自动落到后面的镜像。
  /// * jsDelivr 墙内可达性好，但 `@main` 会被缓存十几小时，所以**每次改完配置
  ///   都要 purge 一次**（见 gate.yml / push_files.py）。cdn 与 fastly 同一张
  ///   CDN，留一个备用域名。
  static const List<String> mirrors = <String>[
    'https://api.github.com/repos/miaozhihan0908-hash/JWHelper/contents/kq_gate.json?ref=main',
    'https://raw.githubusercontent.com/miaozhihan0908-hash/JWHelper/main/kq_gate.json',
    'https://cdn.jsdelivr.net/gh/miaozhihan0908-hash/JWHelper@main/kq_gate.json',
    'https://fastly.jsdelivr.net/gh/miaozhihan0908-hash/JWHelper@main/kq_gate.json',
  ];

  /// Ed25519 公钥（32 字节）。私钥只在作者手里，丢了只能重新发版换公钥。
  static const String publicKeyHex =
      '42881F0C923B6F35EC432258EE83E8861DE73332CFCC837489246F3BE6529D8A';

  /// 配置里没写 `licence` 时按这套判：签到相关三档全都要码。
  ///
  /// **fail-closed**：连不上配置、本地也没缓存时，这三项就是不可用，
  /// 而不是悄悄放开——否则断网 + 清数据就能白用。
  static const GateLicencePolicy defaultLicencePolicy = GateLicencePolicy(
    required: true,
    features: <String>{
      featureAutoSign,
      featureManualSign,
      featureForceSign,
    },
  );

  static final GateClient client = GateClient(
    appId: appId,
    publicKeyHex: publicKeyHex,
    mirrors: mirrors,
    readCache: KqAutoStore.readGateCache,
    writeCache: KqAutoStore.saveGateCache,
    // 生效速度优先：
    //   ttl    = 5 分钟 —— 后台服务最迟 5 分钟就知道自己被停用了；
    //   minGap = 10 秒  —— 进页面、临近上课时的强制回源几乎即时。
    // 配置文件只有几百字节，一天轮询几百次也就几 MB，比一次网页加载还轻。
    ttl: const Duration(minutes: 5),
    minGap: const Duration(seconds: 10),
    defaultLicencePolicy: defaultLicencePolicy,
  );

  static final GateController controller = GateController(
    client: client,
    identityAllowed: _identityFromConfig,
    // 身份被拒时用这句，跟"作者停用"区分开，免得看着像自己乱点的结果。
    identityNotice: const GateNotice(
      title: '版本受限',
      body: '当前账号不在允许使用的名单里',
      confirm: '知道了',
    ),
  );

  /// 学号白名单现在放在配置里（`allowedStudents`，md5 大写）。
  ///
  /// 空名单 = 不限制。学号为空时放行，交给「缺少登录态」那条提示去处理，
  /// 别误报成未授权。
  static bool _identityFromConfig(String studentNo) {
    final allowed = client.current.allowedStudents;
    if (allowed.isEmpty) return true;
    final no = studentNo.trim();
    if (no.isEmpty) return true;
    return allowed.contains(md5Hex(utf8.encode(no)).toUpperCase());
  }

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

  /// 后台用：隔 5 分钟才回源（比默认的 6 小时短得多，停用才来得及）。
  static void refreshIfStale() => controller.refreshIfStale();

  /// 界面用：进页面时调一次，隔 10 秒才回源。
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

  /// 只看远程开关那一层（总闸 / 功能开关 / 学号），不看授权码。
  ///
  /// 授权码那一层在 [KqAccess] 里拼上来，两边分开才好单独测。
  static String? gateBlocker(String studentNo, String feature) =>
      controller.blocker(studentNo, feature);

  /// 诊断面板里的一行摘要。
  static String describe() => controller.describe();
}

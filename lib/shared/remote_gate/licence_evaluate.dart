/// 授权码的状态判定：纯函数，不碰存储、不联网、不看时钟以外的东西。
///
/// 判定顺序刻意固定成「先看有没有名单，再看码，再看学号，再看时间」——
/// 每一条失败都给一句人话，界面直接拿去显示，不用再猜。
library;

import 'gate_config.dart';

/// 本机保存的激活记录。
class LicenceActivation {
  /// 激活时那个码的指纹。
  final String kid;

  /// 第一次输码成功的时间。期限从这里起算。
  final DateTime activatedAt;

  /// 最后一次成功回源（或每轮 tick）的时间，用来发现系统时间被回拨。
  final DateTime lastSeenAt;

  const LicenceActivation({
    required this.kid,
    required this.activatedAt,
    required this.lastSeenAt,
  });

  LicenceActivation copyWith({DateTime? lastSeenAt}) => LicenceActivation(
    kid: kid,
    activatedAt: activatedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kid': kid,
    'activatedAt': activatedAt.toUtc().millisecondsSinceEpoch,
    'lastSeenAt': lastSeenAt.toUtc().millisecondsSinceEpoch,
  };

  factory LicenceActivation.fromJson(Map<String, dynamic> m) {
    DateTime at(String k) {
      final v = m[k];
      if (v is num) {
        return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
      }
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }

    return LicenceActivation(
      kid: '${m['kid'] ?? ''}'.trim().toUpperCase(),
      activatedAt: at('activatedAt'),
      lastSeenAt: at('lastSeenAt'),
    );
  }
}

enum LicenceStatus {
  /// 没有本地激活记录。
  none,

  /// 从没成功拿到过配置，本地也没有授权表。
  noTable,

  /// 码不在表里（无效，或已被作者删除 = 撤销）。
  unknown,

  /// 码绑的是别的学号。
  wrongSub,

  /// 有效期内。
  active,

  /// 永久。
  forever,

  /// 过期。
  expired,

  /// 检测到系统时间被回拨。
  clockBack,
}

class LicenceEvaluation {
  final LicenceStatus status;

  /// 命中记录时的指纹。
  final String? kid;

  /// 到期时间；永久或无效时为 null。
  final DateTime? expiresAt;

  /// 剩余天数（不足一天按一天算）。
  final int daysLeft;

  /// 这条记录设定的天数；0 = 永久。
  final int planDays;

  const LicenceEvaluation({
    required this.status,
    this.kid,
    this.expiresAt,
    this.daysLeft = 0,
    this.planDays = 0,
  });

  /// 能不能用。
  bool get ok =>
      status == LicenceStatus.active || status == LicenceStatus.forever;

  bool get forever => status == LicenceStatus.forever;

  /// 一行短标签，给胶囊/开关副标题用。
  String get label {
    switch (status) {
      case LicenceStatus.active:
        return '剩余 $daysLeft 天';
      case LicenceStatus.forever:
        return '永久授权';
      case LicenceStatus.expired:
        return '已过期';
      case LicenceStatus.unknown:
        return '授权已撤销';
      case LicenceStatus.wrongSub:
        return '学号不符';
      case LicenceStatus.clockBack:
        return '时间异常';
      case LicenceStatus.noTable:
      case LicenceStatus.none:
        return '未激活';
    }
  }

  /// 一句完整的话，给横幅/弹窗用。
  String get message {
    switch (status) {
      case LicenceStatus.active:
        return '剩余 $daysLeft 天，${_ymd(expiresAt)} 到期';
      case LicenceStatus.forever:
        return '永久授权，不会到期';
      case LicenceStatus.expired:
        return '授权已于 ${_ymd(expiresAt)} 到期';
      case LicenceStatus.unknown:
        return '授权码无效，或者已被作者撤销';
      case LicenceStatus.wrongSub:
        return '这个授权码绑定的是别的学号';
      case LicenceStatus.clockBack:
        return '检测到系统时间被回拨，授权暂停使用';
      case LicenceStatus.noTable:
        return '还没拿到授权名单，请连上网络后重试';
      case LicenceStatus.none:
        return '自动签到需要授权码，输入后即可使用';
    }
  }
}

String _ymd(DateTime? t) {
  if (t == null) return '—';
  final d = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

/// 判定当前授权状态。
///
/// * [gate] 是当前生效的（验过签的）配置快照。
/// * [activation] 是本机保存的激活记录，没激活过就传 null。
/// * [studentNo] 是这台手机当前登录的学号。
LicenceEvaluation evaluateLicence({
  required GateState gate,
  required LicenceActivation? activation,
  required String studentNo,
  required DateTime now,
}) {
  // 1) 连名单都没有：既没缓存也没联过网。宁可锁着，也不放行。
  if (gate.hasNoConfig) {
    return const LicenceEvaluation(status: LicenceStatus.noTable);
  }

  final act = activation;
  if (act == null || act.kid.isEmpty) {
    return const LicenceEvaluation(status: LicenceStatus.none);
  }

  // 2) 码必须在名单里。作者把它删掉 = 撤销。
  final record = gate.licenceOf(act.kid);
  if (record == null) {
    return LicenceEvaluation(status: LicenceStatus.unknown, kid: act.kid);
  }

  // 3) 绑了学号就必须对得上。
  final no = studentNo.trim();
  if (record.sub != '*' && record.sub.isNotEmpty && record.sub != no) {
    return LicenceEvaluation(
      status: LicenceStatus.wrongSub,
      kid: record.kid,
      planDays: record.days,
    );
  }

  // 4) 时间被往回拨了（比上次见到的还早）就暂停。
  if (now.isBefore(act.lastSeenAt.subtract(const Duration(hours: 1)))) {
    return LicenceEvaluation(
      status: LicenceStatus.clockBack,
      kid: record.kid,
      planDays: record.days,
    );
  }

  // 5) 永久。
  if (record.forever) {
    return LicenceEvaluation(
      status: LicenceStatus.forever,
      kid: record.kid,
      planDays: 0,
    );
  }

  // 6) 起算点：strict 的码钉在发码那天，否则从第一次激活算。
  final start = record.strict ? (record.iat ?? act.activatedAt) : act.activatedAt;
  final expires = start.add(Duration(days: record.days));
  if (!now.isBefore(expires)) {
    return LicenceEvaluation(
      status: LicenceStatus.expired,
      kid: record.kid,
      expiresAt: expires,
      planDays: record.days,
    );
  }

  final hours = expires.difference(now).inMinutes / 60.0;
  final daysLeft = (hours / 24).ceil().clamp(0, record.days);
  return LicenceEvaluation(
    status: LicenceStatus.active,
    kid: record.kid,
    expiresAt: expires,
    daysLeft: daysLeft,
    planDays: record.days,
  );
}

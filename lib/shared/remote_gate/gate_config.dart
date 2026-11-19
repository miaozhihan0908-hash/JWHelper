/// 远程开关的配置模型：一组命名功能 + 一把总闸 + 一段可远程编辑的文案
/// + 一张授权码名单。
///
/// 这个文件**不依赖任何业务**，换一个 App 可以直接拷走。
library;

/// 一组命名功能的开/关，外加一把总闸。
///
/// **缺省是开**：配置文件里没提到的功能按"开"处理。这样新版本加了功能、
/// 而线上配置还是旧的时候，不会因为少写一个字段就把新功能关掉。
class GateFlags {
  final Map<String, bool> features;

  /// 全量停用，优先级高于任何单个功能。
  final bool killAll;

  const GateFlags({
    this.features = const <String, bool>{},
    this.killAll = false,
  });

  /// 编译进来的默认值：全开。
  static const GateFlags open = GateFlags();

  bool on(String feature) => !killAll && features[feature] != false;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'features': features,
    'killAll': killAll,
  };

  factory GateFlags.fromJson(Map<String, dynamic> m) {
    final raw = m['features'];
    final map = <String, bool>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v is bool) map['$k'] = v;
      });
    }
    return GateFlags(features: map, killAll: m['killAll'] == true);
  }
}

/// 停用弹窗上的文案。
///
/// 放在签名过的配置里，作者改文案不用发新包；又因为在签名范围内，别人
/// 改不了——想把它改成"请重新登录"来钓鱼，验签直接不过，整份作废。
class GateNotice {
  final String title;
  final String body;
  final String confirm;

  const GateNotice({
    this.title = '功能已停用',
    this.body = '这项功能已被作者在后台停用。',
    this.confirm = '知道了',
  });

  /// 拉不到配置、或者配置里没写文案时用它。
  static const GateNotice fallback = GateNotice();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'title': title,
    'body': body,
    'confirm': confirm,
  };

  /// 缺哪个字段就落回默认值，允许只改一句。
  factory GateNotice.fromJson(Map<String, dynamic> m) {
    String pick(String key, String fallbackValue) {
      final v = m[key];
      if (v is! String) return fallbackValue;
      final t = v.trim();
      return t.isEmpty ? fallbackValue : v;
    }

    return GateNotice(
      title: pick('title', fallback.title),
      body: pick('body', fallback.body),
      confirm: pick('confirm', fallback.confirm),
    );
  }

  bool get isCustom =>
      title != fallback.title ||
      body != fallback.body ||
      confirm != fallback.confirm;
}

/// 一条已发出的授权码记录。
///
/// **这里只有指纹（kid），没有码本身**：配置文件是公开的，存明文等于把码贴
/// 在墙上。指纹由码算出来，拿到指纹反推不出码。
class GateLicence {
  /// 码的指纹：sha256(规范化后的码) 前 16 位，大写十六进制。
  final String kid;

  /// 有效天数；0 表示永久。
  final int days;

  /// 绑定的学号；'*' 表示不限（只给作者自己测试用）。
  final String sub;

  /// 发码时间。
  final DateTime? iat;

  /// true = 有效期从 [iat] 起算（重装也不重置）；false = 从首次激活起算。
  final bool strict;

  /// 备注（给作者看的：卖给谁、多少钱、微信名之类）。不参与判定。
  final String note;

  const GateLicence({
    required this.kid,
    required this.days,
    this.sub = '*',
    this.iat,
    this.strict = false,
    this.note = '',
  });

  bool get forever => days <= 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kid': kid,
    'days': days,
    'sub': sub,
    if (iat != null) 'iat': iat!.toUtc().toIso8601String(),
    if (strict) 'strict': true,
    if (note.isNotEmpty) 'note': note,
  };

  factory GateLicence.fromJson(Map<String, dynamic> m) => GateLicence(
    kid: '${m['kid'] ?? ''}'.trim().toUpperCase(),
    days: (m['days'] as num?)?.toInt() ?? 0,
    sub: '${m['sub'] ?? '*'}'.trim(),
    iat: DateTime.tryParse('${m['iat'] ?? ''}')?.toUtc(),
    strict: m['strict'] == true,
    note: '${m['note'] ?? ''}',
  );
}

/// 哪些功能要先有有效授权才能用。
class GateLicencePolicy {
  final bool required;
  final Set<String> features;

  const GateLicencePolicy({
    this.required = false,
    this.features = const <String>{},
  });

  /// 不需要授权码。
  static const GateLicencePolicy disabled = GateLicencePolicy();

  bool needs(String feature) => required && features.contains(feature);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'required': required,
    'features': features.toList()..sort(),
  };

  factory GateLicencePolicy.fromJson(Map<String, dynamic> m) {
    final raw = m['features'];
    final set = <String>{};
    if (raw is List) {
      for (final e in raw) {
        if (e is String && e.trim().isNotEmpty) set.add(e.trim());
      }
    }
    return GateLicencePolicy(required: m['required'] == true, features: set);
  }
}

/// 一份已经判定过的开关快照。
class GateState {
  final GateFlags flags;
  final GateNotice notice;

  /// 已发出的授权码名单（只有指纹）。
  final List<GateLicence> licences;

  /// 哪些功能要授权码。
  final GateLicencePolicy licencePolicy;

  /// 学号白名单（md5 大写）。空集 = 不限制。
  final Set<String> allowedStudents;

  /// 这份配置从哪来：'default' 编译默认、'cache' 本地缓存、否则是镜像 URL。
  final String source;
  final DateTime? syncedAt;
  final DateTime? issuedAt;
  final DateTime? expiresAt;

  const GateState({
    this.flags = GateFlags.open,
    this.notice = GateNotice.fallback,
    this.licences = const <GateLicence>[],
    this.licencePolicy = GateLicencePolicy.disabled,
    this.allowedStudents = const <String>{},
    this.source = 'default',
    this.syncedAt,
    this.issuedAt,
    this.expiresAt,
  });

  static const GateState open = GateState();

  bool get fromRemote => source != 'default' && source != 'cache';

  /// 从没成功拿到过配置（既没缓存也没联网）。这时候连授权表都没有。
  bool get hasNoConfig => source == 'default';

  bool get killAll => flags.killAll;

  GateLicence? licenceOf(String kid) {
    for (final l in licences) {
      if (l.kid == kid) return l;
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'flags': flags.toJson(),
    'notice': notice.toJson(),
    'licences': licences.map((e) => e.toJson()).toList(),
    'licence': licencePolicy.toJson(),
    'allowedStudents': allowedStudents.toList()..sort(),
    'source': source,
    // 统一按 UTC 存毫秒：本地时区改了也不影响一份缓存的含义。
    'syncedAt': syncedAt?.toUtc().millisecondsSinceEpoch,
    'issuedAt': issuedAt?.toUtc().millisecondsSinceEpoch,
    'expiresAt': expiresAt?.toUtc().millisecondsSinceEpoch,
  };

  factory GateState.fromJson(Map<String, dynamic> m) {
    DateTime? at(String k) {
      final v = m[k];
      return v is num
          ? DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true)
          : null;
    }

    final rawList = m['licences'];
    final licences = <GateLicence>[];
    if (rawList is List) {
      for (final e in rawList) {
        if (e is Map) {
          licences.add(GateLicence.fromJson(e.cast<String, dynamic>()));
        }
      }
    }

    final rawStudents = m['allowedStudents'];
    final students = <String>{};
    if (rawStudents is List) {
      for (final e in rawStudents) {
        if (e is String && e.trim().isNotEmpty) {
          students.add(e.trim().toUpperCase());
        }
      }
    }

    return GateState(
      flags: GateFlags.fromJson(
        (m['flags'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      notice: GateNotice.fromJson(
        (m['notice'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      licences: licences,
      licencePolicy: GateLicencePolicy.fromJson(
        (m['licence'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      allowedStudents: students,
      source: '${m['source'] ?? 'cache'}',
      syncedAt: at('syncedAt'),
      issuedAt: at('issuedAt'),
      expiresAt: at('expiresAt'),
    );
  }
}

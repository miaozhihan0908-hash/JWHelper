/// 远程开关的配置模型：一组命名功能 + 一把总闸 + 一段可远程编辑的文案。
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

/// 一份已经判定过的开关快照。
class GateState {
  final GateFlags flags;
  final GateNotice notice;

  /// 这份配置从哪来：'default' 编译默认、'cache' 本地缓存、否则是镜像 URL。
  final String source;
  final DateTime? syncedAt;
  final DateTime? issuedAt;
  final DateTime? expiresAt;

  const GateState({
    this.flags = GateFlags.open,
    this.notice = GateNotice.fallback,
    this.source = 'default',
    this.syncedAt,
    this.issuedAt,
    this.expiresAt,
  });

  static const GateState open = GateState();

  bool get fromRemote => source != 'default' && source != 'cache';

  bool get killAll => flags.killAll;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'flags': flags.toJson(),
    'notice': notice.toJson(),
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

    return GateState(
      flags: GateFlags.fromJson(
        (m['flags'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      notice: GateNotice.fromJson(
        (m['notice'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      source: '${m['source'] ?? 'cache'}',
      syncedAt: at('syncedAt'),
      issuedAt: at('issuedAt'),
      expiresAt: at('expiresAt'),
    );
  }
}

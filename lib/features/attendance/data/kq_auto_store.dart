import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 后台签到引擎的配置与运行状态。
///
/// 全部落在 SharedPreferences 里，因为后台 isolate（前台服务）读不到 UI 侧的
/// 内存状态，只能靠磁盘交换。这里**不放**密码：登录态用统一认证令牌，
/// 由网页版页面在准备阶段推过来。
class KqAutoConfig {
  /// 后台引擎总开关。
  final bool enabled;

  /// 真提交（false 只演练，把要发的内容写进日志）。
  final bool commit;

  /// 轮询间隔（秒）。默认 20 秒，够细又不至于太费电。
  final int intervalSec;

  /// GPS 高斯抖动（米）。0 = 正好落在围栏基准点。
  final double jitterSigma;

  /// 'auto' = 用围栏基准点 + 抖动；'device' = 用真机定位（读不到才回退）。
  final String gpsMode;

  const KqAutoConfig({
    this.enabled = false,
    this.commit = true,
    this.intervalSec = 20,
    this.jitterSigma = 10,
    this.gpsMode = 'auto',
  });

  KqAutoConfig copyWith({
    bool? enabled,
    bool? commit,
    int? intervalSec,
    double? jitterSigma,
    String? gpsMode,
  }) {
    return KqAutoConfig(
      enabled: enabled ?? this.enabled,
      commit: commit ?? this.commit,
      intervalSec: intervalSec ?? this.intervalSec,
      jitterSigma: jitterSigma ?? this.jitterSigma,
      gpsMode: gpsMode ?? this.gpsMode,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'commit': commit,
        'intervalSec': intervalSec,
        'jitterSigma': jitterSigma,
        'gpsMode': gpsMode,
      };

  static KqAutoConfig fromJson(Map<String, dynamic> m) => KqAutoConfig(
        enabled: m['enabled'] == true,
        commit: m['commit'] != false,
        intervalSec: (m['intervalSec'] as num?)?.toInt() ?? 20,
        jitterSigma: (m['jitterSigma'] as num?)?.toDouble() ?? 10,
        gpsMode: '${m['gpsMode'] ?? 'auto'}',
      );
}

class KqAutoStore {
  static const String _kConfig = 'kq_auto_config_v1';
  static const String _kCookie = 'kq_auto_cookie';
  static const String _kStudent = 'kq_auto_student';
  static const String _kAuthAt = 'kq_auto_auth_at';
  static const String _kLog = 'kq_auto_log';
  static const String _kDone = 'kq_auto_done';
  static const String _kLastBeat = 'kq_auto_beat';

  static const int _maxLogLines = 200;

  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // ---------- 配置 ----------

  static Future<KqAutoConfig> readConfig() async {
    final p = await _prefs;
    final raw = p.getString(_kConfig);
    if (raw == null || raw.isEmpty) return const KqAutoConfig();
    try {
      return KqAutoConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const KqAutoConfig();
    }
  }

  static Future<void> saveConfig(KqAutoConfig config) async {
    final p = await _prefs;
    await p.setString(_kConfig, jsonEncode(config.toJson()));
  }

  // ---------- 登录态 ----------

  /// 由网页版页面在准备阶段调用：把当前账号的三个令牌和学号存下来。
  static Future<void> saveAuth({
    required String userToken,
    required String ctTicket,
    required String appCtTicket,
    required String studentNo,
  }) async {
    if (userToken.isEmpty) return;
    final p = await _prefs;
    final cookie = <String>[
      'userToken=$userToken',
      if (ctTicket.isNotEmpty) 'CTTICKET=$ctTicket',
      if (appCtTicket.isNotEmpty) 'APPCTTICKET=$appCtTicket',
    ].join('; ');
    await p.setString(_kCookie, cookie);
    await p.setString(_kStudent, studentNo);
    await p.setInt(_kAuthAt, DateTime.now().millisecondsSinceEpoch);
  }

  static Future<String> readCookie() async => (await _prefs).getString(_kCookie) ?? '';

  static Future<String> readStudentNo() async => (await _prefs).getString(_kStudent) ?? '';

  static Future<DateTime?> readAuthAt() async {
    final ms = (await _prefs).getInt(_kAuthAt);
    if (ms == null || ms <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  static Future<void> clearAuth() async {
    final p = await _prefs;
    await p.remove(_kCookie);
    await p.remove(_kStudent);
    await p.remove(_kAuthAt);
  }

  // ---------- 日志 ----------

  static Future<List<String>> readLog() async {
    final p = await _prefs;
    return p.getStringList(_kLog) ?? const <String>[];
  }

  /// 追加一行日志（带时间戳），只保留最后 200 行。
  static Future<void> appendLog(String message) async {
    final p = await _prefs;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final line = '${two(now.hour)}:${two(now.minute)}:${two(now.second)} $message';
    final list = p.getStringList(_kLog)?.toList() ?? <String>[];
    list.add(line);
    if (list.length > _maxLogLines) {
      list.removeRange(0, list.length - _maxLogLines);
    }
    await p.setStringList(_kLog, list);
  }

  static Future<void> clearLog() async {
    final p = await _prefs;
    await p.remove(_kLog);
  }

  // ---------- 当天已处理标记 ----------

  static Future<Set<String>> readDone() async {
    final p = await _prefs;
    final day = _todayKey();
    final raw = p.getString(_kDone);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map[day] as List?)?.map((e) => '$e').toSet() ?? <String>{};
      return list;
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> markDone(String key) async {
    final p = await _prefs;
    final day = _todayKey();
    Map<String, dynamic> map;
    try {
      map = jsonDecode(p.getString(_kDone) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      map = <String, dynamic>{};
    }
    final list = (map[day] as List?)?.map((e) => '$e').toList() ?? <String>[];
    if (!list.contains(key)) list.add(key);
    map[day] = list;
    // 只留今天，避免无限增长。
    final pruned = <String, dynamic>{day: list};
    await p.setString(_kDone, jsonEncode(pruned));
  }

  static Future<void> unmarkDone(String key) async {
    final p = await _prefs;
    final day = _todayKey();
    Map<String, dynamic> map;
    try {
      map = jsonDecode(p.getString(_kDone) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      map = <String, dynamic>{};
    }
    final list = (map[day] as List?)?.map((e) => '$e').toList() ?? <String>[];
    list.remove(key);
    map[day] = list;
    await p.setString(_kDone, jsonEncode(map));
  }

  // ---------- 心跳 ----------

  static Future<void> beat(String note) async {
    final p = await _prefs;
    await p.setString(
      _kLastBeat,
      '${DateTime.now().millisecondsSinceEpoch}|$note',
    );
  }

  static Future<String> readBeat() async {
    final raw = (await _prefs).getString(_kLastBeat) ?? '';
    if (raw.isEmpty) return '';
    final parts = raw.split('|');
    final ms = int.tryParse(parts.first) ?? 0;
    if (ms <= 0) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)} ${parts.length > 1 ? parts[1] : ''}';
  }

  static String _todayKey() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

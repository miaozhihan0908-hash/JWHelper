import 'dart:convert';
import 'dart:io';

/// 后台签到引擎的配置与运行状态。
///
/// **为什么是文件而不是 SharedPreferences**：
/// 前台服务里的后台 isolate 拿不到 UI 侧的内存状态，只能靠磁盘交换。
/// 原本用 SharedPreferences，但它需要插件注册；而后台 isolate 调
/// `DartPluginRegistrant.ensureInitialized()` 注册插件时，
/// `flutter_background_service_android`（6.1.0 起）会在 `registerWith()` 里
/// 抛 "This class should only be used in the main isolate"，把注册流程打断，
/// 后面排队的插件全部没注册上——于是 `SharedPreferences.getInstance()` 抛
/// `MissingPluginException`，`tick()` 第一句就死，心跳永远不动、
/// `Timer.periodic` 根本挂不上。
///
/// 换成纯 `dart:io` 读写一个 JSON 文件后，后台 isolate 不再依赖任何插件，
/// 这个问题从源头消失。
///
/// 这里**不放**密码：登录态用统一认证令牌，由网页版页面在准备阶段推过来。
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
  static const String _kStartMarker = 'kq_auto_start_marker';

  static const int _maxLogLines = 200;

  static File? _fileCache;

  /// 定位存储文件。
  ///
  /// Android 上 `Directory.systemTemp` 是 `/data/user/0/<pkg>/cache`，
  /// 上一层就是应用私有目录，`files/` 在所有 Android 版本上可写且不需要权限。
  /// 其他平台（CI 上跑测试）退回到临时目录下的子目录。
  static File get _file {
    final cached = _fileCache;
    if (cached != null) return cached;
    File? chosen;
    try {
      final appDir = Directory('${Directory.systemTemp.parent.path}/files');
      if (!appDir.existsSync()) appDir.createSync(recursive: true);
      final probe = File('${appDir.path}/.kq_write_probe');
      probe.writeAsStringSync('1', flush: true);
      probe.deleteSync();
      chosen = File('${appDir.path}/kq_auto_store.json');
    } catch (_) {
      try {
        final fallback = Directory('${Directory.systemTemp.path}/kq_auto');
        if (!fallback.existsSync()) fallback.createSync(recursive: true);
        chosen = File('${fallback.path}/kq_auto_store.json');
      } catch (_) {
        chosen = null;
      }
    }
    // 极端情况下连临时目录都不可写：用一个永远读不到内容的路径，
    // 让上层退化成"默认配置 + 空日志"，而不是抛异常把整个 tick 打死。
    _fileCache =
        chosen ?? File('${Directory.systemTemp.path}/kq_auto_store.json');
    return _fileCache!;
  }

  static Map<String, dynamic> _readAll() {
    try {
      final f = _file;
      if (!f.existsSync()) return <String, dynamic>{};
      final raw = f.readAsStringSync();
      if (raw.isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 原子写：先写临时文件再 rename，避免读到写了一半的 JSON。
  static void _writeAll(Map<String, dynamic> data) {
    try {
      final f = _file;
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(data), flush: true);
      tmp.renameSync(f.path);
    } catch (_) {
      // 存储失败不应该让引擎停摆；下一轮还会重试。
    }
  }

  static void _put(String key, Object? value) {
    final m = _readAll();
    if (value == null) {
      m.remove(key);
    } else {
      m[key] = value;
    }
    _writeAll(m);
  }

  // ---------- 配置 ----------

  static Future<KqAutoConfig> readConfig() async {
    final raw = _readAll()[_kConfig];
    if (raw is! String || raw.isEmpty) return const KqAutoConfig();
    try {
      return KqAutoConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const KqAutoConfig();
    }
  }

  static Future<void> saveConfig(KqAutoConfig config) async {
    _put(_kConfig, jsonEncode(config.toJson()));
  }

  // ---------- 登录态 ----------

  /// 由网页版页面在准备阶段调用：把当前账号的令牌和学号存下来。
  ///
  /// **`jsessionId` 是必需的**：智慧考勤 `/unifast/**` 的认证靠的是 Tomcat
  /// 的 `JSESSIONID`（cookie path 正好就是 `/unifast`），只带
  /// `userToken/CTTICKET/APPCTTICKET` 会一律返回
  /// 401「未找到授权信息，请重新登录！」。
  /// 实测对照：不带 JSESSIONID → 401；带上 → 200 并拿到真实数据。
  static Future<void> saveAuth({
    required String userToken,
    required String ctTicket,
    required String appCtTicket,
    required String studentNo,
    String jsessionId = '',
  }) async {
    if (userToken.isEmpty) return;
    final cookie = <String>[
      'userToken=$userToken',
      if (ctTicket.isNotEmpty) 'CTTICKET=$ctTicket',
      if (appCtTicket.isNotEmpty) 'APPCTTICKET=$appCtTicket',
      if (jsessionId.isNotEmpty) 'JSESSIONID=$jsessionId',
    ].join('; ');
    final m = _readAll();
    m[_kCookie] = cookie;
    m[_kStudent] = studentNo;
    m[_kAuthAt] = DateTime.now().millisecondsSinceEpoch;
    _writeAll(m);
  }

  static Future<String> readCookie() async {
    final v = _readAll()[_kCookie];
    return v is String ? v : '';
  }

  static Future<String> readStudentNo() async {
    final v = _readAll()[_kStudent];
    return v is String ? v : '';
  }

  static Future<DateTime?> readAuthAt() async {
    final ms = _readAll()[_kAuthAt];
    final value = ms is num ? ms.toInt() : 0;
    if (value <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(value);
  }

  static Future<void> clearAuth() async {
    final m = _readAll();
    m.remove(_kCookie);
    m.remove(_kStudent);
    m.remove(_kAuthAt);
    _writeAll(m);
  }

  // ---------- 日志 ----------

  static Future<List<String>> readLog() async {
    final v = _readAll()[_kLog];
    if (v is List) return v.map((e) => '$e').toList();
    return <String>[];
  }

  /// 追加一行日志（带时间戳），只保留最后 200 行。
  static Future<void> appendLog(String message) async {
    final m = _readAll();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final line =
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)} $message';
    final existing = m[_kLog];
    final list = existing is List
        ? existing.map((e) => '$e').toList()
        : <String>[];
    list.add(line);
    if (list.length > _maxLogLines) {
      list.removeRange(0, list.length - _maxLogLines);
    }
    m[_kLog] = list;
    _writeAll(m);
  }

  static Future<void> clearLog() async {
    _put(_kLog, null);
  }

  // ---------- 当天已处理标记 ----------

  static Future<Set<String>> readDone() async {
    final raw = _readAll()[_kDone];
    if (raw is! String || raw.isEmpty) return <String>{};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map[_todayKey()] as List?)?.map((e) => '$e').toSet();
      return list ?? <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> markDone(String key) async {
    final day = _todayKey();
    Map<String, dynamic> map;
    final raw = _readAll()[_kDone];
    try {
      map = raw is String && raw.isNotEmpty
          ? jsonDecode(raw) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      map = <String, dynamic>{};
    }
    final list = (map[day] as List?)?.map((e) => '$e').toList() ?? <String>[];
    if (!list.contains(key)) list.add(key);
    // 只留今天，避免无限增长。
    _put(_kDone, jsonEncode(<String, dynamic>{day: list}));
  }

  static Future<void> unmarkDone(String key) async {
    final day = _todayKey();
    Map<String, dynamic> map;
    final raw = _readAll()[_kDone];
    try {
      map = raw is String && raw.isNotEmpty
          ? jsonDecode(raw) as Map<String, dynamic>
          : <String, dynamic>{};
    } catch (_) {
      map = <String, dynamic>{};
    }
    final list = (map[day] as List?)?.map((e) => '$e').toList() ?? <String>[];
    list.remove(key);
    map[day] = list;
    _put(_kDone, jsonEncode(map));
  }

  // ---------- 崩溃取证 ----------

  /// 启动前后各写一次标记。若进程被原生层带崩，标记会停在 `starting`，
  /// 下次打开 App 就能区分"返回 false"和"进程被杀"。
  static Future<void> saveStartMarker(String value) async {
    _put(_kStartMarker, value);
  }

  static Future<String> readStartMarker() async {
    final v = _readAll()[_kStartMarker];
    return v is String ? v : '';
  }

  // ---------- 心跳 ----------

  static Future<void> beat(String note) async {
    _put(_kLastBeat, '${DateTime.now().millisecondsSinceEpoch}|$note');
  }

  static Future<String> readBeat() async {
    final v = _readAll()[_kLastBeat];
    final raw = v is String ? v : '';
    if (raw.isEmpty) return '';
    final parts = raw.split('|');
    final ms = int.tryParse(parts.first) ?? 0;
    if (ms <= 0) return '';
    final at = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)} '
        '${parts.length > 1 ? parts[1] : ''}';
  }

  static String _todayKey() {
    final d = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}

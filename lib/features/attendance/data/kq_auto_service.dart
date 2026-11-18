import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_core/kq_client.dart';
import 'package:JWHelper/features/attendance/data/kq_signer.dart';

/// 前台服务：让签到引擎在 App 退到后台、屏幕熄灭时也能到点干活。
///
/// 为什么必须是前台服务：普通后台任务会被 Android 冻结（WebView 里的脚本
/// 就是这么失效的）。前台服务带常驻通知，系统不会随手回收，其中的 Dart
/// isolate 可以跑定时器。
///
/// 这里要显式声明前台服务类型（`foregroundServiceTypes: dataSync`），并与
/// Manifest 里的 `android:foregroundServiceType` 保持一致：Android 14 起
/// `startForeground` 没有类型会抛 SecurityException，直接把进程带走。
const String kqAutoChannelId = 'kq_auto_channel';
const int kqAutoNotificationId = 8811;

/// 只在 07:00–22:00 之间拉课表，深夜完全不发请求。
const int _activeHourStart = 7;
const int _activeHourEnd = 22;

/// 课表缓存有效期。
const Duration _scheduleTtl = Duration(minutes: 10);

/// 两次签到尝试之间的最小间隔（避免窗口内每 20 秒打一次）。
const Duration _attemptCooldown = Duration(minutes: 3);

/// 在 App 启动时调用一次即可（重复调用无副作用）。
Future<void> kqInitAutoService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: kqAutoEntryPoint,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: kqAutoChannelId,
      initialNotificationTitle: '考勤守护',
      initialNotificationContent: '待命中',
      foregroundServiceNotificationId: kqAutoNotificationId,
      // 必须显式给类型：Android 14+ 的 startForeground 没有类型会直接崩进程
      foregroundServiceTypes: const [AndroidForegroundType.dataSync],
      // 开机自启走的是插件自己的 BootReceiver，这条路径在国产 ROM 上最容易
      // 出问题（配置还没准备好就被拉起来）。宁可让用户开一次 App 再续上。
      autoStartOnBoot: false,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: kqIosEntryPoint,
      onBackground: kqIosEntryPoint,
    ),
  );
}

/// 最近一次启动失败的原因（给界面显示）。
String kqLastStartError = '';

/// 启动后台守护。返回是否已在运行。
///
/// 每一步都单独兜住异常：启动失败要能回话，最怕的是整个进程被原生层带走。
Future<bool> kqStartAutoService() async {
  kqLastStartError = '';
  final service = FlutterBackgroundService();
  try {
    if (await service.isRunning()) return true;
  } catch (e) {
    kqLastStartError = 'isRunning 失败：$e';
  }
  try {
    await kqInitAutoService();
  } catch (e) {
    kqLastStartError = 'configure 失败：$e';
    return false;
  }
  try {
    final ok = await service.startService();
    if (!ok) kqLastStartError = 'startService 返回 false';
    return ok;
  } catch (e) {
    kqLastStartError = 'startService 异常：$e';
    return false;
  }
}

Future<void> kqStopAutoService() async {
  try {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) return;
    service.invoke('stop');
  } catch (_) {}
}

Future<bool> kqIsAutoServiceRunning() async {
  try {
    return await FlutterBackgroundService().isRunning();
  } catch (_) {
    return false;
  }
}

/// 服务状态自检，返回一段可显示的文本。
Future<String> kqServiceDiagnose() async {
  final buf = StringBuffer();
  final cfg = await KqAutoStore.readConfig();
  buf.writeln('开关: ${cfg.enabled ? '开' : '关'}  真提交: ${cfg.commit ? '开' : '关'}');
  bool running = false;
  try {
    running = await FlutterBackgroundService().isRunning();
    buf.writeln('isRunning: $running');
  } catch (e) {
    buf.writeln('isRunning 异常: $e');
  }
  if (kqLastStartError.isNotEmpty) buf.writeln('上次启动错误: $kqLastStartError');
  final beat = await KqAutoStore.readBeat();
  buf.writeln('服务心跳: ${beat.isEmpty ? '（没有，说明服务从没跑起来过）' : beat}');
  final log = await KqAutoStore.readLog();
  buf.writeln('日志行数: ${log.length}');
  return buf.toString();
}

/// 开关是开着的就把服务拉起来（冷启动后恢复）。
Future<bool> kqStartAutoServiceIfEnabled() async {
  final cfg = await KqAutoStore.readConfig();
  if (!cfg.enabled) return false;
  return kqStartAutoService();
}

/// 让服务立刻跑一轮（不等定时器）。
void kqInvokeRunNow() => FlutterBackgroundService().invoke('runNow');

// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void kqAutoEntryPoint(ServiceInstance service) async {
  // 后台 isolate 里插件要显式注册，否则 SharedPreferences 读不到。
  DartPluginRegistrant.ensureInitialized();

  var running = false;
  var lastScheduleAt = DateTime.fromMillisecondsSinceEpoch(0);
  var nextAttemptAt = DateTime.fromMillisecondsSinceEpoch(0);
  var cachedCourses = const <Map<String, dynamic>>[];

  /// 现在是否有可能要签的课（前后各留 30 分钟）。
  bool nearAny(List<Map<String, dynamic>> courses, DateTime now) {
    for (final c in courses) {
      final w = courseWindow(c);
      if (now.isAfter(w.start.subtract(const Duration(minutes: 30))) &&
          now.isBefore(w.end.add(const Duration(minutes: 30)))) {
        return true;
      }
    }
    return false;
  }

  Future<void> refreshCourses(String cookie, String studentNo) async {
    final client = KqClient(cookie: cookie);
    try {
      final resp = await client.schedule(ymd(DateTime.now()), studentNo);
      cachedCourses = coursesOf(resp);
      lastScheduleAt = DateTime.now();
    } catch (e) {
      await KqAutoStore.appendLog('× 课表刷新失败：$e');
    } finally {
      client.close();
    }
  }

  Future<void> tick({bool force = false}) async {
    if (running) return;
    running = true;
    try {
      final now = DateTime.now();
      await KqAutoStore.beat('tick');

      final cfg = await KqAutoStore.readConfig();
      if (!cfg.enabled && !force) return;
      if (!force && (now.hour < _activeHourStart || now.hour >= _activeHourEnd)) {
        return;
      }

      final cookie = await KqAutoStore.readCookie();
      final studentNo = await KqAutoStore.readStudentNo();
      if (cookie.isEmpty || studentNo.isEmpty) {
        await KqAutoStore.appendLog('缺少登录态：先在 App 里打开一次考勤页');
        return;
      }

      // 课表按 TTL 刷新；刷新后判断现在是否接近上课。
      if (force || DateTime.now().difference(lastScheduleAt) > _scheduleTtl) {
        await refreshCourses(cookie, studentNo);
      }
      if (!force && !nearAny(cachedCourses, now)) return;
      if (!force && now.isBefore(nextAttemptAt)) return;

      nextAttemptAt = DateTime.now().add(_attemptCooldown);
      final signer = KqSigner(
        cookie: cookie,
        studentNo: studentNo,
        commit: cfg.commit,
        jitterSigma: cfg.jitterSigma,
      );
      try {
        final n = await signer.runOnce(force: force);
        // 签完立刻让课表失效，下一轮重新拉，好把 firstSignInTime 看回来。
        if (n > 0) lastScheduleAt = DateTime.fromMillisecondsSinceEpoch(0);
      } catch (e) {
        await KqAutoStore.appendLog('× 执行异常：$e');
      } finally {
        signer.close();
      }
    } finally {
      running = false;
    }
  }

  service.on('runNow').listen((_) => tick(force: true));
  service.on('stop').listen((_) async {
    await service.stopSelf();
  });

  await tick();
  Timer.periodic(const Duration(seconds: 20), (_) => tick());
}

/// iOS 侧的回调签名要求返回 bool，这里只是转调同一个入口。
@pragma('vm:entry-point')
Future<bool> kqIosEntryPoint(ServiceInstance service) async {
  kqAutoEntryPoint(service);
  return true;
}

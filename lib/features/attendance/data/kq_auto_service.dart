import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_core/kq_client.dart';
import 'package:JWHelper/features/attendance/data/kq_signer.dart';

/// 前台服务：让签到引擎在 App 退到后台、屏幕熄灭时也能到点干活。
///
/// 为什么必须是前台服务：普通后台任务会被 Android 冻结（WebView 里的脚本
/// 就是这么失效的）。前台服务带常驻通知，系统不会随手回收，其中的 Dart
/// isolate 可以跑定时器。
///
/// 这里刻意不依赖 `flutter_background_service_android`：只用通用接口，
/// 通知内容固定为「考勤守护」，运行状态在 App 内的控制台里看。
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
      autoStartOnBoot: true,
    ),
    iosConfiguration: const IosConfiguration(
      autoStart: false,
      onForeground: kqAutoEntryPoint,
      onBackground: kqAutoEntryPoint,
    ),
  );
}

/// 启动后台守护。返回是否已在运行。
Future<bool> kqStartAutoService() async {
  final service = FlutterBackgroundService();
  if (await service.isRunning()) return true;
  await kqInitAutoService();
  return service.startService();
}

Future<void> kqStopAutoService() async {
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) return;
  service.invoke('stop');
}

Future<bool> kqIsAutoServiceRunning() => FlutterBackgroundService().isRunning();

/// 开关是开着的就把服务拉起来（冷启动 / 开机自启后恢复）。
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

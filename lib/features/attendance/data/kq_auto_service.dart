import 'dart:async';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_core/kq_client.dart';
import 'package:JWHelper/features/attendance/data/kq_gate.dart';
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

/// 通知通道由**原生侧**创建：见 `MainActivity.ensureKqAutoChannel()`。
///
/// 曾经在这里用 flutter_local_notifications 建通道，但它必须先 `initialize()`，
/// 而本项目是 adaptive icon、没有 PNG 版 `@mipmap/ic_launcher`，于是每轮都抛
/// `PlatformException(invalid_icon)`，通道照样不存在——「一开后台守护就闪退」
/// 就是这么来的：`startForeground()` 拿着一个野 channel 发通知，系统判
/// `invalid channel for service notification`，抛
/// `CannotPostForegroundServiceNotificationException` 把进程直接带走。
/// 现在通道在 Activity.onCreate 里原生创建，不依赖任何插件与资源解析。
///
/// 前台服务通知的通道重要性必须是 LOW（不能是 NONE），原生侧已按此设置。
///
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

/// 停用提示的节流点：半小时最多记一行。
///
/// tick 是 20 秒一轮，不节流的话停用期间日志会被同一句话灌满 200 行，
/// 真正的签到记录全被冲掉。
DateTime _gateLogAt = DateTime.fromMillisecondsSinceEpoch(0);

Future<void> _logGateOnce(String message) async {
  final now = DateTime.now();
  if (now.difference(_gateLogAt) < const Duration(minutes: 30)) return;
  _gateLogAt = now;
  await KqAutoStore.appendLog(message);
}

/// 启动后台守护。返回是否已在运行。
///
/// 每一步都单独兜住异常：启动失败要能回话，最怕的是整个进程被原生层带走。
Future<bool> kqStartAutoService() async {
  kqLastStartError = '';
  // 第一道闸：远程开关 + 身份白名单。启动之前就问，别让它先跑起来再被拦。
  await KqGate.load();
  final blocked = KqGate.autoBlocker(await KqAutoStore.readStudentNo());
  if (blocked != null) {
    kqLastStartError = blocked;
    await _logGateOnce('× 自动签到已被停用：$blocked');
    return false;
  }
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
    // 崩溃取证：进程若被原生层带走，这个标记会停在 starting。
    await KqAutoStore.saveStartMarker(
      'starting ${DateTime.now().toIso8601String()}',
    );
    final ok = await service.startService();
    if (ok) {
      await KqAutoStore.saveStartMarker(
        'ok ${DateTime.now().toIso8601String()}',
      );
    } else {
      kqLastStartError = 'startService 返回 false';
      await KqAutoStore.saveStartMarker('false');
    }
    return ok;
  } catch (e) {
    kqLastStartError = 'startService 异常：$e';
    await KqAutoStore.saveStartMarker('error $e');
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
  final marker = await KqAutoStore.readStartMarker();
  buf.writeln('启动标记: ${marker.isEmpty ? '（没有记录）' : marker}');
  if (marker.startsWith('starting') && !running) {
    buf.writeln(
      '  ↑ 标记停在 starting 且服务没跑起来：进程是被原生层带崩的，'
      '不是返回值失败。把这段发我。',
    );
  }
  final beat = await KqAutoStore.readBeat();
  buf.writeln('服务心跳: ${beat.isEmpty ? '（没有，说明服务从没跑起来过）' : beat}');
  final log = await KqAutoStore.readLog();
  buf.writeln('日志行数: ${log.length}');
  buf.writeln('--- 远程开关 ---');
  buf.writeln(KqGate.describe());
  return buf.toString();
}

/// 开关是开着的就把服务拉起来（冷启动后恢复）。
Future<bool> kqStartAutoServiceIfEnabled() async {
  // 冷启动先读本地缓存（不联网）：网络差的时候闸门也得是准的。
  // 真正的回源挂在后台，慢一点不影响启动。
  await KqGate.load();
  KqGate.refreshIfStale();
  final cfg = await KqAutoStore.readConfig();
  if (!cfg.enabled) return false;
  return kqStartAutoService();
}

/// 让服务立刻跑一轮（不等定时器）。
void kqInvokeRunNow() => FlutterBackgroundService().invoke('runNow');

// ---------------------------------------------------------------------------

@pragma('vm:entry-point')
void kqAutoEntryPoint(ServiceInstance service) async {
  // 这里**故意不调** `DartPluginRegistrant.ensureInitialized()`。
  //
  // 它是官方示例的标准写法，但在 flutter_background_service_android 6.1.0+
  // 上会炸：后台 isolate 注册插件时，该包的 registerWith() 会构造
  // FlutterBackgroundServiceAndroid，而它的 factory 里有守卫
  //   if (!_isMainIsolate) throw Exception('...only be used in the main isolate...')
  // 抛出的异常打断整个注册循环，排在它后面的插件全部没注册上，于是
  // SharedPreferences 抛 MissingPluginException，tick() 第一句就死，
  // 心跳永远不动、Timer.periodic 也挂不上——表现为"服务在跑但什么都不做"。
  //
  // 现在存储层是纯 dart:io 文件（kq_auto_store.dart），后台不需要任何插件。

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
      if (!force &&
          (now.hour < _activeHourStart || now.hour >= _activeHourEnd)) {
        return;
      }

      final cookie = await KqAutoStore.readCookie();
      final studentNo = await KqAutoStore.readStudentNo();
      if (cookie.isEmpty || studentNo.isEmpty) {
        await KqAutoStore.appendLog('缺少登录态：先在 App 里打开一次考勤页');
        return;
      }

      // 第二道闸：每一轮都重判。
      // 服务可能是上一版留下的，开关也可能是刚在后台被关掉的——只在启动时
      // 看一眼不够，那要等到下次冷启动才生效。
      await KqGate.load();
      final blocked = KqGate.autoBlocker(studentNo);
      if (blocked != null) {
        await _logGateOnce('× 自动签到已被停用：$blocked');
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

  // 首次 tick 必须吞掉异常：它一旦抛出，下面的 Timer.periodic 就永远不会
  // 执行，后台从此一动不动（之前"心跳始终停在某个旧时间"就是这么来的）。
  try {
    await tick();
  } catch (e) {
    await KqAutoStore.appendLog('× 首次 tick 异常：$e');
  }
  Timer.periodic(const Duration(seconds: 20), (_) async {
    try {
      await tick();
    } catch (e) {
      await KqAutoStore.appendLog('× tick 异常：$e');
    }
  });
}

/// iOS 侧的回调签名要求返回 bool，这里只是转调同一个入口。
@pragma('vm:entry-point')
Future<bool> kqIosEntryPoint(ServiceInstance service) async {
  kqAutoEntryPoint(service);
  return true;
}

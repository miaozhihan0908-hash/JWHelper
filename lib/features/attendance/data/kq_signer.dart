import 'dart:async';
import 'dart:math' as math;

import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_core/geo.dart';
import 'package:JWHelper/features/attendance/data/kq_core/kq_client.dart';

/// 手动触发的范围。
///
/// 自从删掉注入网页的那套脚本，签到/签退就只能从这里手动触发，所以
/// 「只签」「只退」「两边都跑」必须能分开选——否则上课点一下会把签退
/// 也顺带扫一遍。
enum KqSignMode { both, signIn, signOut }

/// 一次签到的执行器：完全绕开 WebView，直接用 Dart 发请求。
///
/// 行为与网页里的脚本保持一致：
/// * 签到窗口 = `max(可点区间起点, 上课前5分钟) ~ min(可点区间终点, 下课)`
/// * 已经签到（状态 1/2/3 或 `firstSignInTime` 非空）就跳过
/// * 提交前走 预记录 → mobileLog → 8~20 秒 → doSign → 人脸结果
/// * 提交后回查课表，确认真入账；没入账就撤销标记，下一轮重试
class KqSigner {
  KqSigner({
    required this.cookie,
    required this.studentNo,
    required this.commit,
    this.jitterSigma = 10,
    this.onLog,
  });

  final String cookie;
  final String studentNo;
  final bool commit;
  final double jitterSigma;
  final void Function(String message)? onLog;

  final math.Random _rnd = math.Random();
  KqClient? _client;

  KqClient get _c => _client ??= KqClient(cookie: cookie);

  void close() => _client?.close();

  void _log(String m) => onLog?.call(m);

  /// 跑一轮。返回成功提交的次数（签到 + 签退）。
  ///
  /// [force] 为 true 时签到与签退都无视时间窗，也跳过「今天已处理」标记。
  /// [mode] 决定只签、只退，还是两边都跑。
  Future<int> runOnce({
    bool force = false,
    KqSignMode mode = KqSignMode.both,
  }) async {
    final now = DateTime.now();
    final day = ymd(now);

    dynamic resp;
    try {
      resp = await _c.schedule(day, studentNo);
    } catch (e) {
      await KqAutoStore.appendLog('× 课表请求失败：$e');
      _log('× 课表请求失败：$e');
      return 0;
    }

    final courses = coursesOf(resp);
    if (courses.isEmpty) {
      // 未登录时服务端返回的是一句纯文本，这里原样抛给日志。
      final tip = resp is String
          ? resp
          : '课表为空 (${resp is Map ? resp['code'] : resp})';
      await KqAutoStore.appendLog('课表不可用：$tip');
      _log('课表不可用：$tip');
      return 0;
    }

    final done = await KqAutoStore.readDone();
    var submitted = 0;

    // ---- 签到 ----
    if (mode != KqSignMode.signOut) {
      for (final c in courses) {
        final id = '${c['id']}';
        final name = '${c['courseName'] ?? '课程'}';

        if (_signedIn(c)) {
          continue;
        }
        final w = _signInWindow(c, now);
        final key = '$id';
        if (!force) {
          if (done.contains(key)) continue;
          if (now.isBefore(w.$1) || now.isAfter(w.$2)) {
            if (_shouldLogWindow(c)) {
              final msg = now.isBefore(w.$1)
                  ? '$name 窗外，${hm(w.$1)} 才开始（现在 ${hm(now)}）'
                  : '$name 窗口已过（${hm(w.$2)} 结束）';
              await KqAutoStore.appendLog(msg);
              _log(msg);
            }
            continue;
          }
        }

        final ok = await _submitSign(c, name: name, force: force);
        if (ok) {
          submitted++;
          await KqAutoStore.markDone(key);
        }
        await Future<void>.delayed(
          Duration(milliseconds: 900 + _rnd.nextInt(1800)),
        );
      }
    }

    // ---- 签退 ----
    if (mode != KqSignMode.signIn) {
      for (final c in courses) {
        if (_signedOut(c)) continue;
        final w = _signOutWindow(c, now);
        // force 也要绕过时间窗，否则「强制」名不副实。
        if (!force && (now.isBefore(w.$1) || now.isAfter(w.$2))) continue;
        final key = 'out|${c['id']}';
        // 与签到分支保持一致：强制跑一轮时不受已完成标记限制。
        if (!force && done.contains(key)) continue;
        final ok = await _submitSignOut(c, name: '${c['courseName'] ?? '课程'}');
        if (ok) {
          submitted++;
          await KqAutoStore.markDone(key);
        }
        await Future<void>.delayed(
          Duration(milliseconds: 900 + _rnd.nextInt(1800)),
        );
      }
    }

    return submitted;
  }

  /// 自检：只读，不改任何状态。返回是否拿到课表。
  Future<bool> selfTest() async {
    try {
      final t0 = DateTime.now();
      final resp = await _c.schedule(ymd(t0), studentNo);
      final courses = coursesOf(resp);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      if (courses.isEmpty) {
        final tip = resp is String ? resp : '课表为空';
        await KqAutoStore.appendLog('自检失败：$tip (${ms}ms)');
        return false;
      }
      await KqAutoStore.appendLog('自检通过：${courses.length} 门课 (${ms}ms)');
      for (final c in courses) {
        final w = _signInWindow(c, DateTime.now());
        await KqAutoStore.appendLog(
          '  ${c['courseName']} ${c['startTime']}-${c['endTime']} '
          'status=${c['signInStatus']} 首次=${c['firstSignInTime'] ?? '-'} '
          '窗口=${hm(w.$1)}~${hm(w.$2)}',
        );
      }
      return true;
    } catch (e) {
      await KqAutoStore.appendLog('自检异常：$e');
      return false;
    }
  }

  // ---------------- 内部 ----------------

  bool _signedIn(Map<String, dynamic> c) {
    final st = '${c['signInStatus']}';
    if (st == '1' || st == '2' || st == '3') return true;
    final first = '${c['firstSignInTime'] ?? ''}'.trim();
    return first.isNotEmpty;
  }

  bool _signedOut(Map<String, dynamic> c) {
    if ('${c['signOutStatus']}' == '1') return true;
    return '${c['signOutTime'] ?? ''}'.trim().isNotEmpty;
  }

  /// 窗口提示去重。
  ///
  /// 必须是 static：每轮 tick 都会 new 一个 KqSigner，实例字段会随对象一起
  /// 丢掉，去重等于没做——实测表现为每 20 秒写一条「XX 窗外」，
  /// 几分钟就把 200 行的日志槽刷满，真正的签到结果被冲没了。
  static final Map<String, DateTime> _windowLoggedAt = <String, DateTime>{};

  bool _shouldLogWindow(Map<String, dynamic> c) {
    final key = '${c['id']}';
    final now = DateTime.now();
    final last = _windowLoggedAt[key];
    if (last != null && now.difference(last) < const Duration(minutes: 10)) {
      return false;
    }
    _windowLoggedAt[key] = now;
    return true;
  }

  /// 服务端给的可点区间，如 "13:40-15:35"。
  (DateTime, DateTime)? _clickRange(dynamic raw, DateTime day) {
    if (raw == null) return null;
    final parts = '$raw'.split('-');
    if (parts.length < 2) return null;
    final a = hhmmOf(parts.first);
    final b = hhmmOf(parts.last);
    if (a == null || b == null) return null;
    return (atTime(day, a), atTime(day, b));
  }

  (DateTime, DateTime) _signInWindow(Map<String, dynamic> c, DateTime now) {
    final base = courseWindow(c);
    final click = _clickRange(c['signInClickRange'], now);
    final lead = base.start.subtract(const Duration(minutes: 5));
    var lo = click != null && click.$1.isAfter(lead) ? click.$1 : lead;
    var hi = base.end;
    if (click != null && click.$2.isBefore(hi)) hi = click.$2;
    if (hi.isBefore(lo)) hi = lo;
    return (lo, hi);
  }

  (DateTime, DateTime) _signOutWindow(Map<String, dynamic> c, DateTime now) {
    final base = courseWindow(c);
    final click = _clickRange(c['signOutClickRange'], now);
    final lead = base.end.subtract(const Duration(minutes: 5));
    final lag = base.end.add(const Duration(minutes: 20));
    var lo = click != null && click.$1.isAfter(lead) ? click.$1 : lead;
    var hi = click != null && click.$2.isBefore(lag) ? click.$2 : lag;
    if (hi.isBefore(lo)) hi = lo;
    return (lo, hi);
  }

  /// 选坐标：围栏基准点 + 高斯抖动（与网页脚本同参数）。
  String _pickGps(Map<String, dynamic> c) {
    final list = c['roomGpsList'];
    final center = fenceCenter(list is List ? list : null);
    if (center == null) throw StateError('该课无围栏坐标');
    if (jitterSigma <= 0) return formatGps(center[0], center[1]);
    final j = jitter(center[0], center[1], jitterSigma);
    return formatGps(j[0], j[1]);
  }

  Future<bool> _submitSign(
    Map<String, dynamic> c, {
    required String name,
    required bool force,
  }) async {
    final now = DateTime.now();
    String gps;
    try {
      gps = _pickGps(c);
    } catch (e) {
      await KqAutoStore.appendLog('$name：$e');
      return false;
    }
    final roomList = c['roomGpsList'];
    final fence = evaluateFence(roomList is List ? roomList : null, gps);
    final inFence = fence.inFence;
    final status = '${c['signInStatus']}';

    final payload = <String, dynamic>{
      'classDate': ymd(now),
      'studentNo': studentNo,
      'paikeId': c['id'],
      'signType': status == '2' ? '2' : '1',
      'gps': gps,
    };
    if (!inFence) payload['signInStatus'] = '4';
    if ('${c['extendStatus']}' == '4') payload['signInStatus'] = '4';

    await KqAutoStore.appendLog(
      '${commit ? '提交' : '演练'}签到 $name gps=$gps 距${fence.distance.toStringAsFixed(0)}m 状态$status',
    );

    if (!commit) {
      await KqAutoStore.appendLog('  (演练模式，没有真发)');
      return false;
    }

    // 与网页版一致的 5 通请求链路。
    await _chain(gps: gps, inFence: inFence, distance: fence.distance);

    dynamic r;
    try {
      r = await _c.doSign(payload);
    } catch (e) {
      await KqAutoStore.appendLog('× 签到异常 $name：$e');
      return false;
    }
    final code = r is Map ? '${r['code']}' : '';
    if (code != '200') {
      await KqAutoStore.appendLog('× 签到失败 $name：${_brief(r)}');
      return false;
    }

    // 人脸结果（与站点同一时序：doSign 之后回报）。
    await _face(gps: gps, passed: true);

    final confirmed = await _confirm(id: '${c['id']}');
    if (confirmed) {
      await KqAutoStore.appendLog('✓ 签到成功 $name（已回查确认入账）');
      return true;
    }
    await KqAutoStore.appendLog('! 接口回 200 但课表没记录，下一轮重试 $name');
    return false;
  }

  Future<bool> _submitSignOut(
    Map<String, dynamic> c, {
    required String name,
  }) async {
    final now = DateTime.now();
    String gps;
    try {
      gps = _pickGps(c);
    } catch (e) {
      await KqAutoStore.appendLog('$name 签退：$e');
      return false;
    }
    final roomList = c['roomGpsList'];
    final fence = evaluateFence(roomList is List ? roomList : null, gps);
    final payload = <String, dynamic>{
      'classDate': ymd(now),
      'studentNo': studentNo,
      'paikeId': c['id'],
      'gps': gps,
    };
    if (!fence.inFence) payload['signOutStatus'] = '4';

    await KqAutoStore.appendLog('${commit ? '提交' : '演练'}签退 $name gps=$gps');
    if (!commit) return false;

    await _face(gps: gps, passed: true);

    dynamic r;
    try {
      r = await _c.doSignOut(payload);
    } catch (e) {
      await KqAutoStore.appendLog('× 签退异常 $name：$e');
      return false;
    }
    final code = r is Map ? '${r['code']}' : '';
    if (code != '200') {
      await KqAutoStore.appendLog('× 签退失败 $name：${_brief(r)}');
      return false;
    }
    await KqAutoStore.appendLog('✓ 签退成功 $name');
    return true;
  }

  /// 预记录 → 设备日志 → 等待 → （doSign 由调用方发）
  Future<void> _chain({
    required String gps,
    required bool inFence,
    required double distance,
  }) async {
    final parts = gps.split(',');
    final now = DateTime.now();
    try {
      // 站点自己的客户端把经度写进 latitude 字段，这里照抄以免字段语义对不上。
      await _c.faceReport({
        'uuid': _uuid(),
        'user_id': studentNo,
        'latitude': parts[0],
        'longitude': parts[1],
        'altitude': inFence ? 1 : 0,
        'accuracy': double.parse(distance.toStringAsFixed(1)),
        'altitudeAccuracy': inFence ? 0 : 4,
        'time': stamp(now),
      });
    } catch (e) {
      await KqAutoStore.appendLog('  预记录失败：${_brief(e)}');
    }
    try {
      await _c.mobileLog({'userId': studentNo, 'type': '3', 'message': gps});
    } catch (e) {
      await KqAutoStore.appendLog('  设备日志失败：${_brief(e)}');
    }
    await Future<void>.delayed(
      Duration(milliseconds: 8000 + _rnd.nextInt(12000)),
    );
  }

  Future<void> _face({required String gps, required bool passed}) async {
    final parts = gps.split(',');
    try {
      await _c.faceReport({
        'uuid': _uuid(),
        'user_id': studentNo,
        'score': double.parse(
          (0.52 + _rnd.nextDouble() * 0.19).toStringAsFixed(4),
        ),
        'threshold': 0.45,
        'status': passed ? 'PASS' : 'FAIL',
        'latitude': parts[0],
        'longitude': parts[1],
        'altitude': 0,
        'accuracy': 0,
        'altitudeAccuracy': 0,
        'time': stamp(DateTime.now()),
      });
    } catch (_) {}
  }

  Future<bool> _confirm({required String id}) async {
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    try {
      final resp = await _c.schedule(ymd(DateTime.now()), studentNo);
      for (final c in coursesOf(resp)) {
        if ('${c['id']}' != id) continue;
        final ok = _signedIn(c);
        await KqAutoStore.appendLog(
          '  回查 status=${c['signInStatus']} 首次=${c['firstSignInTime'] ?? '-'} '
          '${ok ? '已入账' : '未入账'}',
        );
        return ok;
      }
    } catch (e) {
      await KqAutoStore.appendLog('  回查失败：${_brief(e)}');
    }
    return false;
  }

  String _brief(dynamic v) {
    var s = '$v';
    if (s.length > 160) s = '${s.substring(0, 160)}…';
    return s;
  }

  String _uuid() {
    const chars = 'xxxxxxxxxxxx4xxxyxxxxxxxxxxxxxxx';
    final buf = StringBuffer();
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      if (ch == 'x' || ch == 'y') {
        final r = _rnd.nextInt(16);
        buf.write(((ch == 'x' ? r : (r & 0x3 | 0x8))).toRadixString(16));
      } else {
        buf.write(ch);
      }
    }
    return buf.toString();
  }
}

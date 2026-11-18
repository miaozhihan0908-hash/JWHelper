import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:JWHelper/features/attendance/data/kq_auto_service.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_signer.dart';

/// 后台签到控制台。
///
/// 这里的开关控制的是一个**前台服务**：它在 App 退到后台后继续跑定时器，
/// 到点用 Dart 直接调考勤接口签到，不依赖考勤网页是否被打开。
class KqAutoScreen extends StatefulWidget {
  const KqAutoScreen({super.key});

  @override
  State<KqAutoScreen> createState() => _KqAutoScreenState();
}

class _KqAutoScreenState extends State<KqAutoScreen> {
  KqAutoConfig _config = const KqAutoConfig();
  bool _serviceRunning = false;
  bool _busy = false;
  String _authText = '未就绪';
  String _beatText = '-';
  List<String> _log = const <String>[];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final config = await KqAutoStore.readConfig();
    final running = await kqIsAutoServiceRunning();
    final at = await KqAutoStore.readAuthAt();
    final cookie = await KqAutoStore.readCookie();
    final beat = await KqAutoStore.readBeat();
    final log = await KqAutoStore.readLog();
    if (!mounted) return;
    String two(int n) => n.toString().padLeft(2, '0');
    setState(() {
      _config = config;
      _serviceRunning = running;
      _authText = cookie.isEmpty
          ? '未就绪（先打开一次「考勤」页）'
          : (at == null
              ? '已就绪'
              : '已就绪 ${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}');
      _beatText = beat.isEmpty ? '-' : beat;
      _log = log.reversed.toList();
    });
  }

  Future<void> _toast(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggleEnabled(bool enabled) async {
    setState(() => _busy = true);
    try {
      final next = _config.copyWith(enabled: enabled);
      await KqAutoStore.saveConfig(next);
      if (enabled) {
        final started = await kqStartAutoService();
        if (!started) {
          // 有些 ROM 需要先允许通知，再启动前台服务才会成功。
          await Permission.notification.request();
          await kqStartAutoService();
        }
      } else {
        await kqStopAutoService();
      }
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleCommit(bool commit) async {
    final next = _config.copyWith(commit: commit);
    await KqAutoStore.saveConfig(next);
    await _reload();
  }

  Future<void> _selfTest() async {
    setState(() => _busy = true);
    try {
      final cookie = await KqAutoStore.readCookie();
      final studentNo = await KqAutoStore.readStudentNo();
      if (cookie.isEmpty || studentNo.isEmpty) {
        await _toast('还没有登录态：先进「考勤」页打开一次网页版');
        return;
      }
      final signer = KqSigner(
        cookie: cookie,
        studentNo: studentNo,
        commit: false,
        jitterSigma: _config.jitterSigma,
      );
      try {
        final ok = await signer.selfTest();
        await _toast(ok ? '自检通过：Dart 能直接拿到课表' : '自检失败，看看下面的日志');
      } finally {
        signer.close();
      }
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runNow() async {
    setState(() => _busy = true);
    try {
      final cookie = await KqAutoStore.readCookie();
      final studentNo = await KqAutoStore.readStudentNo();
      if (cookie.isEmpty || studentNo.isEmpty) {
        await _toast('还没有登录态：先进「考勤」页打开一次网页版');
        return;
      }
      final signer = KqSigner(
        cookie: cookie,
        studentNo: studentNo,
        commit: _config.commit,
        jitterSigma: _config.jitterSigma,
      );
      try {
        final n = await signer.runOnce(force: true);
        await _toast(n > 0 ? '成功提交 $n 条' : '没有可提交的（原因见日志）');
      } finally {
        signer.close();
      }
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _requestBattery() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) {
      await _toast('已经在电池优化白名单里');
      return;
    }
    final result = await Permission.ignoreBatteryOptimizations.request();
    await _toast(result.isGranted ? '已加入白名单' : '没拿到豁免，去系统设置里手动允许后台运行');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('后台签到'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.dividerColor),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  value: _config.enabled,
                  onChanged: _busy ? null : _toggleEnabled,
                  title: const Text('后台守护'),
                  subtitle: Text(
                    _serviceRunning
                        ? '前台服务运行中，App 退到后台也会到点签'
                        : '开启后常驻通知栏，关掉 App 也能签到',
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  value: _config.commit,
                  onChanged: _busy ? null : _toggleCommit,
                  title: const Text('真提交'),
                  subtitle: Text(
                    _config.commit ? '到点会真的调接口签到' : '只演练：把要发的内容写进日志',
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.vpn_key_outlined, size: 20),
                  title: const Text('登录态'),
                  subtitle: Text(_authText),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.monitor_heart_outlined, size: 20),
                  title: const Text('服务心跳'),
                  subtitle: Text(_beatText),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _selfTest,
                icon: const Icon(Icons.network_check, size: 18),
                label: const Text('自检'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _runNow,
                icon: const Icon(Icons.bolt, size: 18),
                label: const Text('立刻签一轮'),
              ),
              OutlinedButton.icon(
                onPressed: _requestBattery,
                icon: const Icon(Icons.battery_saver, size: 18),
                label: const Text('电池白名单'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  await KqAutoStore.clearLog();
                  await _reload();
                },
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('清空日志'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.terminal, size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      const Text('运行日志', style: TextStyle(fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text('${_log.length} 行', style: theme.textTheme.bodySmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_log.isEmpty)
                    Text(
                      '还没有记录。先点「自检」看看 Dart 侧能不能拿到课表。',
                      style: theme.textTheme.bodySmall,
                    )
                  else
                    ..._log.take(80).map(
                          (line) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text(
                              line,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 11.5,
                                height: 1.45,
                              ),
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '提示：后台签到靠前台服务跑。若被系统杀后台，把本 App 加入'
            '「自启动 / 后台运行」白名单，并调整电池策略为不限制。',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

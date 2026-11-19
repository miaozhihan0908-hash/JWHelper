import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:JWHelper/features/attendance/data/kq_auto_service.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_signer.dart';

/// 自动签到。
///
/// 开关控制的是一个**前台服务**：App 退到后台后它继续跑定时器，到点直接用
/// Dart 调考勤接口签到，不依赖考勤网页是否被打开。
///
/// 页面刻意按「功能」而不是「控制台」来组织：顶部一张状态卡回答"它现在
/// 在不在干活"，中间两个开关，下面是最近动态。自检、立刻签一轮这些偏诊断
/// 的动作收进「更多」里，不占主视觉。
class KqAutoScreen extends StatefulWidget {
  const KqAutoScreen({super.key});

  @override
  State<KqAutoScreen> createState() => _KqAutoScreenState();
}

class _KqAutoScreenState extends State<KqAutoScreen> {
  KqAutoConfig _config = const KqAutoConfig();
  bool _serviceRunning = false;
  bool _busy = false;
  bool _logExpanded = false;

  String _authText = '未就绪';
  DateTime? _beatAt;
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
    final beatAt = await KqAutoStore.readBeatAt();
    final log = await KqAutoStore.readLog();
    if (!mounted) return;
    String two(int n) => n.toString().padLeft(2, '0');
    setState(() {
      _config = config;
      _serviceRunning = running;
      _beatAt = beatAt;
      _authText = cookie.isEmpty
          ? '未就绪'
          : (at == null
                ? '已就绪'
                : '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}');
      _log = log.reversed.toList();
    });
  }

  Future<void> _toast(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---------------- 开关 ----------------

  Future<void> _toggleEnabled(bool enabled) async {
    setState(() => _busy = true);
    try {
      if (!enabled) {
        await KqAutoStore.saveConfig(_config.copyWith(enabled: false));
        await kqStopAutoService();
        await _reload();
        return;
      }

      // 前台服务没有通知会被系统直接掐掉，所以先单独要通知权限，
      // 免得它和启动异常混在一起分不清是谁的问题。
      try {
        final st = await Permission.notification.status;
        if (!st.isGranted) await Permission.notification.request();
      } catch (_) {}

      final started = await kqStartAutoService();
      if (!started) {
        await KqAutoStore.saveConfig(_config.copyWith(enabled: false));
        final reason = kqLastStartError.isEmpty ? '未知原因' : kqLastStartError;
        await KqAutoStore.appendLog('× 自动签到启动失败：$reason');
        await _reload();
        await _toast('启动失败：$reason');
        return;
      }

      await KqAutoStore.saveConfig(_config.copyWith(enabled: true));
      await _reload();
      await _toast('已开启，通知栏会出现「考勤守护」');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleCommit(bool commit) async {
    await KqAutoStore.saveConfig(_config.copyWith(commit: commit));
    await _reload();
  }

  // ---------------- 更多里的动作 ----------------

  Future<void> _selfTest() async {
    setState(() => _busy = true);
    try {
      final cookie = await KqAutoStore.readCookie();
      final studentNo = await KqAutoStore.readStudentNo();
      if (cookie.isEmpty || studentNo.isEmpty) {
        await _toast('还没有登录态，先打开一次「考勤」页');
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
        await _toast(ok ? '自检通过：能直接拿到课表' : '自检没通过，详情在运行记录里');
      } finally {
        signer.close();
      }
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 强制签到：无视时间窗直接提交。
  ///
  /// 这是全 App 唯一能在任意时刻写进考勤记录的动作（定时器有 ±30 分钟闸门），
  /// 所以每次都要先问一句。
  Future<void> _forceSign() async {
    final committed = _config.commit;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('强制签到'),
        content: Text(
          committed
              ? '它会无视时间窗直接提交：不在上课时间也会真的发一次请求，'
                    '可能在校外时间签上一次。\n\n点一次就好，别连点。'
              : '它会无视时间窗直接提交。\n\n现在「真正提交」是关着的，'
                    '所以只会把要发的内容写进记录，不会真发。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('强制'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return;
    await _runSigner(mode: KqSignMode.signIn, force: true);
  }

  /// 跑一轮签到/签退。手动按钮和「强制」共用这里，只是 mode / force 不同。
  Future<void> _runSigner({
    required KqSignMode mode,
    bool force = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final cookie = await KqAutoStore.readCookie();
      final studentNo = await KqAutoStore.readStudentNo();
      if (cookie.isEmpty || studentNo.isEmpty) {
        await _toast('还没有登录态，先打开一次「考勤」页');
        return;
      }
      final signer = KqSigner(
        cookie: cookie,
        studentNo: studentNo,
        commit: _config.commit,
        jitterSigma: _config.jitterSigma,
      );
      try {
        final n = await signer.runOnce(mode: mode, force: force);
        if (!_config.commit) {
          await _toast('演练模式：已经写进记录，没有真发');
        } else if (n > 0) {
          await _toast('已提交 $n 条');
        } else {
          await _toast(force ? '强制跑完了，详情在运行记录里' : '现在没有能签的课（不在窗口内或已签过）');
        }
      } finally {
        signer.close();
      }
      await _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _diagnose() async {
    setState(() => _busy = true);
    try {
      final text = await kqServiceDiagnose();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('服务诊断'),
          content: SingleChildScrollView(
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
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
    await _toast(result.isGranted ? '已加入白名单' : '没拿到豁免，去系统设置里允许后台运行');
  }

  Future<void> _clearLog() async {
    // 日志是出问题时唯一的证据来源（例如"到底是谁签的"），清掉就找不回来了，
    // 所以不再是一点就没。
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空运行记录？'),
        content: const Text('只删本地这份日志，不会撤回已经提交的签到。清掉之后没法再回查。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await KqAutoStore.clearLog();
    await _reload();
  }

  // ---------------- 视图 ----------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('自动签到'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _reload,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _statusCard(theme),
          const SizedBox(height: 14),
          _manualActions(theme),
          const SizedBox(height: 16),
          _switches(theme),
          const SizedBox(height: 16),
          _recentLog(theme),
          const SizedBox(height: 8),
          _advanced(theme),
        ],
      ),
    );
  }

  /// 顶部状态卡：一句话回答"它现在在不在干活"。
  Widget _statusCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final on = _config.enabled && _serviceRunning;
    final idle = _config.enabled && !_serviceRunning;
    final badgeText = on ? '运行中' : (idle ? '待启动' : '未开启');
    final badgeColor = on
        ? const Color(0xFF1F9E58)
        : (idle ? const Color(0xFFB26A00) : scheme.outline);

    final beatText = _beatAgo();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.14),
              scheme.surface,
            ),
            scheme.surface,
          ],
        ),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  on ? Icons.bolt_rounded : Icons.alarm_off_rounded,
                  color: scheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '考勤守护',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      on
                          ? '到点会自动签到，不用盯着手机'
                          : (idle ? '开关是开的，但服务没跑起来' : '开启后到点自动签，App 退到后台也算数'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badgeText,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: badgeColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                _metaItem(theme, Icons.vpn_key_outlined, '登录态', _authText),
                Container(
                  width: 1,
                  height: 26,
                  color: scheme.outlineVariant.withValues(alpha: 0.6),
                ),
                _metaItem(theme, Icons.monitor_heart_outlined, '心跳', beatText),
              ],
            ),
          ),
          if (_lastResultLine() != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(
                  Icons.check_circle_rounded,
                  size: 14,
                  color: Color(0xFF1F9E58),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '最近：${_lastResultLine()}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 日志里最近一次成功签到的原话。日志最新在前，取第一条命中即可。
  String? _lastResultLine() {
    for (final line in _log) {
      if (line.contains('✓ 签到成功')) return line;
    }
    return null;
  }

  Widget _metaItem(ThemeData theme, IconData icon, String label, String value) {
    final scheme = theme.colorScheme;
    return Expanded(
      child: Row(
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _beatAgo() {
    final at = _beatAt;
    if (at == null) return '还没跑过';
    final d = DateTime.now().difference(at);
    if (d.inSeconds < 45) return '${d.inSeconds} 秒前';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// 手动操作区：上课点「签到」、下课前点「签退」，不赶趟就点「强制」。
  ///
  /// 这三个按钮是删掉注入网页那套脚本后接回来的口子——原来它们长在网页右下角
  /// 的球面板里，App 一退到后台就没了，不如放这儿。
  Widget _manualActions(ThemeData theme) {
    final scheme = theme.colorScheme;
    final radius = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '手动操作',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _busy ? null : _selfTest,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.network_check_rounded, size: 15),
              label: const Text('自检'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _runSigner(mode: KqSignMode.signIn),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  shape: radius,
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(Icons.login_rounded, size: 18),
                label: const Text('签到'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _busy
                    ? null
                    : () => _runSigner(mode: KqSignMode.signOut),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  shape: radius,
                  padding: EdgeInsets.zero,
                ),
                icon: const Icon(Icons.logout_rounded, size: 18),
                label: const Text('签退'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _forceSign,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 46),
                  shape: radius,
                  padding: EdgeInsets.zero,
                  foregroundColor: scheme.error,
                  side: BorderSide(color: scheme.error.withValues(alpha: 0.5)),
                ),
                icon: const Icon(Icons.bolt_rounded, size: 18),
                label: const Text('强制'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _switches(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          SwitchListTile.adaptive(
            value: _config.enabled,
            onChanged: _busy ? null : _toggleEnabled,
            contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
            secondary: Icon(Icons.schedule_rounded, color: scheme.primary),
            title: const Text('自动签到'),
            subtitle: Text(_serviceRunning ? '服务在后台运行' : '开启后到点自动签，退到后台也算数'),
          ),
          Divider(
            height: 1,
            indent: 16,
            color: scheme.outlineVariant.withValues(alpha: 0.4),
          ),
          SwitchListTile.adaptive(
            value: _config.commit,
            onChanged: _busy ? null : _toggleCommit,
            contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
            secondary: Icon(
              _config.commit ? Icons.send_rounded : Icons.visibility_outlined,
              color: _config.commit ? scheme.primary : scheme.outline,
            ),
            title: const Text('真正提交'),
            subtitle: Text(
              _config.commit ? '到点会真的调接口签到' : '只演练：把要发的内容写进记录，不提交',
            ),
          ),
        ],
      ),
    );
  }

  Widget _recentLog(ThemeData theme) {
    final scheme = theme.colorScheme;
    final shown = _logExpanded ? _log : _log.take(3).toList();
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.history_toggle_off_rounded,
                size: 18,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '最近动态',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (_log.length > 3)
                TextButton(
                  onPressed: () => setState(() => _logExpanded = !_logExpanded),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(_logExpanded ? '收起' : '全部 ${_log.length} 条'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (_log.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '还没有记录。开着自动签到就行，到点它会自己干活并记在这里。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            )
          else
            ...shown.map(
              (line) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  line,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.5,
                    color: line.contains('×')
                        ? const Color(0xFFC0392B)
                        : (line.contains('✓')
                              ? const Color(0xFF1F9E58)
                              : scheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _advanced(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        leading: Icon(Icons.tune_rounded, color: scheme.onSurfaceVariant),
        title: Text(
          '更多',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant,
          ),
        ),
        children: [
          _actionTile(
            theme,
            icon: Icons.medical_information_outlined,
            title: '服务诊断',
            subtitle: '看前台服务、启动标记、心跳和日志行数',
            onTap: _busy ? null : _diagnose,
          ),
          _actionTile(
            theme,
            icon: Icons.battery_saver_outlined,
            title: '电池优化白名单',
            subtitle: '国产 ROM 需要它才不会杀掉后台服务',
            onTap: _requestBattery,
          ),
          _actionTile(
            theme,
            icon: Icons.delete_outline_rounded,
            title: '清空运行记录',
            subtitle: '只删本地日志，不影响已经提交的签到',
            onTap: _clearLog,
            danger: true,
          ),
        ],
      ),
    );
  }

  Widget _actionTile(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final scheme = theme.colorScheme;
    final tint = danger ? scheme.error : scheme.onSurfaceVariant;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      leading: Icon(icon, size: 20, color: tint),
      title: Text(
        title,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: danger ? scheme.error : null,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      trailing: Icon(
        Icons.chevron_right_rounded,
        size: 18,
        color: scheme.outline,
      ),
    );
  }
}

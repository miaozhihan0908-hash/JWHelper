import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:JWHelper/features/attendance/data/kq_access.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_gate.dart';
import 'package:JWHelper/features/attendance/data/kq_licence.dart';
import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

/// 授权码页面。
///
/// 只做一件事：把作者发的码填进来，然后告诉用户"现在能用多久"。
/// 判定全在 [KqLicence] / [evaluateLicence] 里，这里不重复算。
class KqLicenceScreen extends StatefulWidget {
  const KqLicenceScreen({super.key, this.studentNo = ''});

  /// 当前登录学号；用于校验绑定的授权码。
  final String studentNo;

  @override
  State<KqLicenceScreen> createState() => _KqLicenceScreenState();
}

class _KqLicenceScreenState extends State<KqLicenceScreen> {
  final TextEditingController _input = TextEditingController();
  LicenceEvaluation _eval = const LicenceEvaluation(status: LicenceStatus.none);
  bool _busy = false;
  String _studentNo = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _studentNo = widget.studentNo;
    _reload();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _reload({bool refresh = false}) async {
    await KqAccess.load();
    if (refresh) await KqGate.refreshQuick();
    final no = _studentNo.isEmpty
        ? await KqAutoStore.readStudentNo()
        : _studentNo;
    if (!mounted) return;
    setState(() {
      _studentNo = no;
      _eval = KqLicence.evaluateSync(KqGate.state, no);
    });
  }

  Future<void> _activate() async {
    if (_busy) return;
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '先把授权码填进来');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // 名单可能还没拉到：先补一次回源，免得用户第一次进来就报"无效"。
      if (KqGate.state.hasNoConfig) await KqGate.refreshQuick();
      final err = await KqLicence.activate(
        rawKey: raw,
        gate: KqGate.state,
        studentNo: _studentNo,
      );
      if (!mounted) return;
      if (err != null) {
        setState(() => _error = err);
        return;
      }
      _input.clear();
      FocusScope.of(context).unfocus();
      await _reload();
      if (!mounted) return;
      final eval = _eval;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              eval.ok ? '授权成功：${eval.message}' : '已保存：${eval.message}',
            ),
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本机授权？'),
        content: const Text('只是把这台手机上的授权记录删掉，不会退回到作者那边，'
            '也不会延长或缩短你手里的码。要再用得重新输一次码。'),
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
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await KqLicence.clear();
    await _reload();
  }

  Future<void> _copyDiagnostics() async {
    final buf = StringBuffer()
      ..writeln('=== 授权诊断 ===')
      ..writeln('学号: ${_studentNo.isEmpty ? '（空）' : _studentNo}')
      ..writeln('状态: ${_eval.status.name} / ${_eval.label}')
      ..writeln('说明: ${_eval.message}')
      ..writeln(KqAccess.describe(_studentNo));
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
  }

  // ---------------- 视图 ----------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('授权码'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _busy ? null : () => _reload(refresh: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _statusCard(theme),
          const SizedBox(height: 16),
          Text(
            '输入授权码',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _input,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            maxLines: 1,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              letterSpacing: 1.5,
            ),
            decoration: InputDecoration(
              hintText: 'K7M2Q-9XB3T-VRD8N-HW4PJ-6CYZF',
              hintStyle: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: scheme.outline.withValues(alpha: 0.6),
                letterSpacing: 0.5,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              errorText: _error,
              errorMaxLines: 3,
              suffixIcon: IconButton(
                tooltip: '粘贴',
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                onPressed: _busy
                    ? null
                    : () async {
                        final data = await Clipboard.getData(
                          Clipboard.kTextPlain,
                        );
                        final text = data?.text;
                        if (text != null && text.isNotEmpty) {
                          _input.text = text.trim();
                        }
                      },
              ),
            ),
            onSubmitted: (_) => _activate(),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _activate,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 46),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(_busy ? '正在校验…' : '激活'),
          ),
          const SizedBox(height: 8),
          Text(
            '横杠、空格、大小写都不用管，直接粘进来就行。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          _tipsCard(theme),
          const SizedBox(height: 16),
          _actions(theme),
        ],
      ),
    );
  }

  Widget _statusCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    final eval = _eval;
    final Color tone;
    final IconData icon;
    switch (eval.status) {
      case LicenceStatus.active:
        tone = const Color(0xFF1F9E58);
        icon = Icons.verified_rounded;
      case LicenceStatus.forever:
        tone = const Color(0xFF1F9E58);
        icon = Icons.workspace_premium_rounded;
      case LicenceStatus.expired:
        tone = scheme.error;
        icon = Icons.event_busy_rounded;
      case LicenceStatus.unknown:
      case LicenceStatus.wrongSub:
        tone = scheme.error;
        icon = Icons.gpp_bad_rounded;
      case LicenceStatus.clockBack:
        tone = const Color(0xFFB26A00);
        icon = Icons.history_toggle_off_rounded;
      case LicenceStatus.noTable:
      case LicenceStatus.none:
        tone = scheme.outline;
        icon = Icons.lock_outline_rounded;
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(tone.withValues(alpha: 0.12), scheme.surface),
            scheme.surface,
          ],
        ),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: tone, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      eval.label,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: tone,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      eval.message,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.badge_outlined,
                  size: 15,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  '账号学号',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _studentNo.isEmpty ? '读取中…' : _studentNo,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tipsCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    const lines = <String>[
      '授权码只认一个学号，别人拿到也用不了。',
      '签到、签退、强制签到、自动签到都要授权；到期后四个入口一起停。',
      '期限从第一次激活那一刻开始算。',
      '换手机要重新输一次码；同一个码在到期前都有效。',
      '「自检」和网页版不受影响，还能用来看课表和查记录。',
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 17,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                '说明',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '· ',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _actions(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Column(
      children: [
        ListTile(
          onTap: _busy ? null : _copyDiagnostics,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(
            Icons.copy_all_outlined,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          title: const Text('复制诊断信息'),
          subtitle: Text(
            '粘贴发出来，能看出当前卡在哪一层',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        ListTile(
          onTap: _busy ? null : _clear,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          leading: Icon(
            Icons.delete_outline_rounded,
            size: 20,
            color: scheme.error,
          ),
          title: Text(
            '清除本机授权',
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.error),
          ),
          subtitle: Text(
            '只清这台手机，不影响你手里的码',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

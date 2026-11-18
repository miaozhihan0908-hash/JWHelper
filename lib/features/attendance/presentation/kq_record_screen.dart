import 'package:flutter/material.dart';

import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_authz_probe.dart';
import 'package:JWHelper/features/attendance/data/kq_record_tool.dart';

/// 历史考勤记录：读名单、改结果、跑权限探测。
///
/// 所有写操作默认演练；只有点过确认框才会真发。
class KqRecordScreen extends StatefulWidget {
  const KqRecordScreen({super.key});

  @override
  State<KqRecordScreen> createState() => _KqRecordScreenState();
}

class _KqRecordScreenState extends State<KqRecordScreen> {
  DateTime _day = DateTime.now();
  bool _busy = false;
  bool _dryRun = true;
  String _status = '';
  List<KqAttendanceRecord> _rows = const [];
  List<KqProbeResult> _probes = const [];
  String _cookie = '';
  String _studentNo = '';

  @override
  void initState() {
    super.initState();
    _loadAuth();
  }

  Future<void> _loadAuth() async {
    final cookie = await KqAutoStore.readCookie();
    final no = await KqAutoStore.readStudentNo();
    if (!mounted) return;
    setState(() {
      _cookie = cookie;
      _studentNo = no;
      _status = cookie.isEmpty ? '没有登录态：先打开一次「考勤」页' : '就绪';
    });
  }

  String _d(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  KqRecordTool? _tool() {
    if (_cookie.isEmpty || _studentNo.isEmpty) {
      setState(() => _status = '缺少登录态，先进「考勤」页');
      return null;
    }
    return KqRecordTool(cookie: _cookie, studentNo: _studentNo);
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 180)),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() => _day = picked);
    await _loadRecords();
  }

  Future<void> _loadRecords() async {
    final tool = _tool();
    if (tool == null) return;
    setState(() {
      _busy = true;
      _status = '拉取 ${_d(_day)} 的记录…';
    });
    try {
      final all = await tool.listByDay(_day);
      final mine = tool.mine(all);
      if (!mounted) return;
      setState(() {
        _rows = mine;
        _status = mine.isEmpty
            ? '这一天没有我的考勤记录（共拉到 ${all.length} 条）'
            : '共 ${mine.length} 条记录';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '拉取失败：$e');
    } finally {
      tool.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runProbe() async {
    final tool = _tool();
    if (tool == null) return;
    final paikeId = _rows.isNotEmpty
        ? _rows.first.paikeId
        : await _firstPaikeIdOfDay(tool);
    if (paikeId.isEmpty) {
      if (mounted) setState(() => _status = '这一天没有课，没法探测');
      tool.close();
      return;
    }
    setState(() {
      _busy = true;
      _status = '探测中（全部只读）…';
    });
    try {
      final probe = KqAuthzProbe(cookie: _cookie, studentNo: _studentNo);
      final results = await probe.run(paikeId: paikeId);
      probe.close();
      if (!mounted) return;
      setState(() {
        _probes = results;
        final open = results.where((r) => r.open).length;
        _status = '探测完成：$open/${results.length} 条显示门是开的';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '探测失败：$e');
    } finally {
      tool.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _firstPaikeIdOfDay(KqRecordTool tool) async {
    final courses = await tool.coursesOn(_day);
    if (courses.isEmpty) return '';
    return '${courses.first['id'] ?? ''}';
  }

  Future<void> _editRecord(KqAttendanceRecord record) async {
    final chosen = <KqFlag>{};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('改考勤结果'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(record.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(record.subtitle, style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: KqFlag.values.map((f) {
                  final on = chosen.contains(f);
                  return FilterChip(
                    label: Text(f.label),
                    selected: on,
                    onSelected: (v) => setLocal(() {
                      if (v) {
                        chosen.add(f);
                      } else {
                        chosen.remove(f);
                      }
                    }),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              Text(
                'studentSignId=${record.signId}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty ? null : () => Navigator.of(ctx).pop(true),
              child: Text(_dryRun ? '演练一次' : '确认修改'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final tool = _tool();
    if (tool == null) return;
    setState(() {
      _busy = true;
      _status = '提交中…';
    });
    try {
      final result = await tool.applyResult(record, chosen, dryRun: _dryRun);
      if (!mounted) return;
      setState(() => _status = result.message);
    } catch (e) {
      if (mounted) setState(() => _status = '提交失败：$e');
    } finally {
      tool.close();
      if (mounted) setState(() => _busy = false);
    }
    if (!_dryRun) await _loadRecords();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史考勤记录'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _pickDay,
            icon: const Icon(Icons.event),
            tooltip: '选择日期',
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
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.calendar_today, size: 20),
                  title: Text(_d(_day)),
                  subtitle: Text(_status.isEmpty ? '选日期后点「拉记录」' : _status),
                ),
                SwitchListTile(
                  value: _dryRun,
                  onChanged: (v) => setState(() => _dryRun = v),
                  title: const Text('演练模式'),
                  subtitle: Text(_dryRun ? '只打印 payload，不发请求' : '真提交：会改服务端记录'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _loadRecords,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('拉记录'),
              ),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _runProbe,
                icon: const Icon(Icons.policy, size: 18),
                label: const Text('权限探测'),
              ),
            ],
          ),
          if (_probes.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('探测矩阵', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    ..._probes.map((p) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${p.verdict}  ${p.name}  HTTP=${p.http ?? '-'} code=${p.code.isEmpty ? '-' : p.code}',
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11.5,
                                  color: p.open
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.onSurface,
                                ),
                              ),
                              if (p.msg.isNotEmpty)
                                Text(
                                  '    ${p.msg}',
                                  style: const TextStyle(
                                      fontFamily: 'monospace', fontSize: 11),
                                ),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '还没有记录。点「拉记录」按日期读取。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            ..._rows.map((r) => Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: theme.dividerColor),
                  ),
                  child: ListTile(
                    dense: true,
                    title: Text(r.title),
                    subtitle: Text(r.subtitle),
                    trailing: TextButton(
                      onPressed: _busy || !r.hasSignId ? null : () => _editRecord(r),
                      child: const Text('改'),
                    ),
                  ),
                )),
          const SizedBox(height: 16),
          Text(
            '改历史记录比签到留的痕重：服务端多半有操作日志（谁、何时、改了什么）。'
            '探测里的写请求全部用不存在的 id，不会改动任何记录。',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_record_tool.dart';

/// 考勤记录：按日期读取课表与出勤明细。
///
/// **这里刻意没有任何"改动"入口**。那几个接口（考勤名单 / 考勤记录 /
/// 改结果 / 代签到）都挂在教师端页面 `teacher/kqResult` 下，学生号调用
/// 一律返回 `403 接口未授权！`——实测四条全被拦，连只读的都不给。
/// 服务端是在网关按角色拦的，不在业务参数层，没有可以绕的缝。
///
/// 所以本页只做一件事：把服务端允许读到的东西读出来给人看。
/// 给一个点了必然 403 的按钮，只会让用户以为是 App 坏了。
class KqRecordScreen extends StatefulWidget {
  const KqRecordScreen({super.key});

  @override
  State<KqRecordScreen> createState() => _KqRecordScreenState();
}

class _KqRecordScreenState extends State<KqRecordScreen> {
  DateTime _day = DateTime.now();
  bool _busy = false;
  String _status = '';
  List<KqAttendanceRecord> _rows = const [];
  List<String> _notes = const [];
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
      final fetch = await tool.fetchDay(_day);
      final mine = tool.mine(fetch.records);
      if (!mounted) return;
      setState(() {
        _rows = mine;
        _notes = fetch.notes;
        _status = mine.isEmpty
            ? '没有可显示的记录（拉到 ${fetch.records.length} 条）— 原因见下方'
            : '共 ${mine.length} 条记录';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '拉取失败：$e');
    } finally {
      tool.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('考勤记录'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _pickDay,
            icon: const Icon(Icons.event_outlined),
            tooltip: '选择日期',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: Icon(
                    Icons.calendar_today_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  title: Text(_d(_day)),
                  subtitle: Text(_status.isEmpty ? '选日期后读取' : _status),
                  trailing: IconButton(
                    onPressed: _busy ? null : _pickDay,
                    icon: const Icon(Icons.chevron_right_rounded, size: 20),
                    tooltip: '换一天',
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 16,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: _busy ? null : _loadRecords,
                          icon: const Icon(Icons.download_rounded, size: 18),
                          label: const Text('读取这一天'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_notes.isNotEmpty) ...[
            const SizedBox(height: 14),
            _notesCard(theme),
          ],
          const SizedBox(height: 14),
          if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                '没有记录。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            ..._rows.map(
              (r) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: ListTile(
                  dense: true,
                  title: Text(r.title),
                  subtitle: Text(r.subtitle),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '说明：出勤明细属于教师端口径的接口，学生号调用会被服务端按角色拒绝'
            '（403 接口未授权）。这里只做读取尝试，不会、也无法修改任何记录。',
            style: theme.textTheme.bodySmall?.copyWith(
              height: 1.6,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _notesCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '读取明细',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () async {
                  await showDialog<void>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('原始回话'),
                      content: SingleChildScrollView(
                        child: SelectableText(
                          _notes.join('\n'),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                          ),
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
                },
                icon: const Icon(Icons.copy_all_rounded, size: 18),
                tooltip: '可选中复制',
              ),
            ],
          ),
          const SizedBox(height: 2),
          ..._notes.map(
            (n) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                n,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

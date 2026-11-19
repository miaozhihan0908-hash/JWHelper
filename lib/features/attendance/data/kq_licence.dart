import 'dart:convert';

import 'package:JWHelper/shared/remote_gate/remote_gate.dart';

import 'kq_auto_store.dart';

/// 本机授权状态。
///
/// 只保存"哪个码、什么时候激活的、最后一次在线是什么时候"。码本身不存，
/// 存的是它的指纹——就算有人翻到这份文件，也拿不到能发给别人的码。
class KqLicence {
  static LicenceActivation? _current;
  static bool _loaded = false;

  static LicenceActivation? get activation => _current;

  /// 冷启动读一次本地记录。不联网，重复调用无副作用。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await KqAutoStore.readLicence();
      if (raw.isEmpty) return;
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic>) _current = LicenceActivation.fromJson(m);
    } catch (_) {
      // 记录坏了就当没激活过，让用户重新输码。
    }
  }

  /// 同步判定。调用前必须先 [load] 过，否则会把"已激活"误判成"未激活"。
  static LicenceEvaluation evaluateSync(GateState gate, String studentNo) =>
      evaluateLicence(
        gate: gate,
        activation: _current,
        studentNo: studentNo,
        now: DateTime.now().toUtc(),
      );

  static Future<LicenceEvaluation> evaluate(
    GateState gate,
    String studentNo,
  ) async {
    await load();
    return evaluateSync(gate, studentNo);
  }

  /// 输一个码。成功返回 null，失败返回一句能直接显示的话。
  ///
  /// 同一个码重复输入**不会重置起算点**——否则反复重输就能无限续期。
  static Future<String?> activate({
    required String rawKey,
    required GateState gate,
    required String studentNo,
  }) async {
    await load();

    if (gate.hasNoConfig) {
      return '还没有拿到授权名单，请连上网络后重试';
    }

    final key = normalizeLicenceKey(rawKey);
    if (key == null) {
      return '授权码无效，看看是不是抄错了一位';
    }

    final kid = kidOf(key);
    final record = gate.licenceOf(kid);
    if (record == null) {
      return '授权码无效，或者已被作者撤销';
    }

    final no = studentNo.trim();
    if (record.sub != '*' && record.sub.isNotEmpty && record.sub != no) {
      return '这个授权码绑定的是学号 ${record.sub}';
    }

    final now = DateTime.now().toUtc();
    final prev = _current;
    final sameKey = prev != null && prev.kid == kid;
    _current = LicenceActivation(
      kid: kid,
      activatedAt: sameKey ? prev.activatedAt : now,
      lastSeenAt: now,
    );
    await _save();

    final eval = evaluateSync(gate, no);
    if (!eval.ok) {
      // 激活了但立刻判定不通过（例如码今天就到期），照样记一笔。
      await KqAutoStore.appendLog('! 授权已写入但当前不可用：${eval.message}');
      return eval.message;
    }
    await KqAutoStore.appendLog('✓ 授权已激活：${eval.label}（${eval.message}）');
    return null;
  }

  /// 清掉本机授权（不影响别人，也不会退回作者的名单）。
  static Future<void> clear() async {
    _current = null;
    _loaded = true;
    await KqAutoStore.clearLicence();
    await KqAutoStore.appendLog('· 已清除本机授权');
  }

  /// 每次回源 / 每轮 tick 推一下"最后一次在线"，用来发现系统时间被回拨。
  static Future<void> touch() async {
    await load();
    final cur = _current;
    if (cur == null) return;
    final now = DateTime.now().toUtc();
    if (!now.isAfter(cur.lastSeenAt)) return;
    _current = cur.copyWith(lastSeenAt: now);
    await _save();
  }

  static Future<void> _save() async {
    final cur = _current;
    if (cur == null) return;
    try {
      await KqAutoStore.saveLicence(jsonEncode(cur.toJson()));
    } catch (_) {}
  }
}

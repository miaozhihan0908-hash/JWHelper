/// 远程开关的客户端：拉取 → 验签 → 缓存 → 回退。
///
/// 这个文件**不依赖任何业务**，换一个 App 拷走、换掉 appId 和公钥即可。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'gate_config.dart';
import 'gate_verify.dart';

/// 从本地缓存读一份原始配置文本（没有就返回空串）。
typedef GateCacheReader = Future<String> Function();

/// 把原始配置文本写进本地缓存。
typedef GateCacheWriter = Future<void> Function(String raw);

/// 设计要点：
///
/// * **只认签名过的**：配置带 Ed25519 签名，公钥在宿主 App 里写死。改一个
///   字节没重签，整份丢弃——包括弹窗文案，别人没法往里塞钓鱼引导。
/// * **缓存存的也是带签名的原文**：冷启动重新验一遍，改本地缓存文件等于
///   让这份配置作废，而不是生效。
/// * **不降级**：新配置的 `issuedAt` 比手上这份旧就忽略。否则把网络打回旧
///   快照（改 hosts、掐 DNS 缓存）就能把已经关掉的功能重新打开。
/// * **拉不到就用缓存，缓存也没有就用编译默认**（全开）。任何一层坏掉都
///   不会让宿主 App 变砖。
class GateClient {
  GateClient({
    required this.appId,
    required this.publicKeyHex,
    required this.mirrors,
    required this.readCache,
    required this.writeCache,
    this.ttl = const Duration(hours: 6),
    this.minGap = const Duration(minutes: 10),
    this.timeout = const Duration(seconds: 8),
    this.clockSkew = const Duration(hours: 6),
  }) : _publicKey = hexToBytes(publicKeyHex);

  /// 在配置里认领哪一节：`apps.<appId>`。
  final String appId;

  final String publicKeyHex;

  /// 镜像按序尝试，第一个验签通过的就用。
  final List<String> mirrors;

  final GateCacheReader readCache;
  final GateCacheWriter writeCache;

  /// 后台轮询的间隔：距上次回源超过这么久才重拉。
  final Duration ttl;

  /// 界面主动要求刷新时的最小间隔，避免每次进页面都打一次网络。
  final Duration minGap;

  /// 单次网络超时。
  final Duration timeout;

  /// 容忍的时钟偏差：签发的 `issuedAt` 比本机时间晚这么多以内仍接受。
  final Duration clockSkew;

  final Uint8List _publicKey;

  GateState _current = GateState.open;
  bool _loaded = false;
  DateTime _lastAttempt = DateTime.fromMillisecondsSinceEpoch(0);

  GateState get current => _current;

  /// 最近一次回源时间；从没回过源返回 null。
  DateTime? get lastAttemptAt =>
      _lastAttempt.millisecondsSinceEpoch == 0 ? null : _lastAttempt;

  /// 读一次缓存并验签（每进程只读一次）。不联网。
  ///
  /// 缓存不检查 `expiresAt`：它在拿到手那一刻是合法签名的，作者签过的意思
  /// 就是「照这个执行」。过期只用来挡新配置，不用来撤销已经生效的这份——
  /// 否则断网等到期，停用就自动解除了。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await readCache();
      if (raw.isEmpty) return;
      final state = parseSigned(raw, source: 'cache', enforceExpiry: false);
      if (state != null) _current = state;
    } catch (_) {
      // 缓存读不出来就当没有，用默认值。
    }
  }

  /// 距上次回源超过 [ttl] 才真的拉，不阻塞调用方。
  void refreshIfStale() {
    if (DateTime.now().difference(_lastAttempt) < ttl) return;
    unawaited(refresh());
  }

  /// 界面侧主动回源：仍受 [minGap] 节流，但比 [ttl] 短得多，
  /// 作者改完文案用户下次进页面就能看到。
  void refreshSoon() {
    if (DateTime.now().difference(_lastAttempt) < minGap) return;
    unawaited(refresh(force: true));
  }

  /// 拉一次配置。全部镜像都拿不到（或验签不过）时退回缓存。
  ///
  /// [force] 为 true 时用 [minGap] 而不是 [ttl] 判断要不要真的发请求。
  Future<GateState> refresh({bool force = false}) async {
    final now = DateTime.now();
    final gap = now.difference(_lastAttempt);
    if (gap < (force ? minGap : ttl)) {
      if (!_loaded) await load();
      return _current;
    }
    _lastAttempt = now;

    for (final url in mirrors) {
      final hit = await _fetchOne(url);
      if (hit == null) continue;
      // 回滚保护：更旧的一份配置不许覆盖手上这份。
      final prev = _current.issuedAt;
      final next = hit.state.issuedAt;
      if (prev != null && next != null && next.isBefore(prev)) continue;

      _current = hit.state;
      _loaded = true;
      try {
        await writeCache(hit.body);
      } catch (_) {
        // 写不进去不影响本次生效，只是下次冷启动会退回旧值。
      }
      return hit.state;
    }

    await load();
    return _current;
  }

  Future<({String body, GateState state})?> _fetchOne(String url) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = timeout;
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      req.headers.set(HttpHeaders.userAgentHeader, 'remote-gate/$appId');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      final body = await utf8.decodeStream(resp).timeout(timeout);
      final state = parseSigned(body, source: url);
      if (state == null) return null;
      return (body: body, state: state);
    } catch (_) {
      return null;
    } finally {
      client?.close(force: true);
    }
  }

  /// 解析并验签。任何一环不对都返回 null。
  ///
  /// 签名覆盖的是「去掉 sig 之后、所有层级按 key 排序」的紧凑 JSON，
  /// 免得字段顺序变了就验不过。
  GateState? parseSigned(
    String body, {
    String source = 'cache',
    bool enforceExpiry = true,
  }) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();
      final sigB64 = '${map['sig'] ?? ''}';
      if (sigB64.isEmpty) return null;

      final payload = Map<String, dynamic>.from(map)..remove('sig');
      final ok = ed25519Verify(
        message: utf8.encode(canonicalJson(payload)),
        signature: base64Decode(sigB64),
        publicKey: _publicKey,
      );
      if (!ok) return null;

      final now = DateTime.now().toUtc();
      final issued = DateTime.tryParse('${map['issuedAt'] ?? ''}')?.toUtc();
      final expires = DateTime.tryParse('${map['expiresAt'] ?? ''}')?.toUtc();
      // 签发时间来自"未来"太远 → 可疑，丢弃。
      if (issued != null && issued.isAfter(now.add(clockSkew))) return null;
      if (enforceExpiry && expires != null && now.isAfter(expires)) return null;

      final section = _sectionOf(map);
      if (section == null) return null;

      return GateState(
        flags: GateFlags.fromJson(<String, dynamic>{
          'features': section['features'],
          'killAll': section['killAll'],
        }),
        notice: GateNotice.fromJson(
          (section['notice'] as Map?)?.cast<String, dynamic>() ??
              const <String, dynamic>{},
        ),
        source: source,
        syncedAt: now,
        issuedAt: issued,
        expiresAt: expires,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从整份文档里挑出本 App 那一节。
  ///
  /// * 有 `apps`：多 App 格式，只认 `apps.<appId>`；没提到我这个 App 就返回
  ///   null（这份配置不是给我用的，不能拿它套默认值）。
  /// * 没有 `apps`：单 App 老格式，整份文档就是本节。
  Map<String, dynamic>? _sectionOf(Map<String, dynamic> map) {
    final apps = map['apps'];
    if (apps == null) return map;
    if (apps is! Map) return null;
    final me = apps[appId];
    if (me is! Map) return null;
    return me.cast<String, dynamic>();
  }

  /// 去掉空值、所有层级按 key 排序后的紧凑 JSON。签名和验签两边必须一致。
  static String canonicalJson(Map<String, dynamic> m) => jsonEncode(_sorted(m));

  static Object? _sorted(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((e) => '$e').toList()..sort();
      final out = <String, Object?>{};
      for (final k in keys) {
        final value = v[k];
        if (value == null) continue;
        out[k] = _sorted(value);
      }
      return out;
    }
    if (v is List) return v.map(_sorted).toList();
    return v;
  }
}

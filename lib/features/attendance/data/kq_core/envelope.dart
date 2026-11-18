/// 请求信封：clientId / scope / X-SIGN-B，以及 /publicKey 的获取与解密。
library;

import 'dart:convert';
import 'dart:io';

import 'md5.dart';
import 'sm2.dart';

const String kBaseHost = 'https://qdxt.sdpei.edu.cn:7083';
const String kApiPrefix = '/unifast';
const String kClientId = 'bVS46ElU';
const String kScope = 'H5';

/// 前端 request.*.js 里硬编码的客户端私钥，用来解开服务端加密响应。
const String kClientPriKey =
    '32CA2B8D01ACD23D3416EED21AF20B6CA0302E5B6CC3982D3CF0471B95DE1ED5';

const String kUa = 'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

/// 前端 keyWord()：排序后的 key+String(value) 拼串，再 md5 大写。
String signB(String cipher) => md5Hex(utf8.encode('reqData$cipher')).toUpperCase();

String signP(String cipher) => md5Hex(utf8.encode('reqData$cipher')).toUpperCase();

class KqHttp {
  final String? token;
  final String? cookie;
  final HttpClient _client;
  String? _pub;

  KqHttp({this.token, this.cookie, bool insecure = true})
      : _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 20) {
    if (insecure) {
      _client.badCertificateCallback = (cert, host, port) => true;
    }
  }

  Future<HttpClientResponse> _send(String method, String path,
      {Map<String, String>? headers, String? body}) async {
    final uri = Uri.parse('$kBaseHost$kApiPrefix$path');
    final req = await _client.openUrl(method, uri);
    req.headers.set('clientId', kClientId);
    req.headers.set('scope', kScope);
    req.headers.set('User-Agent', kUa);
    req.headers.set('Accept', 'application/json, text/plain, */*');
    req.headers.set('Origin', kBaseHost);
    req.headers.set('Referer', '$kBaseHost/pages/kq/kqHome');
    if (token != null && token!.isNotEmpty) req.headers.set('JwtToken', token!);
    if (cookie != null && cookie!.isNotEmpty) req.headers.set('Cookie', cookie!);
    headers?.forEach((k, v) => req.headers.set(k, v));
    if (body != null) {
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }
    return req.close();
  }

  static Future<String> _read(HttpClientResponse r) async {
    final chunks = <int>[];
    await for (final c in r) {
      chunks.addAll(c);
    }
    return utf8.decode(chunks, allowMalformed: true);
  }

  /// 取服务端公钥：响应本身是密文，需要用客户端私钥解开。
  Future<String> publicKey() async {
    if (_pub != null) return _pub!;
    final r = await _send('GET', '/publicKey');
    var raw = (await _read(r)).trim();
    if (raw.startsWith('"') && raw.endsWith('"')) {
      raw = raw.substring(1, raw.length - 1);
    }
    String? key;
    if (raw.startsWith('{')) {
      key = (jsonDecode(raw) as Map)['key'] as String?;
    } else if (raw.startsWith('04')) {
      final plain = utf8.decode(decrypt(raw, kClientPriKey));
      key = (jsonDecode(plain) as Map)['key'] as String?;
    }
    if (key == null || key.isEmpty) {
      throw StateError('无法解析 /publicKey 响应: ${raw.substring(0, raw.length > 120 ? 120 : raw.length)}');
    }
    _pub = key.trim();
    return _pub!;
  }

  /// 解响应：明文 JSON 直接解析，04 开头的先用客户端私钥解密。
  dynamic decode(String raw) {
    final t = raw.trim();
    if (t.startsWith('{') || t.startsWith('[')) return jsonDecode(t);
    if (t.startsWith('04')) {
      try {
        return jsonDecode(utf8.decode(decrypt(t, kClientPriKey)));
      } catch (_) {
        // 落到下面返回原文
      }
    }
    return t;
  }

  Future<dynamic> post(String path, Map<String, dynamic> payload) async {
    final pub = await publicKey();
    final body = jsonEncode(payload);
    final cipher = encrypt(utf8.encode(body), pub);
    final r = await _send('POST', path,
        headers: {
          'Content-Type': 'application/json;charset=UTF-8',
          'X-SIGN-B': signB(cipher),
        },
        body: jsonEncode({'reqData': cipher}));
    return decode(await _read(r));
  }

  Future<dynamic> get(String path, [Map<String, dynamic>? payload]) async {
    var url = path;
    Map<String, String> headers = {};
    if (payload != null && payload.isNotEmpty) {
      final qs = payload.entries
          .map((e) => '${e.key}=${jsonEncode(e.value)}')
          .join('&');
      final cipher = encrypt(utf8.encode(qs), await publicKey());
      url = '$path?reqData=$cipher';
      headers = {'X-SIGN-P': signP(cipher)};
    }
    final r = await _send('GET', url, headers: headers);
    return decode(await _read(r));
  }

  void close() => _client.close(force: true);
}

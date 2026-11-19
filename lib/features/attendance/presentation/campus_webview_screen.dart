import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:JWHelper/features/attendance/presentation/attendance_account_form.dart';
import 'package:JWHelper/features/attendance/presentation/attendance_provider.dart';
import 'package:JWHelper/features/attendance/presentation/attendance_web_actions.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_service.dart';
import 'package:JWHelper/features/attendance/data/kq_auto_store.dart';
import 'package:JWHelper/features/attendance/data/kq_gate.dart';
import 'package:JWHelper/features/attendance/presentation/kq_auto_screen.dart';

/// 智慧考勤网页版（底部导航「考勤」tab 主体）。
///
/// 打开时会先把当前账号的 SSO 令牌写入 Cookie 与 Web Storage，尽量免登录进入；
/// 未配置账号或令牌失效时，页面自身的登录入口仍然可用，不会阻塞访问。
/// 操作按钮位于首页标题栏，通过 [AttendanceWebActions] 调用这里的动作。
///
/// **注意**：本页**不能**触发软件键盘 —— 外层 `HomeScreen` 没有
/// `resizeToAvoidBottomInset`，键盘弹出会盖住输入框且无法上滚。仓库内的
/// `ssoLogin` 页面内部是弹窗式输入，弹窗自己会跟随键盘，所以同样安全。若以后
/// 要在考勤页里直接放普通输入框，必须先给外层补上键盘避让
/// （例如改用 `Padding` + `MediaQuery.viewInsets`）。
class CampusWebViewScreen extends StatefulWidget {
  /// 智慧考勤网页版地址。
  static const String attendanceWebUrl =
      'https://qdxt.sdpei.edu.cn:7083/pages/sdpei/sso';

  const CampusWebViewScreen({super.key});

  @override
  State<CampusWebViewScreen> createState() => _CampusWebViewScreenState();
}

class _CampusWebViewScreenState extends State<CampusWebViewScreen> {
  // 这两个对象都要求平台实现存在，因此只在支持的平台创建（见 initState）。
  WebViewCookieManager? _cookieManager;
  WebViewController? _controller;
  bool _isSupportedPlatform = true;
  String _activeToken = '';
  bool _isLoading = true;
  bool _isPreparing = true;
  bool _registeredActions = false;
  AttendanceWebActions? _actions;
  String? _prepareError;

  /// 自动签到的实时状态：右下角胶囊靠它变色，不用点进去才知道开没开。
  KqAutoConfig _autoConfig = const KqAutoConfig();
  bool _autoRunning = false;

  /// 自动签到被远程停用了。胶囊要能直接显示这件事，不用点进去才知道。
  bool _gateLocked = false;
  Timer? _autoPoller;

  @override
  void initState() {
    super.initState();

    // Windows / Linux 上没有任何 WebView 实现（插件只覆盖 Android/iOS/macOS），
    // 直接构造控制器会抛异常。这类平台不建控制器，改为给出浏览器入口。
    _isSupportedPlatform = WebViewPlatform.instance != null;

    if (_isSupportedPlatform) {
      _cookieManager = WebViewCookieManager();
      _controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0x00000000))
        ..setNavigationDelegate(
          NavigationDelegate(
            onPageStarted: (String url) {
              if (mounted) setState(() => _isLoading = true);
            },
            onPageFinished: (String url) async {
              await _injectTokenToWebStorage();
              if (mounted) setState(() => _isLoading = false);
            },
          ),
        );

      _configureAndroidWebViewPermissions();
    } else {
      _isLoading = false;
      _isPreparing = false;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _actions = context.read<AttendanceWebActions>();
      _actions!.register(
        reload: _prepareAndLoad,
        relogin: _refreshAuth,
        editAccount: _editAccount,
        openInBrowser: _openInBrowser,
      );
      _registeredActions = true;
      _prepareAndLoad();
    });

    // 胶囊的状态要自己跟：服务是后台另一条链路在跑，页面这边不监听它。
    _pollAutoState();
    _autoPoller = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _pollAutoState(),
    );
  }

  /// 读一次后台服务的真实状态（开关 + 进程是否活着），变了才重建。
  Future<void> _pollAutoState() async {
    try {
      await KqGate.load();
      final config = await KqAutoStore.readConfig();
      final studentNo = await KqAutoStore.readStudentNo();
      final locked = KqGate.autoBlocker(studentNo) != null;
      final running = config.enabled && await kqIsAutoServiceRunning();
      if (!mounted) return;
      if (config.enabled == _autoConfig.enabled &&
          config.commit == _autoConfig.commit &&
          running == _autoRunning &&
          locked == _gateLocked) {
        return;
      }
      setState(() {
        _autoConfig = config;
        _autoRunning = running;
        _gateLocked = locked;
      });
    } catch (_) {
      // 读不到就维持上一次的状态，不打断页面。
    }
  }

  @override
  void dispose() {
    _autoPoller?.cancel();
    _autoPoller = null;
    // 页面被销毁（例如账号被清除）后标题栏不应再留着按钮。
    // 注销会通知监听者，而 dispose 可能发生在 build/dispose 阶段，
    // 因此推迟到当前帧结束再执行。
    if (_registeredActions) {
      final actions = _actions;
      _registeredActions = false;
      _actions = null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => actions?.unregister(),
      );
    }
    super.dispose();
  }

  /// Android 的 WebView 默认拒绝网页的摄像头与定位请求，这里改为按系统权限放行；
  /// iOS 这两项都交给系统弹窗处理，无需干预。
  ///
  /// 定位是签到/签退的必要条件：网页里的 `navigator.geolocation` 只有在宿主 App
  /// 拿到定位授权后才会返回坐标，所以这里申请系统权限后再决定是否放行。
  void _configureAndroidWebViewPermissions() {
    final platformController = _controller?.platform;
    if (platformController is! AndroidWebViewController) {
      return;
    }

    platformController
      ..setGeolocationEnabled(true)
      ..setOnPlatformPermissionRequest((request) async {
        if (request.types.contains(WebViewPermissionResourceType.camera)) {
          final status = await Permission.camera.request();
          if (!status.isGranted) {
            request.deny();
            return;
          }
        }
        request.grant();
      })
      ..setGeolocationPermissionsPromptCallbacks(
        onShowPrompt: (request) async {
          final status = await Permission.locationWhenInUse.request();
          if (!status.isGranted) {
            _notifyLocationDenied(
              permanentlyDenied: status.isPermanentlyDenied,
            );
          }
          return GeolocationPermissionsResponse(
            allow: status.isGranted,
            // 只在已授权时记住，否则用户去系统设置打开定位后回来还能再次询问。
            retain: status.isGranted,
          );
        },
      );
  }

  void _notifyLocationDenied({required bool permanentlyDenied}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: const Text('签到需要定位权限，请允许「教务小助手」使用定位后重试'),
        action: permanentlyDenied
            ? const SnackBarAction(label: '去设置', onPressed: openAppSettings)
            : null,
      ),
    );
  }

  Future<void> _prepareAndLoad() async {
    // 没有 WebView 实现时（Windows/Linux）页面只有浏览器入口，无需加载。
    if (!_isSupportedPlatform) {
      return;
    }

    if (mounted) {
      setState(() {
        _isPreparing = true;
        _prepareError = null;
      });
    }

    try {
      final provider = context.read<AttendanceProvider>();
      // 有凭据就先确保令牌可用（失败也继续，网页版自己还有登录入口）。
      if (provider.hasSavedCredentials) {
        await provider.ensureAuthorizedWithRecovery();
      }

      _activeToken = provider.userToken;
      final targetUri = _buildTargetUri(
        CampusWebViewScreen.attendanceWebUrl,
        _activeToken,
      );

      await _setAuthCookies(
        uri: targetUri,
        userToken: _activeToken,
        ctTicket: provider.ctTicket,
        appCtTicket: provider.appCtTicket,
      );

      await _syncBackgroundAuth(provider, targetUri);

      final headers = <String, String>{
        if (_activeToken.isNotEmpty) 'Authorization': 'Bearer $_activeToken',
        if (_activeToken.isNotEmpty) 'X-User-Token': _activeToken,
      };

      await _controller?.loadRequest(targetUri, headers: headers);
      if (mounted) {
        setState(() {
          _isPreparing = false;
        });
      }
    } catch (e) {
      // 鉴权准备失败不影响浏览网页版，只在页面上给一条提示。
      if (mounted) {
        setState(() {
          _isPreparing = false;
          _prepareError = '免登录准备失败: $e';
        });
      }
    }
  }

  /// 重新登录并重载页面（网页版里登录态失效时使用）。
  Future<void> _refreshAuth() async {
    final provider = context.read<AttendanceProvider>();
    if (!provider.hasSavedCredentials) {
      _showSnack('未配置智慧考勤账号，请在设置中填写学号与密码');
      return;
    }

    final error = await provider.refreshSession();
    if (!mounted) return;

    if (error != null) {
      _showSnack(error);
      return;
    }

    await _prepareAndLoad();
    if (!mounted) return;
    _showSnack('已重新登录');
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _editAccount() async {
    final saved = await AttendanceAccountDialog.show(context);
    if (!saved || !mounted) return;
    await _prepareAndLoad();
  }

  Uri _buildTargetUri(String rawUrl, String userToken) {
    var uri = Uri.parse(rawUrl);
    if (userToken.isEmpty) {
      return uri;
    }

    if (uri.host == 'jxzlbz.sdpei.edu.cn') {
      return Uri.parse(
        'https://jxzlbz.sdpei.edu.cn/h5/#/pages/login/caslogin?userToken=${Uri.encodeComponent(userToken)}',
      );
    }

    if (uri.host.contains('sdpei.edu.cn')) {
      final query = Map<String, String>.from(uri.queryParameters);
      query.putIfAbsent('userToken', () => userToken);

      var fragment = uri.fragment;
      if (fragment.isNotEmpty && !fragment.contains('userToken=')) {
        fragment =
            '$fragment${fragment.contains('?') ? '&' : '?'}userToken=${Uri.encodeQueryComponent(userToken)}';
      }

      uri = uri.replace(queryParameters: query, fragment: fragment);
    }

    return uri;
  }

  Future<void> _setAuthCookies({
    required Uri uri,
    required String userToken,
    required String ctTicket,
    required String appCtTicket,
  }) async {
    final domains = <String>{uri.host};
    if (uri.host.endsWith('sdpei.edu.cn')) {
      domains.addAll(<String>[
        'jxzlbz.sdpei.edu.cn',
        'sso.sdpei.edu.cn',
        'static.sdpei.edu.cn',
        'pubfilestor.sdpei.edu.cn',
      ]);
    }

    for (final domain in domains) {
      if (userToken.isNotEmpty) {
        await _cookieManager?.setCookie(
          WebViewCookie(
            name: 'userToken',
            value: userToken,
            domain: domain,
            path: '/',
          ),
        );
      }
      if (ctTicket.isNotEmpty) {
        await _cookieManager?.setCookie(
          WebViewCookie(
            name: 'CTTICKET',
            value: ctTicket,
            domain: domain,
            path: '/',
          ),
        );
      }
      if (appCtTicket.isNotEmpty) {
        await _cookieManager?.setCookie(
          WebViewCookie(
            name: 'APPCTTICKET',
            value: appCtTicket,
            domain: domain,
            path: '/',
          ),
        );
      }
    }
  }

  /// 把登录态同步给后台签到引擎，并在开关打开时确保前台服务在跑。
  ///
  /// 后台 isolate 读不到这里的内存状态，所以令牌必须落盘一次；之后即使
  /// 页面被销毁、App 退到后台，引擎也能自己发请求。
  Future<void> _syncBackgroundAuth(
    AttendanceProvider provider,
    Uri targetUri,
  ) async {
    try {
      // 智慧考勤 /unifast/** 的接口认证靠 Tomcat 的 JSESSIONID（cookie path
      // 就是 /unifast），而它是 HttpOnly —— JS 的 document.cookie 读不到，
      // 只能走原生 CookieManager。少了它，后台引擎每个请求都吃 401
      // 「未找到授权信息，请重新登录！」，表现就是课表拉不到、记录拉不到。
      String jsessionId = '';
      try {
        // webview_flutter 4.14 起 getCookies 是具名参数 domain:（早期版本
        // 是位置参数，照旧写法会编译失败）。
        final cookies = await WebViewCookieManager().getCookies(
          domain: Uri.parse('https://qdxt.sdpei.edu.cn:7083/unifast/'),
        );
        for (final cookie in cookies) {
          if (cookie.name == 'JSESSIONID' && cookie.value.isNotEmpty) {
            jsessionId = cookie.value;
            break;
          }
        }
      } catch (_) {
        // 取不到就退化成不带 session：接口会 401，但不影响网页版本身。
      }
      await KqAutoStore.saveAuth(
        userToken: provider.userToken,
        ctTicket: provider.ctTicket,
        appCtTicket: provider.appCtTicket,
        studentNo: provider.savedUsername,
        jsessionId: jsessionId,
      );
      final config = await KqAutoStore.readConfig();
      if (config.enabled) {
        await kqStartAutoService();
      }
    } catch (_) {
      // 同步失败不影响网页版本身。
    }
  }

  /// 免责声明正文。首次进入自动签到页必须先过这一关。
  static const String _disclaimerText =
      '本功能仅供交流学习和技术研究使用，禁止用于商业或非法用途。'
      '使用者应自行承担使用风险。作者不对任何第三方转载、复制、打包、修改、'
      '分发、售卖或传播本插件的行为负责，由此产生的一切责任由传播者或使用者'
      '自行承担。下载、安装或使用即视为同意本声明。如不同意，请立即停止使用'
      '并删除本插件。';

  /// 打开自动签到页。没同意过声明就先弹窗拦截，「不同意」直接留在考勤页。
  Future<void> _openAutoScreen() async {
    var accepted = false;
    try {
      accepted = await KqAutoStore.readDisclaimerAccepted();
    } catch (_) {
      // 读不到就当没同意过，宁可多问一次。
    }
    if (!accepted) {
      if (!mounted) return;
      final go = await _showDisclaimer();
      if (go != true) return;
    }
    if (!mounted) return;

    // 远程总闸：拉一次最新状态再决定放不放行（最多等两秒，拿不到就用缓存）。
    await KqGate.load();
    await KqGate.refreshQuick();
    if (!mounted) return;
    final studentNo = await KqAutoStore.readStudentNo();
    if (KqGate.killAll || !KqGate.identityAllows(studentNo)) {
      await _showGateNotice();
      await _pollAutoState();
      return;
    }

    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const KqAutoScreen()));
    // 回来立刻对齐一次：用户可能刚在里面开了或关了服务。
    await _pollAutoState();
  }

  /// 弹免责声明，返回 true 表示用户选「进入功能」。
  ///
  /// 「我已知晓，不再提示」只在点了「进入功能」时才落盘：随手关掉弹窗不会
  /// 记住，下次进来还会再问一遍。
  Future<bool> _showDisclaimer() async {
    var dontAsk = false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final theme = Theme.of(ctx);
            return AlertDialog(
              title: const Text('使用声明'),
              contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              content: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _disclaimerText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.75,
                        fontSize: 13.5,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 10),
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => setLocal(() => dontAsk = !dontAsk),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Checkbox(
                                value: dontAsk,
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                onChanged: (v) =>
                                    setLocal(() => dontAsk = v ?? false),
                              ),
                            ),
                            const Expanded(child: Text('我已知晓，不再提示')),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('不同意'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('进入功能'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == true && dontAsk) {
      try {
        await KqAutoStore.saveDisclaimerAccepted();
      } catch (_) {}
    }
    return result == true;
  }

  /// 整个功能被停用时拦在门口的弹窗。文案来自远程配置，作者随时能改。
  Future<void> _showGateNotice() async {
    final notice = KqGate.notice;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(notice.title),
        content: SingleChildScrollView(child: Text(notice.body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(notice.confirm),
          ),
        ],
      ),
    );
  }

  /// 右下角状态胶囊：既是进自动签到的入口，也直接回答「它现在在不在干活」。
  ///
  /// 原来这里是个纯图标悬浮球——关着和开着长得一模一样，想确认状态只能点进去。
  /// 现在改成带状态点的胶囊：绿=运行中，琥珀=开关开了但服务没起来，灰=没开，
  /// 主题色=演练（真正提交关着，只写记录不发请求）。
  Widget _buildAutoEntry() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = _autoConfig.enabled;
    final running = enabled && _autoRunning;

    final Color tone;
    final String label;
    if (_gateLocked) {
      tone = scheme.error;
      label = '已停用';
    } else if (!enabled) {
      tone = scheme.outline;
      label = '自动签到';
    } else if (!running) {
      tone = const Color(0xFFB26A00);
      label = '待启动';
    } else if (!_autoConfig.commit) {
      tone = scheme.primary;
      label = '演练中';
    } else {
      tone = const Color(0xFF1F9E58);
      label = '自动签到';
    }

    return Material(
      color: scheme.surface.withValues(alpha: 0.94),
      shape: const StadiumBorder(),
      elevation: 3,
      shadowColor: scheme.shadow.withValues(alpha: 0.25),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: _openAutoScreen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 7, 6, 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _injectTokenToWebStorage() async {
    if (_activeToken.isEmpty) {
      return;
    }
    final escaped = _activeToken
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    try {
      await _controller?.runJavaScript(
        "window.localStorage.setItem('userToken', '$escaped');"
        "window.sessionStorage.setItem('userToken', '$escaped');",
      );
    } catch (_) {
      // 非 H5 页面上执行脚本会失败，忽略即可。
    }
  }

  /// 这里原本会往网页里注入 `assets/kq/kq.user.js`（一套网页版自动签到脚本）。
  ///
  /// 删掉的原因：
  /// * 它只有考勤页开着、并且 App 在前台时才有效，退到后台就被浏览器节流，
  ///   实际等于没有；真正常驻签到的能力在 [KqAutoScreen] 那条前台服务链路上。
  /// * 它和 App 引擎是两套独立实现、两套开关、两套日志，出问题时要先分辨
  ///   "到底是谁签的"，排查成本远高于收益。
  /// * 它自己的配置只要版本号对不上就会把 `autoStart` 强行改回 true，
  ///   是个埋着的意外开关。
  Future<void> _openInBrowser() async {
    // 浏览器兜底同样希望带上登录态：先把令牌准备好；
    // 准备失败也照常打开，网页内可以自己登录。
    final provider = context.read<AttendanceProvider>();
    if (provider.hasSavedCredentials) {
      await provider.ensureAuthorizedWithRecovery();
    }
    if (!mounted) return;

    final uri = _buildTargetUri(
      CampusWebViewScreen.attendanceWebUrl,
      provider.userToken,
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开浏览器')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSupportedPlatform) {
      return _buildUnsupportedPlatformView();
    }

    return Column(
      children: [
        if (_prepareError != null) _buildPrepareBanner(_prepareError!),
        Expanded(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller!),
              if (_isPreparing || _isLoading)
                const Center(child: CircularProgressIndicator()),
              Positioned(right: 10, bottom: 12, child: _buildAutoEntry()),
            ],
          ),
        ),
      ],
    );
  }

  /// Windows / Linux 等没有 WebView 实现的平台：给出浏览器入口，而不是崩溃。
  Widget _buildUnsupportedPlatformView() {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.web_asset_off,
              size: 40,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            const Text(
              '当前平台不支持应用内考勤网页',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '可以改用系统浏览器打开考勤页面，签到、签退与统计功能一致。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _openInBrowser,
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: const Text('用浏览器打开'),
            ),
          ],
        ),
      ),
    );
  }

  /// 免登录准备失败时的提示条：只在网页版上方做提示，不遮挡网页。
  Widget _buildPrepareBanner(String message) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              Icons.info_outline,
              size: 16,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$message，可在网页内直接登录',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(onPressed: _refreshAuth, child: const Text('重新登录')),
          ],
        ),
      ),
    );
  }
}

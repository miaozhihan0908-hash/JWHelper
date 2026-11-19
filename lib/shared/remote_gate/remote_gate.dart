/// 远程开关模块的统一出口。
///
/// 用法（宿主 App 只需要这几行）：
///
/// ```dart
/// final client = GateClient(
///   appId: 'myapp',
///   publicKeyHex: '…',
///   mirrors: ['https://raw.githubusercontent.com/OWNER/REPO/main/gate.json'],
///   readCache: () async => store.read('gate'),
///   writeCache: (raw) async => store.write('gate', raw),
/// );
/// final gate = GateController(client: client);
/// await gate.init();
/// gate.refreshSoon();
/// if (!gate.allows(identity, 'autoSign')) { … }
/// ```
library;

export 'gate_client.dart';
export 'gate_config.dart';
export 'gate_controller.dart';
export 'gate_verify.dart';
export 'licence_evaluate.dart';
export 'licence_key.dart';

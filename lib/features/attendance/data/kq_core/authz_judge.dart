/// 权限探测的判定规则。
///
/// 单独放一个文件、零依赖：既能被 Flutter 侧引用，也能用纯 `dart run`
/// 在本地跑用例（这个判定直接决定"门开没开"的结论，值得单独验）。
library;

/// 返回 `开` / `关` / `不明`。
///
/// 顺序很关键：「未找到授权信息，请重新登录！」同时含「未找到」和「授权」，
/// 认证类必须先判，否则会把未登录误读成"角色已放行"。
String judgeProbe({int? http, required String code, required String msg}) {
  if (code == '200') return '开';
  // 1) 认证层：没登录 / 令牌过期
  if (msg.contains('授权') || msg.contains('登录') || msg.contains('过期')) {
    return '关';
  }
  // 2) 授权层：登录了但角色不够
  if (msg.contains('权限') ||
      msg.contains('无权') ||
      msg.contains('角色') ||
      msg.contains('非法') ||
      msg.contains('禁止')) {
    return '关';
  }
  // 3) 走到业务层：前两层都过了，只是这条数据不存在
  if (msg.contains('不存在') ||
      msg.contains('未找到') ||
      msg.contains('找不到') ||
      msg.contains('参数')) {
    return '开';
  }
  if (http == 403) return '关';
  return '不明';
}

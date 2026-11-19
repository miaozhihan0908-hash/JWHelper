import 'dart:io' show Platform;

import 'package:flutter/material.dart';

/// 使用说明。
///
/// **为什么按平台分两份**：Android 和 iOS 能做的事不一样。Android 有前台服务，
/// 退到后台也能签；iOS 没有常驻定时器，后台自动签到基本不成立。混在一起写，
/// 用户会照着做不到的步骤反复试，然后以为是自己设置错了。
///
/// 从 1.0.2 起多了一套授权码：签到相关的四个入口都要先在 App 里输码。
/// 说明里必须先讲清楚这件事，否则用户会以为是按钮坏了。
class KqHelpScreen extends StatelessWidget {
  const KqHelpScreen({super.key});

  static bool get isIOS => Platform.isIOS;

  /// 设置里那一行显示的副标题。
  static String get subtitle =>
      isIOS ? 'iOS 版：授权码、怎么装、能做到什么' : 'Android 版：授权码、开启、保活与排查';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sections = isIOS ? _iosSections() : _androidSections();

    return Scaffold(
      appBar: AppBar(title: const Text('使用说明')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _platformBanner(theme),
          const SizedBox(height: 14),
          for (final s in sections) ...[
            _sectionCard(theme, s),
            const SizedBox(height: 12),
          ],
          const SizedBox(height: 4),
          Text(
            '本功能仅供交流学习和技术研究使用，禁止用于商业或非法用途。'
            '使用者应自行承担使用风险。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.7,
            ),
          ),
        ],
      ),
    );
  }

  Widget _platformBanner(ThemeData theme) {
    final scheme = theme.colorScheme;
    final ios = isIOS;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.16),
              scheme.surface,
            ),
            scheme.surface,
          ],
        ),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(
            ios ? Icons.phone_iphone_rounded : Icons.android_rounded,
            size: 26,
            color: scheme.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ios ? 'iOS 版' : 'Android 版',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  ios ? '手动签到可用，后台自动签到不成立' : '后台自动签到可用，需要放行电池优化',
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
    );
  }

  Widget _sectionCard(ThemeData theme, _Section s) {
    final scheme = theme.colorScheme;
    final danger = s.danger;
    return Container(
      decoration: BoxDecoration(
        color: danger
            ? Color.alphaBlend(
                scheme.error.withValues(alpha: 0.08),
                scheme.surface,
              )
            : scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: danger
              ? scheme.error.withValues(alpha: 0.35)
              : scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                s.icon,
                size: 17,
                color: danger ? scheme.error : scheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: danger ? scheme.error : null,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...s.items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: (danger ? scheme.error : scheme.primary)
                            .withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      item,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- Android ----------------

  List<_Section> _androidSections() => const [
    _Section(
      icon: Icons.play_circle_outline_rounded,
      title: '第一次用（四步）',
      items: [
        '设置 → 智慧考勤账号，填「智慧山体」的学号和密码，保存后会立刻校验。',
        '回到底部「考勤」页，等网页加载完一次。这一步把登录态交给后台引擎，之后不用再开网页。',
        '点右下角胶囊 → 在「授权码」页把作者发给你的码填进去，点激活。没激活之前，签到相关的按钮都是灰的。',
        '回到自动签到页，打开「自动签到」。通知栏出现「考勤守护」就是跑起来了。',
      ],
    ),
    _Section(
      icon: Icons.vpn_key_outlined,
      title: '授权码怎么用',
      items: [
        '码由作者发给你，一个码只认一个学号，别人拿到也用不了。',
        '期限从你第一次激活那一刻开始算：7 天、30 天、永久，或者作者说的任意天数。',
        '横杠、空格、大小写都不用管，直接粘进去；抄错一位会提示「授权码无效」。',
        '页面右上角能看到剩余天数；「更多 → 远程状态 / 授权」里能看到完整状态。',
        '换手机要重新输一次码；同一个码在到期前都有效，重装也照样能用。',
        '到期后会弹出提示、四个签到入口一起变灰；「自检」和网页版不受影响。',
      ],
    ),
    _Section(
      icon: Icons.battery_saver_outlined,
      title: '必须做的保活',
      items: [
        '自动签到页 → 更多 → 电池优化白名单，点一下放行。',
        '小米、华为、OPPO、vivo 还要在系统设置里额外允许「自启动」和「后台运行」，只点白名单不够。',
        '胶囊显示「待启动」= 开关是开的但服务没起来，通常就是被系统掐了。',
      ],
    ),
    _Section(
      icon: Icons.touch_app_outlined,
      title: '手动补一下',
      items: [
        '「签到」「签退」：只处理当前在窗口内的课，窗外和已经签过的会自动跳过。',
        '「强制」：无视时间窗直接提交，每次都会先弹确认——这是唯一能在任意时刻写进考勤的动作，点一次就好，别连点。',
        '标题右侧的「自检」只是读一次课表，不写任何东西、也不需要授权码，用它确认现在通不通。',
      ],
    ),
    _Section(
      icon: Icons.circle,
      title: '胶囊几个颜色什么意思',
      items: [
        '绿点：服务在跑，到点会真签。',
        '琥珀「待启动」：开关开了，但后台服务没起来。',
        '琥珀「未激活」：还没输授权码，或者码过期了。',
        '灰点：没有开启。',
        '蓝点「演练中」：「真正提交」关着，只把要发的内容写进记录，不发请求。',
        '红点「已停用」：作者在后台停用了签到功能，点进去会看到一段说明。',
      ],
    ),
    _Section(
      icon: Icons.build_circle_outlined,
      title: '出问题时',
      items: [
        '状态卡上的「心跳」如果停在几小时前，说明服务被杀了，回「必须做的保活」再看一遍。',
        '签不上：先点「自检」，再点「签到」看提示；还是不行就用下面的导出日志。',
        '更多 → 导出日志，会把整段运行记录复制到剪贴板，直接粘贴发出来即可。',
        '授权码相关的问题：授权页 → 复制诊断信息，里面能看到卡在哪一层。',
      ],
    ),
    _Section(
      icon: Icons.info_outline_rounded,
      title: '作者可以随时暂停功能',
      items: [
        '签到相关的功能（自动、签到、签退、强制）都在作者手里有一个总开关，改一次不用更新版本。',
        '被暂停时，点胶囊会弹出一段说明，这是作者写的；看完关掉就回考勤页，不会进功能。',
        '恢复同样是实时的：作者打开之后，你下次进这个页面就正常了。',
        '自检和网页版不受影响，暂停期间照样能看课表、查记录。',
      ],
    ),
    _Section(
      icon: Icons.block_rounded,
      title: '做不到的事',
      danger: true,
      items: [
        '改历史签到记录：那几个接口挂在教师端，学生号调用一律 403，是网关按角色拦的。',
        '看同学的考勤：同上。',
        '撤销已经签上的记录：学生端没有这个入口。',
      ],
    ),
  ];

  // ---------------- iOS ----------------

  List<_Section> _iosSections() => const [
    _Section(
      icon: Icons.download_outlined,
      title: '怎么装（IPA 未签名）',
      items: [
        '这个包没有签名，双击是装不上的。iPhone 上要用 Sideloadly、AltStore 这类工具自签。',
        '免费 Apple ID 签名 7 天过期，到期重新签一次；付费开发者账号可以签 1 年。',
        '签名后首次打开如果提示「未受信任的企业级开发者」，去 设置 → 通用 → VPN与设备管理 里信任一下。',
      ],
    ),
    _Section(
      icon: Icons.play_circle_outline_rounded,
      title: '第一次用',
      items: [
        '设置 → 智慧考勤账号，填学号和密码。',
        '打开底部「考勤」页，允许定位和相机（签到要用）。',
        '右下角胶囊 → 同意声明 → 进自动签到页。',
        '还没输授权码的话，先点「输入授权码」把作者发的码填进去，否则签到按钮都是灰的。',
      ],
    ),
    _Section(
      icon: Icons.vpn_key_outlined,
      title: '授权码怎么用',
      items: [
        '码由作者发给你，一个码只认一个学号。',
        '期限从第一次激活那一开始算；到期后自动锁上，输新的码即可。',
        '横杠、空格、大小写都不用管；换手机要重新输一次。',
        '「自检」和网页版不需要授权码。',
      ],
    ),
    _Section(
      icon: Icons.block_rounded,
      title: 'iOS 上后台自动签到不成立',
      danger: true,
      items: [
        'iOS 不允许 App 常驻定时器，锁屏或切走后没有任何东西在按点执行。',
        '「自动签到」开关可以打开，但系统只在它愿意的时候唤醒后台任务——可能一天几次，也可能很久不唤醒。别指望它替你签。',
        '已经补了 BGTaskScheduler 配置让这条路存在，但那是「有机会」，不是「到点一定执行」。',
        '想在 iOS 上签到，就打开 App 点「签到」或「签退」。',
      ],
    ),
    _Section(
      icon: Icons.touch_app_outlined,
      title: '手动签到 / 签退 / 强制',
      items: [
        '「签到」「签退」：只处理当前在窗口内的课。',
        '「强制」：无视时间窗，每次先弹确认，点一次就好。',
        '这三件事都必须在 App 处于前台时点，切到别的 App 就会中断。',
      ],
    ),
    _Section(
      icon: Icons.build_circle_outlined,
      title: '出问题时',
      items: [
        '签到提示定位失败：设置 → 隐私与安全性 → 定位服务，把本 App 改成「使用期间」。',
        '考勤网页白屏：右上角菜单 → 用浏览器打开，网页版本身功能一致。',
        '更多 → 导出日志，复制出来发出来即可。',
        '授权码相关：授权页 → 复制诊断信息。',
      ],
    ),
    _Section(
      icon: Icons.info_outline_rounded,
      title: '作者可以随时暂停功能',
      items: [
        '签到相关功能在作者手里有一个总开关，改一次不用更新版本。',
        '被暂停时，点胶囊会弹出一段作者写的说明，关掉就回考勤页。',
        '恢复也是实时的，下次进页面就正常。',
      ],
    ),
  ];
}

class _Section {
  final IconData icon;
  final String title;
  final List<String> items;
  final bool danger;

  const _Section({
    required this.icon,
    required this.title,
    required this.items,
    this.danger = false,
  });
}

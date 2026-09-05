import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';



import '../../app/theme.dart';

import '../../services/message_store.dart';

import '../../state/auth_provider.dart';

import '../../state/providers.dart';

import '../auth/login_page.dart';

import '../auth/register_page.dart';

import '../firmware/firmware_page.dart';

import '../machines/machines_page.dart';

import '../preview/timelapse_gallery_page.dart';

import 'sys_bits_page.dart';

import '../settings/debug_settings_page.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';


/// Core 5: personal hub & device manager.

/// Strictly aligned to 我的页面.html —— 荧光绿 #00ff7f / 纯黑底 / 线性图标 / 原名。

class ProfilePage extends ConsumerStatefulWidget {

  const ProfilePage({super.key});



  @override

  ConsumerState<ProfilePage> createState() => _ProfilePageState();

}



class _ProfilePageState extends ConsumerState<ProfilePage> {

  void _openSheet(Widget content) {

    showModalBottomSheet(

      context: context,

      isScrollControlled: true,

      backgroundColor: Colors.transparent,

      builder: (_) => content,

    );

  }



  /// 进入登录/注册页；成功后刷新（顶部显示真实账号）。

  Future<void> _goLogin() async {

    await Navigator.of(context).push(

      MaterialPageRoute(builder: (_) => const LoginPage()),

    );

    if (mounted) setState(() {});

  }



  Future<void> _goRegister() async {

    await Navigator.of(context).push(

      MaterialPageRoute(builder: (_) => const RegisterPage()),

    );

    if (mounted) setState(() {});

  }



  Future<void> _goMachines() async {

    await Navigator.of(context).push(

      MaterialPageRoute(builder: (_) => const MachinesPage()),

    );

    if (mounted) setState(() {});

  }



  @override

  Widget build(BuildContext context) {

    final t = Theme.of(context).textTheme;

    final auth = ref.watch(authProvider);

    final loggedIn = auth.isLoggedIn;

    final username = auth.username?.isNotEmpty == true

        ? auth.username!

        : (auth.userId ?? '未登录');

    // 推送偏好（持久化，响应式）——替代原先的内存假开关

    final pushPrefs = ref.watch(pushPrefsProvider);

    return ListView(

      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),

      children: [

        // 用户信息头（登录态真实账号；未登录显示登录/注册入口）

        Container(

          padding: const EdgeInsets.all(18),

          decoration: BoxDecoration(

            color: CncColors.panelAlt,

            borderRadius: BorderRadius.circular(16),

            border: Border.all(color: CncColors.border),

          ),

          child: Row(

            children: [

              CircleAvatar(

                radius: 30,

                backgroundColor:

                    loggedIn ? CncColors.blue : CncColors.textSub,

                child: Text(

                  loggedIn

                      ? (username.isEmpty

                          ? 'U'

                          : username[0].toUpperCase())

                      : '?',

                  style: const TextStyle(

                      fontSize: 24,

                      fontWeight: FontWeight.bold,

                      color: Colors.white),

                ),

              ),

              const SizedBox(width: 14),

              Expanded(

                child: Column(

                  crossAxisAlignment: CrossAxisAlignment.start,

                  children: [

                    Text(loggedIn ? username : '未登录',

                        style: t.titleLarge

                            ?.copyWith(color: CncColors.textMain)),

                    const SizedBox(height: 4),

                    Text(

                      loggedIn

                          ? 'Cloud ID: ${auth.userId}'

                          : '登录后可扫码绑定你的雕刻机',

                      style: const TextStyle(

                          fontSize: 11, color: CncColors.textSub),

                    ),

                  ],

                ),

              ),

              if (!loggedIn)

                TextButton(

                  onPressed: _goLogin,

                  child: const Text('登录',

                      style: TextStyle(

                          color: CncColors.primaryInk,

                          fontWeight: FontWeight.bold)),

                ),

            ],

          ),

        ),

        const SizedBox(height: 18),



        // 模块 1：设备与网络（配网在屏幕端完成，App 只做绑定/查看，无蓝牙配网）

        _SectionTitle('设备与网络'),

        _MenuGroup(

          children: [

            if (!loggedIn) ...[

              _MenuItem(

                icon: Symbols.person_add,

                title: '注册账号',

                onTap: _goRegister,

              ),

            ],

            _MenuItem(

              icon: Symbols.sensors,

              title: '我的机器',

              trailing: const Text('扫码绑定机器',

                  style: TextStyle(fontSize: 12, color: CncColors.primaryInk)),

              onTap: _goMachines,

            ),

            _MenuItem(

              icon: Symbols.system_update,

              title: '固件升级',

              trailing: const Text('摄像头/控制屏幕/主板',

                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(

                    builder: (_) => const FirmwarePage()),

              ),

            ),

          ],

        ),



        // 模块 2：消息与告警

        _SectionTitle('消息与告警'),

        _MenuGroup(

          children: [

            _MenuItem(

              icon: Symbols.notifications,

              title: '系统消息与历史告警',

              trailing: Consumer(

                builder: (context, ref, _) {

                  final async = ref.watch(storedMessagesProvider);

                  return async.when(

                    data: (list) => Text(

                        list.isEmpty ? '暂无记录' : '${list.length} 条历史',

                        style: const TextStyle(

                            fontSize: 12, color: CncColors.textSub)),

                    loading: () => const SizedBox(

                      width: 14,

                      height: 14,

                      child: CircularProgressIndicator(

                          strokeWidth: 1.5, color: CncColors.textSub)),

                    error: (_, __) => const SizedBox.shrink(),

                  );

                },

              ),

              onTap: () => _openSheet(const _MessagesSheet()),

            ),

            _MenuItem(

              icon: Symbols.notifications_active,

              title: '允许推送设备完成状态',

              trailing: _Switch(

                  value: pushPrefs.notifyComplete,

                  onChanged: (v) =>

                      ref.read(pushPrefsProvider.notifier).toggleComplete(v)),

            ),

            _MenuItem(

              icon: Symbols.warning_amber,

              title: '允许推送硬件异常告警',

              trailing: _Switch(

                  value: pushPrefs.notifyAlert,

                  onChanged: (v) =>

                      ref.read(pushPrefsProvider.notifier).toggleAlert(v)),

            ),

          ],

        ),



        // 模块 2.5：创作与回顾

        _SectionTitle('创作与回顾'),

        _MenuGroup(

          children: [

            _MenuItem(

              icon: Symbols.movie,

              title: '延时摄影回顾',

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(

                    builder: (_) => const TimeLapseGalleryPage()),

              ),

            ),

            _MenuItem(

              icon: Symbols.construction,

              title: '官方刀头库',

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(builder: (_) => const SysBitsPage()),

              ),

            ),

          ],

        ),



        // 模块 3：支持与诊断

        _SectionTitle('支持与诊断'),

        _MenuGroup(

          children: [

            _MenuItem(

              icon: Symbols.build,

              title: '智能诊断与日志提取',

              onTap: () => _openSheet(const _DiagSheet()),

            ),

            _MenuItem(

              icon: Symbols.tune,

              title: '联调设置（云端 / MQTT / 设备）',

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(

                    builder: (_) => const DebugSettingsPage()),

              ),

            ),

            _MenuItem(

              icon: Symbols.headset_mic,

              title: '在线售后客服',

              onTap: () {

                ScaffoldMessenger.of(context).showSnackBar(

                  const SnackBar(content: Text('正在接通在线客服...')),

                );

              },

            ),

          ],

        ),

        // 模块 4：账号（仅登录后显示退出登录）

        if (loggedIn) ...[

          const SizedBox(height: 18),

          _MenuGroup(

            children: [

              _MenuItem(

                icon: Symbols.logout,

                title: '退出登录',

                // 不传 trailing —— _MenuItem 在 onTap!=null 时会自动加 chevron，

                // 这里不再重复，否则会出现两个右箭头。

                onTap: () async {

                  final ok = await showDialog<bool>(

                    context: context,

                    builder: (_) => AlertDialog(

                      backgroundColor: CncColors.card,

                      title: const Text('退出登录',

                          style: TextStyle(color: CncColors.textMain)),

                      content: const Text('确定要退出当前账号吗？',

                          style: TextStyle(color: CncColors.textSub)),

                      actions: [

                        TextButton(

                          onPressed: () => Navigator.pop(context, false),

                          child: const Text('取消'),

                        ),

                        TextButton(

                          onPressed: () => Navigator.pop(context, true),

                          child: const Text('退出',

                              style: TextStyle(color: CncColors.danger)),

                        ),

                      ],

                    ),

                  );

                  if (ok == true && mounted) {

                    await ref.read(authProvider.notifier).logout();

                    if (mounted) setState(() {});

                  }

                },

              ),

            ],

          ),

        ],

      ],

    );

  }

}



// ===================== 分组菜单 =====================



class _SectionTitle extends StatelessWidget {

  final String text;

  const _SectionTitle(this.text);

  @override

  Widget build(BuildContext context) => Padding(

        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),

        child: Text(text.toUpperCase(),

            style: const TextStyle(

                fontSize: 11, color: CncColors.textSub, letterSpacing: 0.5)),

      );

}



class _MenuGroup extends StatelessWidget {

  final List<Widget> children;

  const _MenuGroup({required this.children});

  @override

  Widget build(BuildContext context) => Container(

        decoration: BoxDecoration(

          color: CncColors.card,

          borderRadius: BorderRadius.circular(14),

          border: Border.all(color: CncColors.border),

        ),

        child: Column(children: children),

      );

}



class _MenuItem extends StatelessWidget {

  final IconData icon;

  final String title;

  final Widget? trailing;

  final VoidCallback? onTap;

  const _MenuItem(

      {required this.icon,

      required this.title,

      this.trailing,

      this.onTap});



  @override

  Widget build(BuildContext context) => InkWell(

        onTap: onTap,

        child: Container(

          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 15),

          decoration: BoxDecoration(

            border: Border(

                bottom: BorderSide(color: CncColors.border)),

          ),

          child: Row(

            children: [

              SizedBox(

                  width: 24,

                  child: Icon(icon,

                      size: 20, color: CncColors.textMain)),

              const SizedBox(width: 12),

              Expanded(

                  child: Text(title,

                      style: const TextStyle(

                          fontSize: 14,

                          fontWeight: FontWeight.w500,

                          color: CncColors.textMain))),

              if (trailing != null)

                ...[

                  trailing!,

                  const SizedBox(width: 6),

                  if (onTap != null)

                    const Icon(Symbols.chevron_right,

                        color: CncColors.textSub),

                ],

            ],

          ),

        ),

      );

}



class _Switch extends StatelessWidget {

  final bool value;

  final void Function(bool) onChanged;

  const _Switch({required this.value, required this.onChanged});

  @override

  Widget build(BuildContext context) => GestureDetector(

        onTap: () => onChanged(!value),

        child: AnimatedContainer(

          duration: const Duration(milliseconds: 200),

          width: 36,

          height: 20,

          decoration: BoxDecoration(

            borderRadius: BorderRadius.circular(10),

            color: value ? CncColors.primary : CncColors.border,

          ),

          child: AnimatedAlign(

            duration: const Duration(milliseconds: 200),

            alignment:

                value ? Alignment.centerRight : Alignment.centerLeft,

            child: Container(

              width: 16,

              height: 16,

              margin: const EdgeInsets.all(2),

              decoration: BoxDecoration(

                color: value ? Colors.white : CncColors.textSub,

                shape: BoxShape.circle,

              ),

            ),

          ),

        ),

      );

}



// ===================== 底部抽屉通用框架 =====================



class _SheetFrame extends StatelessWidget {

  final String title;

  final Widget child;

  const _SheetFrame({required this.title, required this.child});



  @override

  Widget build(BuildContext context) => Container(

        decoration: BoxDecoration(

          color: CncColors.card,

          borderRadius:

              const BorderRadius.vertical(top: Radius.circular(24)),

          border: Border(top: BorderSide(color: CncColors.border)),

        ),

        constraints: BoxConstraints(

            maxHeight: MediaQuery.of(context).size.height * 0.82),

        child: Column(

          mainAxisSize: MainAxisSize.min,

          children: [

            Padding(

              padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),

              child: Row(

                mainAxisAlignment: MainAxisAlignment.spaceBetween,

                children: [

                  Text(title,

                      style: const TextStyle(

                          fontSize: 16,

                          fontWeight: FontWeight.bold,

                          color: CncColors.textMain)),

                  IconButton(

                    icon: const Icon(Symbols.close,

                        color: CncColors.textSub, size: 22),

                    onPressed: () => Navigator.pop(context),

                  ),

                ],

              ),

            ),

            const Divider(height: 1, color: CncColors.border),

            Flexible(

              child: SingleChildScrollView(

                padding: const EdgeInsets.all(20),

                child: child,

              ),

            ),

          ],

        ),

      );

}





// ===================== 抽屉 3：消息与告警 =====================



class _MessagesSheet extends ConsumerStatefulWidget {

  const _MessagesSheet();

  @override

  ConsumerState<_MessagesSheet> createState() => _MessagesSheetState();

}



class _MessagesSheetState extends ConsumerState<_MessagesSheet> {

  List<StoredMessage> _msgs = const [];

  bool _loaded = false;



  @override

  void initState() {

    super.initState();

    // 触发 messageStoreProvider，确保本地消息持久化订阅已挂载

    ref.read(messageStoreProvider);

    _load();

  }



  Future<void> _load() async {

    final list = await MessageStore.instance.load();

    if (!mounted) return;

    setState(() {

      _msgs = list;

      _loaded = true;

    });

    // 刷新「我的」页未读/历史数

    ref.invalidate(storedMessagesProvider);

  }



  @override

  Widget build(BuildContext context) {

    return _SheetFrame(

      title: '系统消息与历史告警',

      child: !_loaded

          ? const Padding(

              padding: EdgeInsets.all(20),

              child: Center(

                child: SizedBox(

                  width: 22,

                  height: 22,

                  child: CircularProgressIndicator(strokeWidth: 2),

                ),

              ),

            )

          : _msgs.isEmpty

              ? const Padding(

                  padding: EdgeInsets.all(24),

                  child: Center(

                    child: Text('暂无系统消息',

                        style: TextStyle(

                            fontSize: 12, color: CncColors.textSub)),

                  ),

                )

              : Column(

                  children: _msgs.map((m) => _buildMsg(m)).toList(),

                ),

    );

  }



  Widget _buildMsg(StoredMessage m) {

    final icon = m.isAlarm

        ? Symbols.error

        : m.isWarn

            ? Symbols.warning_amber

            : Symbols.check_circle;

    final iconColor = m.isAlarm

        ? CncColors.danger

        : m.isWarn

            ? CncColors.warning

            : CncColors.primary;

    return Container(

      margin: const EdgeInsets.only(bottom: 10),

      padding: const EdgeInsets.all(12),

      decoration: BoxDecoration(

        color: CncColors.bg,

        borderRadius: BorderRadius.circular(6),

        border: Border(

            left: BorderSide(

                color: m.isAlarm

                    ? CncColors.danger

                    : m.isWarn

                        ? CncColors.warning

                        : CncColors.primary,

                width: 3)),

      ),

      child: Column(

        crossAxisAlignment: CrossAxisAlignment.start,

        children: [

          Row(

            children: [

              Icon(icon, size: 16, color: iconColor),

              const SizedBox(width: 6),

              Expanded(

                child: Text(m.title.isEmpty ? m.type : m.title,

                    style: const TextStyle(

                        fontSize: 13,

                        fontWeight: FontWeight.bold,

                        color: CncColors.textMain)),

              ),

            ],

          ),

          const SizedBox(height: 4),

          Text(_formatTime(m.at),

              style:

                  const TextStyle(fontSize: 10, color: CncColors.textSub)),

          const SizedBox(height: 6),

          Text(m.body,

              style: const TextStyle(

                  fontSize: 11, color: CncColors.textSub, height: 1.4)),

        ],

      ),

    );

  }



  String _formatTime(DateTime t) {

    final now = DateTime.now();

    final today = DateTime(now.year, now.month, now.day);

    final d = DateTime(t.year, t.month, t.day);

    final hh = t.hour.toString().padLeft(2, '0');

    final mm = t.minute.toString().padLeft(2, '0');

    if (d == today) return '今天 $hh:$mm';

    if (d == today.subtract(const Duration(days: 1))) return '昨天 $hh:$mm';

    return '${t.month}月${t.day}日 $hh:$mm';

  }

}



// ===================== 抽屉 4：诊断日志 =====================



class _DiagSheet extends StatelessWidget {

  const _DiagSheet();

  @override

  Widget build(BuildContext context) => _SheetFrame(

        title: '智能诊断与日志',

        child: Column(

          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            const Text(

              '当机器出现不可恢复的异常（如异响、持续报错）时，可一键提取主板底层运行日志'

              '（含最近 5 次加工的 G-Code 轨迹与传感器快照），发送给售后工程师协助分析。',

              style: TextStyle(

                  fontSize: 12, color: CncColors.textSub, height: 1.5),

            ),

            const SizedBox(height: 16),

            const _DiagProgressButton(),

          ],

        ),

      );

}



class _DiagProgressButton extends StatefulWidget {

  const _DiagProgressButton();

  @override

  State<_DiagProgressButton> createState() => _DiagProgressButtonState();

}



class _DiagProgressButtonState extends State<_DiagProgressButton> {

  bool _running = false;

  double _progress = 0;

  void _start() {

    if (_running) return;

    setState(() => _running = true);

    Timer.periodic(const Duration(milliseconds: 400), (timer) {

      _progress += 20;

      if (mounted) setState(() {});

      if (_progress >= 100) {

        timer.cancel();

        if (mounted) {

          ScaffoldMessenger.of(context).showSnackBar(

            const SnackBar(

                content: Text('日志打包完成，已发送至云端客服工单系统')),

          );

          Future.delayed(const Duration(milliseconds: 600), () {

            if (mounted) Navigator.pop(context);

          });

        }

      }

    });

  }



  @override

  Widget build(BuildContext context) => Column(

        children: [

          if (_running)

            Padding(

              padding: const EdgeInsets.only(bottom: 12),

              child: LinearProgressIndicator(

                value: _progress / 100,

                backgroundColor: CncColors.bg,

                color: CncColors.primary,

                minHeight: 8,

                borderRadius: BorderRadius.circular(4),

              ),

            ),

          SizedBox(

            width: double.infinity,

            child: FilledButton(

              onPressed: _running ? null : _start,

              style: FilledButton.styleFrom(

                backgroundColor: CncColors.bg,

                foregroundColor: CncColors.primaryInk,

                disabledBackgroundColor: CncColors.border,

                padding: const EdgeInsets.symmetric(vertical: 14),

                shape: RoundedRectangleBorder(

                  borderRadius: BorderRadius.circular(12),

                  side: BorderSide(color: CncColors.border),

                ),

              ),

              child: Row(

                  mainAxisAlignment: MainAxisAlignment.center,

                  children: [

                    if (!_running)

                      const Icon(Symbols.archive, size: 18, color: CncColors.primary),

                    if (!_running) const SizedBox(width: 8),

                    Text(

                        _running ? '打包中 ${_progress.toInt()}%' : '一键打包提取机器日志',

                        style: const TextStyle(

                            fontSize: 14, fontWeight: FontWeight.bold)),

                  ]),

            ),

          ),

        ],

      );

}


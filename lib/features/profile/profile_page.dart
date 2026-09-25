import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/theme.dart';
import '../../app/theme_mode_controller.dart';
import '../../services/message_store.dart';

import '../../state/auth_provider.dart';

import '../../state/providers.dart';
import '../../state/firmware_update_provider.dart';

import '../auth/login_page.dart';

import '../auth/register_page.dart';

import '../firmware/firmware_page.dart';

import '../machines/machines_page.dart';

import '../preview/timelapse_gallery_page.dart';

import 'profile_widgets.dart';
import 'settings_page.dart';
import 'sys_bits_page.dart';
import 'work_history_page.dart';

/// Core 5: personal hub & device manager.
///
/// 工单七（2026-09-25）：主页信息架构重设计 —— 高频与身份留主页，
/// 低频收进设置页（SettingsPage）。搬移映射见工单七 §3；本页只出现
/// 账户卡、注册条件项、创作/设备/支持三组与沉底设置入口。

class ProfilePage extends ConsumerStatefulWidget {

  const ProfilePage({super.key});



  @override

  ConsumerState<ProfilePage> createState() => _ProfilePageState();

}



class _ProfilePageState extends ConsumerState<ProfilePage> {

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

    return ListView(

      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),

      children: [

        // 用户信息头（登录态真实账号；未登录显示登录入口）—— 工单七 §1 #0 原样保留

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

                      style: TextStyle(

                          fontSize: 11, color: CncColors.textSub),

                    ),

                  ],

                ),

              ),

              if (!loggedIn)

                TextButton(

                  onPressed: _goLogin,

                  child: Text('登录',

                      style: TextStyle(

                          color: CncColors.primaryInk,

                          fontWeight: FontWeight.bold)),

                ),

            ],

          ),

        ),

        const SizedBox(height: 18),



        // 注册账号：仅未登录显示（原条件渲染，账户卡正下方独立单条卡 —— §1 #0a）

        if (!loggedIn) ...[

          MenuGroup(

            children: [

              MenuItem(

                icon: Symbols.person_add,

                title: '注册账号',

                onTap: _goRegister,

              ),

            ],

          ),

          const SizedBox(height: 18),

        ],



        // 创作（工单七 §1 #1：雕刻历史为全页最高频，提为第一组第一条）

        SectionTitle('创作'),

        MenuGroup(

          children: [

            MenuItem(

              icon: Symbols.history,

              title: '雕刻历史',

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(builder: (_) => const WorkHistoryPage()),

              ),

            ),

            MenuItem(

              icon: Symbols.movie,

              title: '延时摄影回顾',

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(

                    builder: (_) => const TimeLapseGalleryPage()),

              ),

            ),

            MenuItem(

              icon: Symbols.construction,

              title: '官方刀头库',

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(builder: (_) => const SysBitsPage()),

              ),

            ),

          ],

        ),



        // 设备（§1 #2）

        SectionTitle('设备'),

        MenuGroup(

          children: [

            MenuItem(

              icon: Symbols.sensors,

              title: '我的机器',

              trailing: Text('扫码绑定机器',

                  style: TextStyle(fontSize: 12, color: CncColors.primaryInk)),

              onTap: _goMachines,

            ),

            MenuItem(

              icon: Symbols.system_update,

              title: '固件升级',

              badge: const _FwUpdateDot(),

              trailing: Text('摄像头/控制屏幕/主板',

                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(

                    builder: (_) => const FirmwarePage()),

              ),

            ),

          ],

        ),



        // 支持（§1 #3：系统消息与历史告警保留主页，归支持组）

        SectionTitle('支持'),

        MenuGroup(

          children: [

            MenuItem(

              icon: Symbols.notifications,

              title: '系统消息与历史告警',

              trailing: Consumer(

                builder: (context, ref, _) {

                  final async = ref.watch(storedMessagesProvider);

                  return async.when(

                    data: (list) => Text(

                        list.isEmpty ? '暂无记录' : '${list.length} 条历史',

                        style: TextStyle(

                            fontSize: 12, color: CncColors.textSub)),

                    loading: () => SizedBox(

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

            MenuItem(

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



        // 沉底：设置入口（§1 #4：右侧显示当前主题名，同款 Consumer 写法）

        const SizedBox(height: 18),

        MenuGroup(

          children: [

            MenuItem(

              icon: Symbols.settings,

              title: '设置',

              trailing: Consumer(

                builder: (context, ref, _) => Text(

                    themeModeLabel(ref.watch(themeModeProvider)),

                    style: TextStyle(fontSize: 12, color: CncColors.textSub)),

              ),

              onTap: () => Navigator.push(

                context,

                MaterialPageRoute(builder: (_) => const SettingsPage()),

              ),

            ),

          ],

        ),

      ],

    );

  }



  void _openSheet(Widget content) => openSheet(context, content);

}



// ===================== 分组菜单（共享组件见 profile_widgets.dart） =====================



/// 固件升级「可升级」绿点（拉取式，非推送）。

/// 监听 [fwUpdateAvailableProvider]：云端有可升级固件时显示绿色小点，否则不显示。

class _FwUpdateDot extends ConsumerWidget {

  const _FwUpdateDot();



  @override

  Widget build(BuildContext context, WidgetRef ref) {

    final hasUpdate = ref.watch(fwUpdateAvailableProvider);

    if (!hasUpdate) return const SizedBox.shrink();

    return Container(

      width: 8,

      height: 8,

      decoration: BoxDecoration(

        color: CncColors.primary,

        shape: BoxShape.circle,

      ),

    );

  }

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

                      style: TextStyle(

                          fontSize: 16,

                          fontWeight: FontWeight.bold,

                          color: CncColors.textMain)),

                  IconButton(

                    icon: Icon(Symbols.close,

                        color: CncColors.textSub, size: 22),

                    onPressed: () => Navigator.pop(context),

                  ),

                ],

              ),

            ),

            Divider(height: 1, color: CncColors.border),

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



// ===================== 抽屉：消息与告警 =====================



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

              ? Padding(

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

                    style: TextStyle(

                        fontSize: 13,

                        fontWeight: FontWeight.bold,

                        color: CncColors.textMain)),

              ),

            ],

          ),

          const SizedBox(height: 4),

          Text(_formatTime(m.at),

              style:

                  TextStyle(fontSize: 10, color: CncColors.textSub)),

          const SizedBox(height: 6),

          Text(m.body,

              style: TextStyle(

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

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/theme.dart';
import '../settings/debug_settings_page.dart';

/// Core 5: personal hub & device manager.
/// Strictly aligned to 我的页面.html —— 荧光绿 #00ff7f / 纯黑底 / 线性图标 / 原名。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _pushComplete = true; // 允许推送设备完成状态
  bool _pushAlert = true; // 允许推送硬件异常告警

  void _openSheet(Widget content) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => content,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // 用户信息头（蓝 U 头像）
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
                backgroundColor: CncColors.blue,
                child: const Text('U',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('User_9527',
                        style: t.titleLarge
                            ?.copyWith(color: CncColors.textMain)),
                    const SizedBox(height: 4),
                    const Text('Cloud ID: CNC-A8F9-2026',
                        style: TextStyle(
                            fontSize: 11, color: CncColors.textSub)),
                  ],
                ),
              ),
              const Icon(Symbols.settings, size: 22, color: CncColors.textMain),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // 模块 1：设备与网络
        _SectionTitle('设备与网络'),
        _MenuGroup(
          children: [
            _MenuItem(
              icon: Symbols.wifi,
              title: '网络配对与连接',
              trailing: const Text('已连 Wi-Fi',
                  style: TextStyle(fontSize: 12, color: CncColors.primaryInk)),
              onTap: () => _openSheet(const _PairingSheet()),
            ),
            _MenuItem(
              icon: Symbols.system_update,
              title: '固件 OTA 升级',
              trailing: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: CncColors.danger,
                    borderRadius: BorderRadius.circular(10)),
                child: const Text('有新版本',
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
              ),
              onTap: () => _openSheet(const _OtaSheet()),
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
              trailing: const Text('2 条未读',
                  style: TextStyle(fontSize: 12, color: CncColors.danger)),
              onTap: () => _openSheet(const _MessagesSheet()),
            ),
            _MenuItem(
              icon: Symbols.notifications_active,
              title: '允许推送设备完成状态',
              trailing: _Switch(
                  value: _pushComplete,
                  onChanged: (v) => setState(() => _pushComplete = v)),
            ),
            _MenuItem(
              icon: Symbols.warning,
              title: '允许推送硬件异常告警',
              trailing: _Switch(
                  value: _pushAlert,
                  onChanged: (v) => setState(() => _pushAlert = v)),
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
              icon: Symbols.headset,
              title: '在线售后客服',
              onTap: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('正在接通在线客服...')),
                );
              },
            ),
          ],
        ),
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

// ===================== 抽屉 1：网络配对 =====================

class _PairingSheet extends StatelessWidget {
  const _PairingSheet();
  @override
  Widget build(BuildContext context) => _SheetFrame(
        title: '配置机器网络',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Center(
              child: Column(
                children: [
                  Icon(Symbols.wifi, size: 48, color: CncColors.primary),
                  SizedBox(height: 10),
                  Text('当前连接：Smart_Studio_5G',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: CncColors.textMain)),
                  SizedBox(height: 4),
                  Text('IP: 192.168.1.105',
                      style: TextStyle(
                          fontSize: 11, color: CncColors.textSub)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: CncColors.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: CncColors.border),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('重新配置网络 (蓝牙模式)',
                      style: TextStyle(
                          fontSize: 12, color: CncColors.textSub)),
                  SizedBox(height: 8),
                  _PasswordField(),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SendConfigButton(),
          ],
        ),
      );
}

class _PasswordField extends StatelessWidget {
  const _PasswordField();
  @override
  Widget build(BuildContext context) => TextField(
        obscureText: true,
        style: const TextStyle(color: CncColors.textMain),
        decoration: InputDecoration(
          hintText: '输入新 Wi-Fi 密码...',
          hintStyle: const TextStyle(color: CncColors.textSub),
          filled: true,
          fillColor: CncColors.bg,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: CncColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: CncColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: CncColors.primary),
          ),
        ),
      );
}

class _SendConfigButton extends StatefulWidget {
  const _SendConfigButton();
  @override
  State<_SendConfigButton> createState() => _SendConfigButtonState();
}

class _SendConfigButtonState extends State<_SendConfigButton> {
  String _label = '下发配置至机器';
  bool _busy = false;
  void _onTap() {
    if (_busy) return;
    setState(() {
      _busy = true;
      _label = '正在通过蓝牙下发...';
    });
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      setState(() => _label = '网络已重新连接');
      Future.delayed(const Duration(milliseconds: 1000), () {
        if (mounted) Navigator.pop(context);
      });
    });
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _onTap,
          style: FilledButton.styleFrom(
            backgroundColor: CncColors.primary,
            foregroundColor: Colors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: Text(_label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold)),
        ),
      );
}

// ===================== 抽屉 2：OTA 升级 =====================

class _OtaSheet extends StatelessWidget {
  const _OtaSheet();
  @override
  Widget build(BuildContext context) => _SheetFrame(
        title: '主板固件升级 (OTA)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: CncColors.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: CncColors.primary.withOpacity(0.3)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text('当前版本: v1.2.0',
                          style: TextStyle(
                              fontSize: 12, color: CncColors.textSub)),
                      Text('新版本: v1.3.5',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: CncColors.primaryInk)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('更新日志：',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: CncColors.textMain)),
                  const SizedBox(height: 4),
                  const Text('• 优化了 ATC 抓刀算法，换刀速度提升 15%\n'
                      '• 修复了长时间雕刻时偶发的 Z 轴丢步报错\n'
                      '• 新增支持 14 种新耗材预设参数',
                      style: TextStyle(
                          fontSize: 11,
                          color: CncColors.textSub,
                          height: 1.6)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _OtaProgressButton(),
            const SizedBox(height: 6),
            const Text('升级期间机器将重启，请勿断开主电源',
                style: TextStyle(fontSize: 10, color: CncColors.textSub),
                textAlign: TextAlign.center),
          ],
        ),
      );
}

class _OtaProgressButton extends StatefulWidget {
  const _OtaProgressButton();
  @override
  State<_OtaProgressButton> createState() => _OtaProgressButtonState();
}

class _OtaProgressButtonState extends State<_OtaProgressButton> {
  bool _running = false;
  double _progress = 0;
  void _start() {
    if (_running) return;
    setState(() => _running = true);
    Timer.periodic(const Duration(milliseconds: 300), (timer) {
      _progress += 10;
      if (mounted) setState(() {});
      if (_progress >= 100) {
        timer.cancel();
        if (mounted) {
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              backgroundColor: CncColors.card,
              title: const Text('固件已刷入',
                  style: TextStyle(color: CncColors.textMain)),
              content: const Text('机器正在重启，请稍候...',
                  style: TextStyle(color: CncColors.textSub)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('好的'))
              ],
            ),
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
                backgroundColor: CncColors.primary,
                foregroundColor: Colors.black,
                disabledBackgroundColor: CncColors.border,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                  _running ? '刷入中 ${_progress.toInt()}%' : '一键下载并刷入机器',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      );
}

// ===================== 抽屉 3：消息与告警 =====================

class _MessagesSheet extends StatelessWidget {
  const _MessagesSheet();
  static const _msgs = [
    _Msg(
        icon: Symbols.error,
        iconColor: CncColors.danger,
        title: '加工异常中断',
        time: '今天 15:30',
        desc: '检测到加工过程中机箱防护门被物理打开。为保障安全，主轴已急停。请检查并复位机器。',
        error: true),
    _Msg(
        icon: Symbols.check_circle,
        iconColor: CncColors.primary,
        title: '雕刻任务已完成',
        time: '今天 11:20',
        desc: '工程包“定制化_父亲节底座_V2”已成功完成加工。延时摄影视频已保存至云端相册。'),
    _Msg(
        icon: Symbols.build,
        iconColor: CncColors.textSub,
        title: '刀具保养提醒',
        time: '昨天 09:10',
        desc: 'T1 槽位 3.175 平底刀累计切削时长已达 50 小时，建议检查刃口磨损情况。'),
  ];
  @override
  Widget build(BuildContext context) => _SheetFrame(
        title: '系统消息与历史告警',
        child: Column(
          children: _msgs
              .map((m) => Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: CncColors.bg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border(
                          left: BorderSide(
                              color: m.error
                                  ? CncColors.danger
                                  : CncColors.primary,
                              width: 3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(m.icon, size: 16, color: m.iconColor),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(m.title,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: CncColors.textMain)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(m.time,
                            style: const TextStyle(
                                fontSize: 10, color: CncColors.textSub)),
                        const SizedBox(height: 6),
                        Text(m.desc,
                            style: const TextStyle(
                                fontSize: 11,
                                color: CncColors.textSub,
                                height: 1.4)),
                      ],
                    ),
                  ))
              .toList(),
        ),
      );
}

class _Msg {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String time;
  final String desc;
  final bool error;
  const _Msg(
      {required this.icon,
      required this.iconColor,
      required this.title,
      required this.time,
      required this.desc,
      this.error = false});
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

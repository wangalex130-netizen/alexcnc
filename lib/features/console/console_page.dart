import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../models/machine_status.dart';
import '../../models/tool.dart';
import '../../state/providers.dart';

/// 状态驱动设备控制台 (Core 3) —— 严格对齐 控制页面.html。
///
/// 顶部视频监控 + 闪烁「实时监控」；快捷开关（机箱照明/红点激光/延时摄影）；
/// 全局 DRO（Smart 3020 + 待机/加工中）；IDLE 时展开 Jog / 主轴 / ATC；
/// 底部常驻 停止 / 暂停。远程监视模式（isLocalLAN=false）下主动控制自动锁死。
class ConsolePage extends ConsumerStatefulWidget {
  const ConsolePage({super.key});

  @override
  ConsumerState<ConsolePage> createState() => _ConsolePageState();
}

class _ConsolePageState extends ConsumerState<ConsolePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rec = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  bool _light = false;
  bool _laser = false;
  bool _timelapse = false;
  bool _spindleOn = false;
  int _rpm = 12000;

  // ATC 刀仓（与 HTML 一致）
  final List<Tool> _tools = const [
    Tool(index: 1, name: '🔴 3.175 平底刀', lengthMm: 12, installed: true),
    Tool(index: 2, name: '🟢 60° V型刀', lengthMm: 10, installed: true),
    Tool(index: 3, name: '未挂载刀具 (空位)', installed: false),
  ];

  @override
  void dispose() {
    _rec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(machineStatusProvider).value ?? const MachineStatus();
    final isLocal = ref.watch(isLocalLANProvider);
    final hw = ref.read(hardwareServiceProvider);

    final idle = status.state == MachineState.idle;
    final busy = status.state == MachineState.busy;
    final canControl = isLocal && idle;

    return Scaffold(
      backgroundColor: CncColors.bg,
      body: Column(
        children: [
          // ---- 视频监控区 ----
          Stack(
            children: [
              Container(
                height: 220,
                width: double.infinity,
                color: const Color(0xFF0a0a0a),
                child: const Center(
                  child: Icon(Icons.videocam, size: 48, color: Color(0xFF333333)),
                ),
              ),
              Positioned(
                top: 40,
                left: 15,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: CncColors.border),
                      ),
                      child: Row(
                        children: [
                          FadeTransition(
                            opacity: _rec,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: CncColors.danger,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text('实时监控', style: TextStyle(fontSize: 11, color: Colors.white)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // LAN / WAN 状态（点击切换，驱动门禁）
              Positioned(
                top: 40,
                right: 15,
                child: GestureDetector(
                  onTap: () => ref.read(isLocalLANProvider.notifier).state = !isLocal,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: CncColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(isLocal ? Icons.wifi : Icons.cloud,
                            size: 12, color: isLocal ? CncColors.primary : CncColors.warning),
                        const SizedBox(width: 4),
                        Text(isLocal ? '🟢 局域网直连' : '🔴 远程监视',
                            style: TextStyle(
                                fontSize: 10,
                                color: isLocal ? CncColors.primary : CncColors.warning,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          // ---- 快捷开关 ----
          Row(
            children: [
              _ToggleBtn(icon: '💡', label: '机箱照明', active: _light,
                  onTap: () {
                    setState(() => _light = !_light);
                    hw.setAux('light', _light);
                  }),
              _ToggleBtn(icon: '🎯', label: '红点激光', active: _laser,
                  onTap: () {
                    setState(() => _laser = !_laser);
                    hw.setAux('laser', _laser);
                  }),
              _ToggleBtn(icon: '⏱️', label: '延时摄影', active: _timelapse,
                  onTap: () {
                    setState(() => _timelapse = !_timelapse);
                    hw.setAux('timelapse', _timelapse);
                  }),
            ],
          ),

          // ---- 内容滚动区 ----
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // 远程监视提示
                if (!isLocal)
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: CncColors.warning.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: CncColors.warning.withOpacity(0.4)),
                    ),
                    child: const Text('🔒 远程监视模式：主动移动/开切已锁定，仅可查看状态与软停止/暂停。',
                        style: TextStyle(fontSize: 11, color: CncColors.warning)),
                  ),

                // 全局 DRO
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: _cardDeco(),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Smart 3020',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: busy ? CncColors.warning.withOpacity(0.15) : CncColors.primary.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              busy ? '🟠 加工中 (BUSY)' : '🟢 待机 (IDLE)',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: busy ? CncColors.warning : CncColors.primary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _DroAxis(label: 'X 轴', color: CncColors.danger, value: status.position.x),
                          _DroAxis(label: 'Y 轴', color: CncColors.primary, value: status.position.y),
                          _DroAxis(label: 'Z 轴', color: CncColors.blue, value: status.position.z),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // IDLE 控制区（远程模式锁死）
                if (canControl) ...[
                  const _SectionTitle('定位与回零'),
                  _JogCard(
                    onJog: (axis, d) => hw.jog(axis, d),
                    onSetZero: () => hw.setWorkZero(),
                    onHome: () => hw.home(),
                  ),
                  const SizedBox(height: 12),
                  const _SectionTitle('主轴调试 (Spindle)'),
                  _SpindleCard(
                    rpm: _rpm,
                    onRpm: (v) => setState(() => _rpm = v),
                    spindleOn: _spindleOn,
                    onToggle: () {
                      setState(() => _spindleOn = !_spindleOn);
                      _spindleOn ? hw.startSpindle(_rpm.toDouble()) : hw.stopSpindle();
                    },
                  ),
                  const SizedBox(height: 12),
                  const _SectionTitle('安全与刀仓配置'),
                  _AtcEntry(onOpen: () => _openAtc(context, hw)),
                ] else if (isLocal && !idle) ...[
                  const SizedBox(height: 8),
                  const Center(child: Text('加工中… 危险操作已收起', style: TextStyle(color: CncColors.textSub))),
                ],

                const SizedBox(height: 12),
              ],
            ),
          ),

          // ---- 底部动作条 ----
          Container(
            padding: const EdgeInsets.fromLTRB(15, 10, 15, 24),
            color: CncColors.panel,
            child: Row(
              children: [
                Expanded(
                  child: _ActionBtn(
                    label: '🚨 停止',
                    fg: CncColors.danger,
                    bg: CncColors.danger.withOpacity(0.15),
                    border: CncColors.danger,
                    onTap: () => hw.stopJob(),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionBtn(
                    label: '⏸️ 暂停',
                    fg: CncColors.textMain,
                    bg: const Color(0xFF222222),
                    border: CncColors.border,
                    onTap: () => busy ? hw.pauseJob() : hw.resumeJob(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _openAtc(BuildContext context, dynamic hw) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _AtcSheet(
        tools: _tools,
        onSync: () {
          hw.updateToolMap(_tools);
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('✓ 同步到机器')),
          );
        },
      ),
    );
  }
}

// ===================== 通用装饰 =====================

BoxDecoration _cardDeco() => BoxDecoration(
      color: CncColors.card,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: CncColors.border),
    );

// ===================== 快捷开关 =====================

class _ToggleBtn extends StatelessWidget {
  final String icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ToggleBtn({required this.icon, required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: active ? CncColors.card : const Color(0xFF111111),
              border: Border(
                right: BorderSide(color: CncColors.border.withOpacity(0.5)),
              ),
            ),
            child: Column(
              children: [
                Text(icon, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(fontSize: 10, color: active ? CncColors.primary : CncColors.textSub)),
              ],
            ),
          ),
        ),
      );
}

// ===================== DRO =====================

class _DroAxis extends StatelessWidget {
  final String label;
  final Color color;
  final double value;
  const _DroAxis({required this.label, required this.color, required this.value});

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF111111),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: CncColors.border),
          ),
          child: Column(
            children: [
              Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 2),
              Text(value.toStringAsFixed(3),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: CncColors.textMain)),
            ],
          ),
        ),
      );
}

// ===================== 小标题 =====================

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Text(text,
            style: const TextStyle(fontSize: 11, color: CncColors.textSub, letterSpacing: 0.5)),
      );
}

// ===================== Jog 摇杆 =====================

class _JogCard extends StatelessWidget {
  final void Function(String axis, double d) onJog;
  final VoidCallback onSetZero;
  final VoidCallback onHome;
  const _JogCard({required this.onJog, required this.onSetZero, required this.onHome});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: _cardDeco(),
        child: Row(
          children: [
            // XY 九宫格
            Expanded(
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                childAspectRatio: 1.4,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  const SizedBox(),
                  _JogBtn('Y+', () => onJog('y', 1)),
                  const SizedBox(),
                  _JogBtn('X-', () => onJog('x', -1)),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF111111),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Center(child: Text('XY', style: TextStyle(fontSize: 10, color: Color(0xFF555555)))),
                  ),
                  _JogBtn('X+', () => onJog('x', 1)),
                  const SizedBox(),
                  _JogBtn('Y-', () => onJog('y', -1)),
                  const SizedBox(),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Z 列
            SizedBox(
              width: 45,
              child: Column(
                children: [
                  _JogBtn('Z+', () => onJog('z', 1)),
                  _JogBtn('Z', () => onJog('z', 0), plain: true),
                  _JogBtn('Z-', () => onJog('z', -1)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 定原点 / 回零
            SizedBox(
              width: 50,
              child: Column(
                children: [
                  _HomeBtn('📍\n定原点', onSetZero),
                  const SizedBox(height: 4),
                  _HomeBtn('🏠\n回零', onHome),
                ],
              ),
            ),
          ],
        ),
      );
}

class _JogBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool plain;
  const _JogBtn(this.label, this.onTap, {this.plain = false});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            color: plain ? const Color(0xFF111111) : const Color(0xFF222222),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: CncColors.border),
          ),
          child: Center(child: Text(label, style: const TextStyle(fontSize: 14, color: CncColors.textMain))),
        ),
      );
}

class _HomeBtn extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _HomeBtn(this.label, this.onTap);
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 38,
          decoration: BoxDecoration(
            color: const Color(0xFF222222),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: CncColors.border),
          ),
          child: Center(
            child: Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: CncColors.textSub)),
          ),
        ),
      );
}

// ===================== 主轴 =====================

class _SpindleCard extends StatelessWidget {
  final int rpm;
  final ValueChanged<int> onRpm;
  final bool spindleOn;
  final VoidCallback onToggle;
  const _SpindleCard({required this.rpm, required this.onRpm, required this.spindleOn, required this.onToggle});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: _cardDeco(),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('目标转速: ${rpm.toString()} RPM',
                    style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
                GestureDetector(
                  onTap: onToggle,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: spindleOn ? CncColors.danger.withOpacity(0.15) : const Color(0xFF222222),
                      border: Border.all(color: spindleOn ? CncColors.danger : CncColors.border),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(spindleOn ? '🚨 停止转动' : '🌀 测试启动',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: spindleOn ? CncColors.danger : CncColors.textMain)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('0', style: TextStyle(fontSize: 10, color: Color(0xFF555555))),
                Expanded(
                  child: Slider(
                    value: rpm.toDouble(),
                    min: 0,
                    max: 24000,
                    divisions: 24,
                    activeColor: CncColors.primary,
                    onChanged: (v) => onRpm(v.round()),
                  ),
                ),
                const Text('24k', style: TextStyle(fontSize: 10, color: Color(0xFF555555))),
              ],
            ),
          ],
        ),
      );
}

// ===================== ATC 入口 + 抽屉 =====================

class _AtcEntry extends StatelessWidget {
  final VoidCallback onOpen;
  const _AtcEntry({required this.onOpen});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onOpen,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: _cardDeco(),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('ATC 自动换刀系统', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                  SizedBox(height: 2),
                  Text('当前主轴: T1 (🔴3.175平底刀)', style: TextStyle(fontSize: 10, color: Color(0xFF666666))),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF222222),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CncColors.border),
                ),
                child: const Text('管理刀仓 ❯', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: CncColors.blue)),
              ),
            ],
          ),
        ),
      );
}

class _AtcSheet extends StatelessWidget {
  final List<Tool> tools;
  final VoidCallback onSync;
  const _AtcSheet({required this.tools, required this.onSync});

  @override
  Widget build(BuildContext context) => Container(
        height: 400,
        decoration: const BoxDecoration(
          color: Color(0xFF151515),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: CncColors.border)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  Text('配置 ATC 刀具映射表', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                  Text('×', style: TextStyle(fontSize: 22, color: Color(0xFF666666))),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  const Text('选择物理卡槽对应的实际刀具，同步后机器将自动更新设定。',
                      style: TextStyle(fontSize: 10, color: CncColors.textSub)),
                  const SizedBox(height: 10),
                  ...tools.map((t) => Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                        decoration: _cardDeco(),
                        child: Row(
                          children: [
                            Text('T${t.index}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF555555))),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                                  const SizedBox(height: 2),
                                  Text(t.installed ? '刃长: ${t.lengthMm}mm / 适合粗雕' : '空位',
                                      style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: t.installed ? CncColors.blue.withOpacity(0.1) : CncColors.primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(t.installed ? '更换 ❯' : '添加 +',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                                      color: t.installed ? CncColors.blue : CncColors.primary)),
                            ),
                          ],
                        ),
                      )),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onSync,
                  style: FilledButton.styleFrom(
                    backgroundColor: CncColors.primary,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('✓ 同步到机器', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          ],
        ),
      );
}

// ===================== 底部动作 =====================

class _ActionBtn extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  final Color border;
  final VoidCallback onTap;
  const _ActionBtn({required this.label, required this.fg, required this.bg, required this.border, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: fg)),
          ),
        ),
      );
}

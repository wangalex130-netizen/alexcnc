import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../app/config.dart';
import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../data/tool_library.dart';
import '../../widgets/tool_icon.dart';
import '../../models/machine_status.dart';
import '../../models/tool.dart';
import '../../state/providers.dart';
import '../../services/network_auth.dart';
import '../preview/rtsp_preview_widget.dart';
import '../preview/mjpeg_stream_player.dart';
import '../preview/fullscreen_preview_page.dart';
import '../wizard/job_monitor_page.dart';
import '../wizard/self_check_page.dart';

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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _rec = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  bool _light = false;
  bool _laser = false;
  bool _timelapse = false;
  bool _spindleOn = false;
  int _rpm = 12000;
  Timer? _netTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 启动后稍延迟探测一次，避免首帧布局未完成就弹错误。
    Future.delayed(const Duration(milliseconds: 300), _autoDetectNetwork);
    // 每 10s 周期探测：手机在 Wi-Fi/蜂窝间切换时能自动跟随。
    _netTimer = Timer.periodic(const Duration(seconds: 10), (_) => _autoDetectNetwork());
  }

  @override
  void dispose() {
    _rec.dispose();
    _netTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 自动探测手机是否与控制器在同一局域网：
  /// 用 Socket 探测控制器 TCP 8899 是否可达（2s 超时）。
  /// 可达=同局域网（可完整控制）；不可达=远程监视（控制锁死）。
  Future<void> _autoDetectNetwork() async {
    final cfg = ref.read(runtimeConfigProvider);
    final host = cfg.resolvedDeviceTcpHost;
    final port = cfg.resolvedDeviceTcpPort;
    if (host.isEmpty || port <= 0) return;
    final reachable =
        await NetworkProbe.probe(host, port, timeout: const Duration(seconds: 2));
    if (!mounted) return;
    if (ref.read(isLocalLANProvider) != reachable) {
      ref.read(isLocalLANProvider.notifier).state = reachable;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _autoDetectNetwork();
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
              // 监控视频源：内网走 RTSP（原生 VLC，画质好延迟低）；
              // 外网（自动探测 8899 不可达）走香港中继 MJPEG（已优化 ~14fps）。
              // isLocal 由 _autoDetectNetwork 自动判定，无需手动切换。
              SizedBox(
                height: 220,
                child: isLocal
                    ? RtspPreviewWidget(
                        rtspUrl:
                            ref.watch(runtimeConfigProvider).resolvedCameraRtsp)
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          MjpegStreamPlayer(
                            // 外网统一走香港中继；autoStart=false 显示
                            // 「点击开始预览」，用户点一下再拉流省流量。
                            autoStart: false,
                            url: '${AppConfig.cameraRelayBaseUrl}'
                                '/stream/${AppConfig.cameraRelayDevice}'
                                '?token=${AppConfig.cameraRelayToken}',
                          ),
                          // 外网全屏预览（横屏 + 截图保存相册）
                          Positioned(
                            bottom: 10,
                            right: 10,
                            child: GestureDetector(
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const FullscreenPreviewPage(),
                                ),
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.55),
                                  borderRadius: BorderRadius.circular(8),
                                  border:
                                      Border.all(color: CncColors.border),
                                ),
                                child: const Icon(Icons.fullscreen_rounded,
                                    size: 18, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
              Positioned(
                top: 40,
                left: 15,
                child: Row(
                  children: [
                    // KARVA 品牌角标（logo + 浅色面板，视频上也能看清）
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: CncColors.panel,
                        borderRadius: BorderRadius.circular(CncSizes.r4),
                        border: Border.all(color: CncColors.border, width: 0.5),
                      ),
                      child: Image.asset(CncAssets.logo, height: 12, fit: BoxFit.contain),
                    ),
                    const SizedBox(width: 8),
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
              // LAN / WAN 状态（自动探测；点击=立即重探，不再手动切换）
              Positioned(
                top: 40,
                right: 15,
                child: GestureDetector(
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('重新检测网络模式…', style: TextStyle(fontSize: 13)),
                        duration: Duration(seconds: 2),
                      ),
                    );
                    _autoDetectNetwork();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: CncColors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(isLocal ? Symbols.wifi : Symbols.cloud,
                            size: 12, color: isLocal ? CncColors.primary : CncColors.warning),
                        const SizedBox(width: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _statusDot(isLocal ? CncColors.primary : CncColors.warning),
                            const SizedBox(width: 5),
                            Text(isLocal ? '局域网直连' : '远程监视',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: isLocal ? CncColors.primary : CncColors.warning,
                                    fontWeight: FontWeight.bold)),
                          ],
                        ),
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
              _ToggleBtn(
                  icon: Symbols.lightbulb,
                  label: '机箱照明',
                  active: _light,
                  onTap: () {
                    setState(() => _light = !_light);
                    hw.setAux('light', _light);
                  }),
              _ToggleBtn(
                  icon: Symbols.gps_fixed,
                  label: '红点激光',
                  active: _laser,
                  onTap: () {
                    setState(() => _laser = !_laser);
                    hw.setAux('laser', _laser);
                  }),
              _ToggleBtn(
                  icon: Symbols.schedule,
                  label: '延时摄影',
                  active: _timelapse,
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
                    child: Row(
                      children: [
                        const Icon(Symbols.lock, size: 14, color: CncColors.warning),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('远程监视模式：主动移动/开切已锁定，仅可查看状态与软停止/暂停。',
                              style: const TextStyle(fontSize: 11, color: CncColors.warning)),
                        ),
                      ],
                    ),
                  ),

                // 当前加工任务入口（解决监控页被叉掉后找不到入口的 bug）
                Consumer(
                  builder: (context, ref, child) {
                    final job = ref.watch(activeJobProvider);
                    if (job == null) return const SizedBox.shrink();
                    final completed = job.completed;
                    final progress = completed
                        ? 100
                        : (status.progress.clamp(0.0, 1.0) * 100).round();
                    return GestureDetector(
                      onTap: () {
                        if (completed || job.selfCheckDone) {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const JobMonitorPage()),
                          );
                        } else {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => SelfCheckPage(
                                materialKey: job.materialKey,
                                requiredTools: job.task.requiredTools,
                                procSlot: job.procSlot,
                              ),
                            ),
                          );
                        }
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: completed
                              ? CncColors.primary.withOpacity(0.1)
                              : CncColors.warning.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: completed
                                  ? CncColors.primary.withOpacity(0.4)
                                  : CncColors.warning.withOpacity(0.4)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: completed
                                    ? CncColors.primary.withOpacity(0.15)
                                    : CncColors.warning.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                  completed ? Symbols.check_circle : Symbols.play_circle,
                                  color: completed
                                      ? CncColors.primary
                                      : CncColors.warning,
                                  size: 18),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    completed
                                        ? '加工已完成'
                                        : '当前加工中 · $progress%',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: completed
                                            ? CncColors.primaryInk
                                            : CncColors.warning),
                                  ),
                                  Text(job.item.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: CncColors.textMain)),
                                ],
                              ),
                            ),
                            const Icon(Symbols.chevron_right,
                                color: CncColors.textSub),
                          ],
                        ),
                      ),
                    );
                  },
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
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _statusDot(busy ? CncColors.warning : CncColors.primary),
                                const SizedBox(width: 5),
                                Text(
                                  busy ? '加工中 (BUSY)' : '待机 (IDLE)',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: busy ? CncColors.warning : CncColors.primaryInk),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _DroAxis(label: 'X 轴', color: CncColors.danger, value: status.position.x),
                          _DroAxis(label: 'Y 轴', color: CncColors.primaryInk, value: status.position.y),
                          _DroAxis(label: 'Z 轴', color: CncColors.blue, value: status.position.z),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 主动控制区：局域网直连始终展示，加工中仅禁用不隐藏
                if (isLocal) ...[
                  const _SectionTitle('定位与回零'),
                  _StepSelector(),
                  _JogCard(
                    enabled: canControl,
                    onJog: (axis, sign) => hw.jog(axis, ref.watch(jogStepProvider) * sign),
                    onSetZero: () => hw.setWorkZero(),
                    onHome: () => hw.home(),
                  ),
                  const SizedBox(height: 12),
                  const _SectionTitle('主轴调试 (Spindle)'),
                  _SpindleCard(
                    enabled: canControl,
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
                  _AtcEntry(enabled: canControl, onOpen: () => _openAtc(context, hw)),
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
                    icon: Symbols.stop,
                    label: '停止',
                    fg: CncColors.danger,
                    bg: CncColors.danger.withOpacity(0.15),
                    border: CncColors.danger,
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          backgroundColor: CncColors.card,
                          title: const Text('确认停止雕刻吗？',
                              style: TextStyle(color: CncColors.danger)),
                          content: const Text('停止后主轴将刹停，本次加工会中断。',
                              style: TextStyle(color: CncColors.textMain)),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消',
                                  style: TextStyle(color: CncColors.textMain)),
                            ),
                            TextButton(
                              onPressed: () {
                                hw.stopJob();
                                ref.read(activeJobProvider.notifier).clear();
                                Navigator.of(context).pop();
                              },
                              child: const Text('确认停止',
                                  style: TextStyle(color: CncColors.danger)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ActionBtn(
                    icon: status.state == MachineState.paused ? Symbols.play_arrow : Symbols.pause,
                    label: status.state == MachineState.paused ? '继续' : '暂停',
                    fg: CncColors.textMain,
                    bg: CncColors.panelAlt,
                    border: CncColors.border,
                    onTap: () {
                      // 暂停/继续状态来自机器（与监控页共享同一状态源，自动同步）
                      if (status.state == MachineState.paused) {
                        hw.resumeJob();
                      } else {
                        hw.pauseJob();
                      }
                    },
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
        onSync: () {
          final magazine = ref.read(toolMagazineProvider);
          final tools = [1, 2, 3, 4].map((slot) {
            final id = magazine[slot];
            final def = id != null ? toolById(id) : null;
            return Tool(
              index: slot,
              name: def != null ? '${ringEmoji(def.ring)} ${def.name}' : '空位',
              material: def != null ? def.material : null,
              installed: def != null,
              defId: id,
            );
          }).toList();
          hw.updateToolMap(tools);
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('同步到机器')),
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

/// 状态指示圆点：替代彩色 emoji 色点，统一为纯色圆，跟随语义色。
Widget _statusDot(Color color) => Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

// ===================== 快捷开关 =====================

class _ToggleBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;
  const _ToggleBtn({required this.icon, required this.label, required this.active, this.enabled = true, required this.onTap});

  @override
  Widget build(BuildContext context) => Expanded(
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: active && enabled ? CncColors.card : const Color(0xFFE6E9ED),
                border: Border(
                  right: BorderSide(color: CncColors.border.withOpacity(0.5)),
                ),
              ),
              child: Column(
                children: [
                  Icon(icon,
                      size: 20,
                      color: active && enabled ? CncColors.primary : CncColors.textSub),
                  const SizedBox(height: 4),
                  Text(label,
                      style: TextStyle(fontSize: 10, color: active && enabled ? CncColors.primary : CncColors.textSub)),
                ],
              ),
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
            color: const Color(0xFFE6E9ED),
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

// ===================== Jog 步进档位（全局共享） =====================

class _StepSelector extends ConsumerWidget {
  const _StepSelector();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final step = ref.watch(jogStepProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Text('步进', style: TextStyle(fontSize: 11, color: CncColors.textSub)),
          const SizedBox(width: 10),
          ...[0.1, 1.0, 10.0].map((v) {
            final sel = step == v;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => ref.read(jogStepProvider.notifier).state = v,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    decoration: BoxDecoration(
                      color: sel ? CncColors.primary : CncColors.bg,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: sel ? CncColors.primary : CncColors.border,
                      ),
                    ),
                    child: Center(
                      child: Text('${v.toStringAsFixed(1)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: sel ? Colors.black : CncColors.textMain,
                          )),
                    ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ===================== Jog 摇杆 =====================

class _JogCard extends StatelessWidget {
  final bool enabled;
  final void Function(String axis, double d) onJog;
  final VoidCallback onSetZero;
  final VoidCallback onHome;
  const _JogCard({this.enabled = true, required this.onJog, required this.onSetZero, required this.onHome});

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
                  _JogBtn('Y+', () => onJog('y', 1), enabled: enabled),
                  const SizedBox(),
                  _JogBtn('X-', () => onJog('x', -1), enabled: enabled),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFE6E9ED),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Center(child: Text('XY', style: TextStyle(fontSize: 10, color: Color(0xFF555555)))),
                  ),
                  _JogBtn('X+', () => onJog('x', 1), enabled: enabled),
                  const SizedBox(),
                  _JogBtn('Y-', () => onJog('y', -1), enabled: enabled),
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
                  _JogBtn('Z+', () => onJog('z', 1), enabled: enabled),
                  _JogBtn('Z', () => onJog('z', 0), plain: true, enabled: enabled),
                  _JogBtn('Z-', () => onJog('z', -1), enabled: enabled),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // 定原点 / 回零
            SizedBox(
              width: 50,
              child: Column(
                children: [
                  _HomeBtn(icon: Symbols.add_location, label: '定原点', onTap: onSetZero, enabled: enabled),
                  const SizedBox(height: 4),
                  _HomeBtn(icon: Symbols.home, label: '回零', onTap: onHome, enabled: enabled),
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
  final bool enabled;
  const _JogBtn(this.label, this.onTap, {this.plain = false, this.enabled = true});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: 38,
            decoration: BoxDecoration(
              color: plain ? const Color(0xFFE6E9ED) : CncColors.panelAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: CncColors.border),
            ),
            child: Center(child: Text(label, style: const TextStyle(fontSize: 14, color: CncColors.textMain))),
          ),
        ),
      );
}

class _HomeBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  const _HomeBtn({required this.icon, required this.label, required this.onTap, this.enabled = true});
  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: CncColors.panelAlt,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: CncColors.border),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18, color: CncColors.textSub),
                const SizedBox(height: 3),
                Text(label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: CncColors.textSub)),
              ],
            ),
          ),
        ),
      );
}

// ===================== 主轴 =====================

class _SpindleCard extends StatelessWidget {
  final bool enabled;
  final int rpm;
  final ValueChanged<int> onRpm;
  final bool spindleOn;
  final VoidCallback onToggle;
  const _SpindleCard({this.enabled = true, required this.rpm, required this.onRpm, required this.spindleOn, required this.onToggle});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: _cardDeco(),
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('目标转速: ${rpm.toString()} RPM',
                      style: const TextStyle(fontSize: 12, color: CncColors.textSub)),
                  GestureDetector(
                    onTap: enabled ? onToggle : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: spindleOn && enabled ? CncColors.danger.withOpacity(0.15) : CncColors.panelAlt,
                        border: Border.all(color: spindleOn && enabled ? CncColors.danger : CncColors.border),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(spindleOn && enabled ? Symbols.stop_circle : Symbols.play_arrow,
                              size: 14, color: spindleOn && enabled ? CncColors.danger : CncColors.textMain),
                          const SizedBox(width: 6),
                          Text(spindleOn && enabled ? '停止转动' : '测试启动',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: spindleOn && enabled ? CncColors.danger : CncColors.textMain)),
                        ],
                      ),
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
                      activeColor: enabled ? CncColors.primary : CncColors.textSub,
                      onChanged: enabled ? (v) => onRpm(v.round()) : null,
                    ),
                  ),
                  const Text('24k', style: TextStyle(fontSize: 10, color: Color(0xFF555555))),
                ],
              ),
            ],
          ),
        ),
      );
}

// ===================== ATC 入口 + 抽屉 =====================
// 与向导 Step3 共用 toolMagazineProvider：任一处修改，另一处立即同步。

class _AtcEntry extends ConsumerWidget {
  final bool enabled;
  final VoidCallback onOpen;
  const _AtcEntry({this.enabled = true, required this.onOpen});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final magazine = ref.watch(toolMagazineProvider);
    final t1 = magazine[1] != null ? toolById(magazine[1]!) : null;
    final sub = t1 != null
        ? '当前主轴 T1: ${ringEmoji(t1.ring)} ${t1.name}'
        : '当前主轴: 空';
    return GestureDetector(
      onTap: enabled ? onOpen : null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: _cardDeco(),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('ATC 自动换刀系统', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                  const SizedBox(height: 2),
                  Text(sub, style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: CncColors.panelAlt,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CncColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Text('管理刀仓', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: CncColors.blue)),
                    SizedBox(width: 4),
                    Icon(Symbols.chevron_right, size: 14, color: CncColors.blue),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AtcSheet extends ConsumerStatefulWidget {
  final VoidCallback onSync;
  const _AtcSheet({required this.onSync});

  @override
  ConsumerState<_AtcSheet> createState() => _AtcSheetState();
}

class _AtcSheetState extends ConsumerState<_AtcSheet> {
  int? _pickerSlot; // 正在选择刀具的卡槽

  @override
  Widget build(BuildContext context) {
    final magazine = ref.watch(toolMagazineProvider);

    if (_pickerSlot != null) {
      // 刀具选择面板（从刀库选择填入该刀位）
      return Container(
        height: 460,
        decoration: const BoxDecoration(
          color: Color(0xFFE0E3E8),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: CncColors.border)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('选择刀具 → T$_pickerSlot', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                  GestureDetector(
                    onTap: () => setState(() => _pickerSlot = null),
                    child: const Text('×', style: TextStyle(fontSize: 22, color: Color(0xFF666666))),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  ...toolCatalog.map((def) => Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                        decoration: _cardDeco(),
                        child: Row(
                          children: [
                            ToolIcon(def: def, size: 38),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(def.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                                  const SizedBox(height: 2),
                                  Text('${def.type} · ⌀${def.diameterMm}mm · ${def.flutes}刃 · ${def.material}',
                                      style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
                                  const SizedBox(height: 2),
                                  Text(def.desc, style: const TextStyle(fontSize: 9, color: CncColors.textSub)),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onTap: () {
                                ref.read(toolMagazineProvider.notifier).assign(_pickerSlot!, def.id);
                                setState(() => _pickerSlot = null);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: CncColors.primary.withOpacity(0.12),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: CncColors.primary.withOpacity(0.5)),
                                ),
                                child: const Text('填入', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.primaryInk)),
                              ),
                            ),
                          ],
                        ),
                      )),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () {
                      ref.read(toolMagazineProvider.notifier).assign(_pickerSlot!, null);
                      setState(() => _pickerSlot = null);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: CncColors.danger.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: CncColors.danger.withOpacity(0.4)),
                      ),
                      child: const Center(
                        child: Text('清空此刀位 (空)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: CncColors.danger)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 主映射表
    return Container(
      height: 460,
      decoration: const BoxDecoration(
        color: Color(0xFFE0E3E8),
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
                const Text('选择物理卡槽对应的实际刀具（刀库与向导共用，任一处修改自动同步）。',
                    style: TextStyle(fontSize: 10, color: CncColors.textSub)),
                const SizedBox(height: 10),
                for (final slot in [1, 2, 3, 4]) ...[
                  Builder(builder: (c) {
                    final id = magazine[slot];
                    final def = id != null ? toolById(id) : null;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
                      decoration: _cardDeco(),
                        child: Row(
                        children: [
                          Opacity(
                            opacity: def != null ? 1 : 0.28,
                            child: ToolIcon(def: def ?? toolCatalog.first, size: 40, showRing: def != null),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(def != null ? 'T$slot · ${def.name}' : 'T$slot · 未挂载刀具 (空位)',
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: CncColors.textMain)),
                                const SizedBox(height: 2),
                                Text(def != null ? '${def.type} · ⌀${def.diameterMm}mm · ${def.desc}' : '点击添加刀具',
                                    style: const TextStyle(fontSize: 10, color: Color(0xFF666666))),
                              ],
                            ),
                          ),
                          GestureDetector(
                            onTap: () => setState(() => _pickerSlot = slot),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: def != null ? CncColors.blue.withOpacity(0.1) : CncColors.primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(def != null ? '更换' : '添加 +',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                                      color: def != null ? CncColors.blue : CncColors.primaryInk)),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: widget.onSync,
                style: FilledButton.styleFrom(
                  backgroundColor: CncColors.primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Symbols.sync, size: 18, color: Colors.black),
                    SizedBox(width: 8),
                    Text('同步到机器', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ===================== 底部动作 =====================

class _ActionBtn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color fg;
  final Color bg;
  final Color border;
  final VoidCallback onTap;
  const _ActionBtn({required this.label, this.icon, required this.fg, required this.bg, required this.border, required this.onTap});

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
            child: icon == null
                ? Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: fg))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 18, color: fg),
                      const SizedBox(width: 6),
                      Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: fg)),
                    ],
                  ),
          ),
        ),
      );
}

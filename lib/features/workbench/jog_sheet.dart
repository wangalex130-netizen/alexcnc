import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/config.dart';
import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../models/machine_status.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';

/// 全局 Jog 手动移动浮层（底部弹出）。
///
/// 三处入口共用（首页机器卡 / 向导 Step4 / 全屏监控），步进档位由
/// [jogStepProvider] 全局共享（0.1 / 1.0 / 10 mm）。
class JogSheet extends ConsumerStatefulWidget {
  final HardwareService hw;
  const JogSheet({super.key, required this.hw});

  @override
  ConsumerState<JogSheet> createState() => _JogSheetState();
}

class _JogSheetState extends ConsumerState<JogSheet>
    with WidgetsBindingObserver {
  /// W-10：上次弹出「Jog 被拦下」提示的时间，用于节流（见 build 内 toastJogBlocked）。
  DateTime? _lastJogBlockToast;

  /// 是否正处于"长按连续点动"中（2026-09-11 S1）。
  /// 用于退后台 / 页面销毁时补发 jog_cancel —— 不能只依赖固件的超时兜底，
  /// 因为长按手势在 App 失去焦点时会被系统直接中断（不会触发 onTapUp）。
  bool _jogActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 离开页面时若仍在连续点动，补发取消（此处直接调服务：jogEnd 是 build 内的
    // 局部函数，生命周期回调里访问不到）。
    if (_jogActive) {
      _jogActive = false;
      widget.hw.jogCancel();
    }
    super.dispose();
  }

  /// App 退到后台 / 失去焦点 / 被销毁：主动取消连续点动。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      if (_jogActive) {
        _jogActive = false;
        widget.hw.jogCancel();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(jogStepProvider);
    // 终局方案（2026-08-28）：命令一律经云端 MQTT 下发；
    // 🔴 D-DEC-1（2026-09-10）：Jog 额外要求与机器同一局域网（服务层拦截，见 hw.jog）。
    // 能否手动移动取决于机器状态 —— 空闲可动，加工中/报警/回零中/未连接均锁定。
    final mState = ref.watch(machineStatusProvider).value?.state;
    // 2026-08-29 安全加固：真实后端模式下未选机器时同样锁定
    //（未选机器 deviceId 会回退到默认联调设备，不能往未知机器下发运动命令）。
    final hasMachine = ref.watch(currentMachineProvider) != null;
    final lockedByMachine =
        ref.watch(runtimeConfigProvider).resolvedUseRealBackend && !hasMachine;
    final canControl = mState == MachineState.idle && !lockedByMachine;
    final lockLabel = lockedByMachine
        ? '未选择机器 · 已锁定'
        : (mState == null || mState == MachineState.disconnected)
            ? '未连接 · 已锁定'
            : '加工中 · 已锁定';

    // 🔴 报警自救通道（2026-08-31）：软复位 / 解锁**刻意不受 `state == idle` 闸门限制**。
    // 机器进 Alarm 后 canControl=false，Jog/回零全被锁死；若连解锁也一起锁，
    // 就形成死锁——App 永远无法把机器从报警里拉回来，只能爬到机器旁按实体键。
    // 因此这两个动作只要「已选机器且已连上」就可用，是 Jog 安全闸门的唯一例外。
    // 代价是可控的：软复位=中止运动（不移动轴），解锁=只清锁不移动。
    final connected = mState != null && mState != MachineState.disconnected;
    final canReset = !lockedByMachine && connected;
    // 解锁只在报警态点亮，避免正常状态下误触（$X 无害但会让用户以为出了问题）。
    final canUnlock = !lockedByMachine && connected && mState == MachineState.alarm;

    /// 局部函数必须先声明后使用（Dart 不做 hoisting），故放在两个动作之前。
    /// 底部浮层可能没有外层 Scaffold，用 maybeOf 兜底避免抛异常。
    void toast(String msg) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    }

    /// W-10：Jog 被门禁拦下时的提示。连发为 180ms/帧，必须节流，
    /// 否则每帧弹一次会把提示刷成"抖动"，反而看不清原因。
    void toastJogBlocked(String msg) {
      final now = DateTime.now();
      final last = _lastJogBlockToast;
      if (last != null && now.difference(last) < const Duration(seconds: 3)) {
        return;
      }
      _lastJogBlockToast = now;
      toast(msg);
    }

    Future<void> jog(String axis, int sign) async {
      if (!canControl) return;
      final sent = await widget.hw.jog(axis, step * sign);
      if (!sent && mounted) {
        // false = 未确认与机器同网（D-DEC-1 门禁）或 MQTT 未连上（W-09-c）。
        toastJogBlocked('未发送：请连接机器所在 Wi-Fi 后再点动（外网仅监视）');
      }
    }

    /// 长按开始：**只发一次**连续点动指令（2026-09-11 三方共识 S1）。
    ///
    /// 由固件把它转成一条长距离 `$J` 持续运动，松手由 [jogEnd] 取消；
    /// 这样不再需要 180ms 连发，也就不存在"运动队列堆积 → 松手后继续走"。
    Future<void> jogStart(String axis, int sign) async {
      if (!canControl) return;
      _jogActive = true;
      final sent = await widget.hw.jogContinuous(axis, sign);
      if (!sent) {
        _jogActive = false;
        if (mounted) {
          toastJogBlocked('未发送：请连接机器所在 Wi-Fi 后再点动（外网仅监视）');
        }
      }
    }

    /// 松手 / 手势取消：取消连续点动（固件写 GRBL 实时字符 0x85）。
    /// 幂等 —— 未在点动中时调用无副作用。
    Future<void> jogEnd() async {
      if (!_jogActive) return;
      _jogActive = false;
      await widget.hw.jogCancel();
    }

    /// 软复位：加工中/暂停中会中断作业，故需二次确认；空闲/报警态直接执行。
    Future<void> doSoftReset() async {
      if (!canReset) return;
      final running = mState == MachineState.busy || mState == MachineState.paused;
      if (running) {
        final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('软复位会中断当前作业'),
                content: const Text(
                    '机器正在加工。软复位会立即中止运动并清空运动缓冲，'
                    '正在进行的雕刻无法续雕。确定继续吗？'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('确定软复位',
                          style: TextStyle(color: CncColors.danger))),
                ],
              ),
            ) ??
            false;
        if (!ok) return;
      }
      await widget.hw.softReset();
      if (mounted) toast('已发送软复位');
    }

    Future<void> doUnlock() async {
      if (!canUnlock) return;
      await widget.hw.unlock();
      // 解锁后机器坐标不可信（$X 只是清锁，没有重建坐标系），必须提示重新定原点。
      if (mounted) toast('已解除报警锁定 · 请重新定原点后再加工');
    }

    return Container(
      decoration: const BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: CncColors.border)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('手动移动（Jog）',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold, color: CncColors.textMain)),
              if (!canControl)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: CncColors.warning.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(lockLabel,
                      style: const TextStyle(fontSize: 10, color: CncColors.warning)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 步进档位
          Row(
            children: [
              const Text('步进',
                  style: TextStyle(fontSize: 12, color: CncColors.textSub)),
              const SizedBox(width: 12),
              ...[0.1, 1.0, 10.0].map((v) {
                final sel = step == v;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onTap: () =>
                          ref.read(jogStepProvider.notifier).state = v,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: sel
                              ? CncColors.primary
                              : CncColors.bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: sel ? CncColors.primary : CncColors.border,
                          ),
                        ),
                        child: Center(
                          child: Text('${v.toStringAsFixed(1)} mm',
                              style: TextStyle(
                                fontSize: 13,
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
          const SizedBox(height: 16),
          // XY 九宫格 + Z
          Row(
            children: [
              Expanded(
                child: GridView.count(
                  crossAxisCount: 3,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.5,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                  children: [
                    const SizedBox(),
                    _JogKey('Y+', () => jog('y', 1),
                        onJogStart: () => jogStart('y', 1),
                        onJogEnd: jogEnd, enabled: canControl),
                    const SizedBox(),
                    _JogKey('X-', () => jog('x', -1),
                        onJogStart: () => jogStart('x', -1),
                        onJogEnd: jogEnd, enabled: canControl),
                    Container(
                      decoration: BoxDecoration(
                        color: CncColors.bg,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Center(
                        child: Text('XY',
                            style: TextStyle(fontSize: 11, color: CncColors.textSub)),
                      ),
                    ),
                    _JogKey('X+', () => jog('x', 1),
                        onJogStart: () => jogStart('x', 1),
                        onJogEnd: jogEnd, enabled: canControl),
                    const SizedBox(),
                    _JogKey('Y-', () => jog('y', -1),
                        onJogStart: () => jogStart('y', -1),
                        onJogEnd: jogEnd, enabled: canControl),
                    const SizedBox(),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 52,
                child: Column(
                  children: [
                    _JogKey('Z+', () => jog('z', 1),
                        onJogStart: () => jogStart('z', 1),
                        onJogEnd: jogEnd, enabled: canControl),
                    _JogKey('Z−', () => jog('z', -1),
                        onJogStart: () => jogStart('z', -1),
                        onJogEnd: jogEnd, enabled: canControl),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 动作列（2026-08-31 调整）：
              //  · 去掉「设原点」——定原点属于发起雕刻任务向导中的环节，不该出现在 Jog 里；
              //  · 补上「软复位 / 解锁」——机器报警后的自救入口，不受 idle 闸门限制。
              SizedBox(
                width: 54,
                child: Column(
                  children: [
                    _JogKey('软复位', doSoftReset,
                        enabled: canReset, repeat: false, danger: true),
                    const SizedBox(height: 6),
                    _JogKey('解锁', doUnlock,
                        enabled: canUnlock, repeat: false, danger: true),
                    const SizedBox(height: 6),
                    _JogKey('回零', () {
                      if (!canControl) return;
                      // W-10 扩展：回零属契约 forbidden（全行程移动）→ 仅同网可执行。
                      widget.hw.home().then((sent) {
                        if (!sent && mounted) {
                          toastJogBlocked(
                              '回零未发送：只能在机器同一局域网内执行（外网仅监视 / 可停机）');
                        }
                      });
                    }, enabled: canControl, repeat: false),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('步进 ${step.toStringAsFixed(1)} mm · 长按可连续移动',
              style: const TextStyle(fontSize: 11, color: CncColors.textSub)),
        ],
      ),
    );
  }
}

class _JogKey extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final bool enabled;
  final bool tall;
  /// 是否启用「按住连续触发」。
  /// **动作键（软复位 / 解锁 / 回零）必须传 false** —— 长按连发会导致
  /// reset / $X / $H 被连打下发（历史上 Jog 的连发是为解决 0.1mm 点动太慢，
  /// 对一次性动作不但无益，还会打断固件侧正在处理的命令）。
  final bool repeat;
  /// 危险动作配色（软复位 / 解锁）：橙红描边，与移动键区分，降低误触。
  final bool danger;
  /// 长按开始（2026-09-11 共识 S1）：传了它才走"长按只发一次"的新模型。
  /// 为 null 或开关关闭时，退回旧的 180ms 连发行为。
  final VoidCallback? onJogStart;
  /// 松手 / 手势取消 / 页面销毁：取消连续点动（固件写 0x85）。
  final VoidCallback? onJogEnd;
  const _JogKey(this.label, this.onTap,
      {this.enabled = true,
      this.tall = false,
      this.repeat = true,
      this.danger = false,
      this.onJogStart,
      this.onJogEnd});

  @override
  State<_JogKey> createState() => _JogKeyState();
}

class _JogKeyState extends State<_JogKey> {
  Timer? _repeat;
  /// 长按判定计时器（新模型：达阈值才发 continuous）。
  Timer? _holdTimer;
  bool _holding = false;
  /// 本次按压是否已发出 continuous（决定松手时发 cancel 还是当作单击）。
  bool _continuous = false;

  /// 是否走「长按只发一次 + 松手取消」的新模型。
  /// 需要同时满足：构建开关打开（AppConfig.jogContinuousEnabled）**且**调用方传了
  /// [widget.onJogStart]。后者为 null 的多是动作键（软复位/解锁/回零），不受影响。
  bool get _useContinuous =>
      AppConfig.jogContinuousEnabled && widget.onJogStart != null;

  /// 按下。
  ///
  /// - **新模型**：只启动长按判定；达到 220ms 阈值时**只发一次** continuous，
  ///   由固件转成一条长距离 `$J` 持续运动 —— 从源头消除
  ///   「每 180ms 连发 → GRBL 运动队列堆积 → 松手后机器继续走」。
  /// - **旧模型（默认）**：按下即走一步；按住 500ms 后每 180ms 一步。
  /// [widget.repeat] 为 false 时只触发一次（动作键走这条路径）。
  void _start() {
    if (!widget.enabled) return;
    if (mounted) setState(() => _holding = true);

    if (_useContinuous) {
      _holdTimer?.cancel();
      _holdTimer = Timer(const Duration(milliseconds: 220), () {
        if (!mounted || !_holding) return;
        _continuous = true;
        widget.onJogStart!.call();
      });
      return;
    }

    widget.onTap();
    if (!widget.repeat) return;
    _repeat?.cancel();
    _repeat = Timer(const Duration(milliseconds: 500), () {
      _repeat = Timer.periodic(const Duration(milliseconds: 180), (_) {
        if (widget.enabled) widget.onTap();
      });
    });
  }

  /// 抬起 / 手势取消 / 长按结束。
  ///
  /// - 新模型：已发过 continuous → 发一次 `jog_cancel`；未达阈值 → 当作单击走一步。
  /// - 旧模型：停掉连发定时器即可。
  void _stop() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _repeat?.cancel();
    _repeat = null;
    if (_useContinuous) {
      if (_continuous) {
        _continuous = false;
        widget.onJogEnd?.call();
      } else {
        widget.onTap(); // 未达长按阈值：按单击处理
      }
    }
    if (mounted && _holding) setState(() => _holding = false);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _repeat?.cancel();
    // 控件销毁时若仍在连续点动，必须补发取消，否则机器会一直走到软限位。
    if (_continuous) {
      _continuous = false;
      widget.onJogEnd?.call();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 危险动作（软复位 / 解锁）用红色描边+红字，与移动键在视觉上区分开。
    final accent = widget.danger ? CncColors.danger : CncColors.primary;
    return GestureDetector(
          onTapDown: (_) => _start(),
          onTapUp: (_) => _stop(),
          onTapCancel: _stop,
          onLongPressEnd: (_) => _stop(),
          child: Opacity(
            opacity: widget.enabled ? 1 : 0.45,
            child: Container(
              height: widget.tall ? 44 : 40,
              decoration: BoxDecoration(
                color: _holding ? accent.withOpacity(0.22) : CncColors.panelAlt,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: _holding
                        ? accent
                        : (widget.danger ? CncColors.danger : CncColors.border)),
              ),
              child: Center(
                child: Text(widget.label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: widget.danger
                            ? CncColors.danger
                            : CncColors.textMain)),
              ),
            ),
          ),
        );
  }
}

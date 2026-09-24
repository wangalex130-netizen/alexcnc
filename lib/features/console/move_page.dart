import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';

import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../l10n/strings_zh.dart';
import '../../models/jog_profile.dart';
import '../../models/machine_status.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';
import '../../widgets/octagon_dial.dart';
import '../../widgets/jog_key.dart';

/// 控制台二级页「移动」（工单二 §4 / 控制台规格书 §7，拓竹圆盘式）。
///
/// 手势与安全闸门**复用 JogSheet 同一套逻辑**（长按只发一次 continuous +
/// 200ms 保活 + 松手 0x85；斜角仅点按 jogXY 多轴帧，每轴分量 = 步长÷√2），
/// 不改任何协议；步长三选与 JogSheet 共享 [jogStepProvider]（0.1/1/10，
/// 对 X/Y/Z/A 统一，A 为角度）。
class MovePage extends ConsumerStatefulWidget {
  final HardwareService hw;
  const MovePage({super.key, required this.hw});

  @override
  ConsumerState<MovePage> createState() => _MovePageState();
}

class _MovePageState extends ConsumerState<MovePage>
    with WidgetsBindingObserver {
  DateTime? _lastJogBlockToast;

  /// 是否正处于「长按连续点动」中：退后台/销毁时补发 jog_cancel。
  bool _jogActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_jogActive) {
      _jogActive = false;
      widget.hw.jogCancel();
    }
    super.dispose();
  }

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

  static String _stepLabel(double step) => step == step.roundToDouble()
      ? step.toStringAsFixed(0)
      : step.toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(jogStepProvider);
    final status =
        ref.watch(machineStatusProvider).value ?? const MachineStatus();
    final mState = status.state;
    // 2026-08-29 安全加固：真实后端模式下未选机器时锁定运动命令
    //（未选机器 deviceId 会回退到默认联调设备）。
    final hasMachine = ref.watch(currentMachineProvider) != null;
    final lockedByMachine = ref.watch(runtimeConfigProvider).resolvedUseRealBackend &&
        !hasMachine;
    // 终局方案（2026-08-28）：空闲可动，加工中/报警/回零中锁定。
    final canControl = mState == MachineState.idle && !lockedByMachine;
    // 🔴 报警自救通道（2026-08-31，与 jog_sheet 同口径）：软复位/解锁刻意
    // 不受 idle 闸门限制 —— 否则报警死锁，App 永远救不回来。
    final connected = mState != MachineState.disconnected;
    final canReset = !lockedByMachine && connected;
    final canUnlock = canReset && mState == MachineState.alarm;

    void toast(String msg) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
      );
    }

    /// W-10：Jog 被门禁拦下时的提示（连发 180ms/帧，必须节流）。
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
        toastJogBlocked('未发送：请连接机器所在 Wi-Fi 后再点动（外网仅监视）');
      }
    }

    /// 长按开始：只发一次连续点动指令（2026-09-11 三方共识 S1）。
    Future<void> jogStart(String axis, int sign) async {
      if (!canControl) return;
      _jogActive = true;
      final sent = await widget.hw
          .jogContinuous(axis, sign, feed: jogFeedForStep(step));
      if (!sent) {
        _jogActive = false;
        if (mounted) {
          toastJogBlocked('未发送：请连接机器所在 Wi-Fi 后再点动（外网仅监视）');
        }
      }
    }

    /// 松手 / 手势取消：取消连续点动（固件写 GRBL 实时字符 0x85）。幂等。
    Future<void> jogEnd() async {
      if (!_jogActive) return;
      _jogActive = false;
      await widget.hw.jogCancel();
    }

    /// 连续点动保活（A2）：按住期间由 JogKey 每 200ms 回调一次。
    void jogKeepalive() {
      if (!_jogActive) return;
      widget.hw.jogKeepalive();
    }

    /// 八向盘点按：直边走既有单轴 jog；斜角走 jogXY 一条 `$J=G91 X.. Y..`
    /// 联动帧（固件现成），每轴分量 = 步长÷√2。屏幕上 = 机床 Y+，故 my = -dy。
    Future<void> tapDir(int dx, int dy) async {
      if (dx != 0 && dy != 0) {
        final comp = step / sqrt2;
        final sent = await widget.hw
            .jogXY(dx * comp, -dy * comp, feed: jogFeedForStep(step));
        if (!sent && mounted) {
          toastJogBlocked('未发送：请连接机器所在 Wi-Fi 后再点动（外网仅监视）');
        }
      } else if (dx != 0) {
        await jog('x', dx);
      } else if (dy != 0) {
        await jog('y', -dy);
      }
    }

    /// 软复位：加工中/暂停中会中断作业，需二次确认；空闲/报警态直接执行。
    Future<void> doSoftReset() async {
      if (!canReset) return;
      final running =
          mState == MachineState.busy || mState == MachineState.paused;
      if (running) {
        final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(S.jogResetTitle),
                content: Text(S.jogResetBody),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(S.jogResetConfirm,
                          style: TextStyle(color: CncColors.danger))),
                ],
              ),
            ) ??
            false;
        if (!ok) return;
      }
      await widget.hw.softReset();
      if (mounted) toast(S.jogResetDone);
    }

    Future<void> doUnlock() async {
      if (!canUnlock) return;
      await widget.hw.unlock();
      // 解锁后机器坐标不可信（$X 只是清锁），必须提示重新定原点。
      if (mounted) toast('已解除报警锁定 · 请重新定原点后再加工');
    }

    Future<void> doHome() async {
      if (!canControl) return;
      // W-10 扩展：回零属契约 forbidden（全行程移动）→ 仅同网可执行。
      final sent = await widget.hw.home();
      if (!sent && mounted) {
        toastJogBlocked('回零未发送：只能在机器同一局域网内执行（外网仅监视 / 可停机）');
      }
    }

    final p = status.position;

    return Scaffold(
      backgroundColor: CncColors.bg,
      appBar: AppBar(
        backgroundColor: CncColors.card,
        surfaceTintColor: CncColors.card,
        toolbarHeight: 48,
        elevation: 0,
        iconTheme: IconThemeData(color: CncColors.textMain),
        leading: IconButton(
          icon: const Icon(Symbols.chevron_left, size: 22),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('移动',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CncColors.textMain)),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ② DRO 条（规格 §7-2）：四组 spaceBetween；A 列接入前显示 ——。
          Container(
            margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: CncColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CncColors.border),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _dro('X', p.x.toStringAsFixed(3)),
                _dro('Y', p.y.toStringAsFixed(3)),
                _dro('Z', p.z.toStringAsFixed(3)),
                _droA(),
              ],
            ),
          ),
          // ③ 圆盘 + Z 列（规格 §7-3：盘 190×190、中心钮 58×58）。
          Container(
            margin: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 190,
                  height: 190,
                  child: OctagonDial(
                    enabled: canControl,
                    onTap: tapDir,
                    holdFor: (dx, dy) => dx == 0 || dy == 0,
                    onHoldStart: (dx, dy) {
                      if (dx != 0) {
                        jogStart('x', dx);
                      } else {
                        jogStart('y', -dy);
                      }
                    },
                    onHoldEnd: jogEnd,
                    onHoldKeepalive: jogKeepalive,
                    repeatFor: (dx, dy) => (dx == 0 || dy == 0) && step <= 1.0,
                    centerLabel: '归中',
                    // 中心键：归中指令接口未接，正常外观、点击无响应。
                    onCenter: () {},
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  children: [
                    Text('Z 轴',
                        style: TextStyle(
                            fontSize: 10.5, color: CncColors.textSub)),
                    const SizedBox(height: 8),
                    _zBtn(Symbols.keyboard_arrow_up, step, 1,
                        enabled: canControl,
                        jog: jog,
                        jogStart: jogStart,
                        jogEnd: jogEnd,
                        jogKeepalive: jogKeepalive),
                    const SizedBox(height: 8),
                    _zBtn(Symbols.keyboard_arrow_down, step, -1,
                        enabled: canControl,
                        jog: jog,
                        jogStart: jogStart,
                        jogEnd: jogEnd,
                        jogKeepalive: jogKeepalive),
                  ],
                ),
              ],
            ),
          ),
          // ④ 步长选择（规格 §7-4）：三枚胶囊 70 宽，对 X/Y/Z/A 统一。
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _pill(0.1, step == 0.1),
                const SizedBox(width: 8),
                _pill(1.0, step == 1.0),
                const SizedBox(width: 8),
                _pill(10.0, step == 10.0),
              ],
            ),
          ),
          // ⑤ A 轴卡（规格 §7-5）：接口未通点击无响应，无任何标签。
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: CncColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: CncColors.border),
            ),
            child: Row(
              children: [
                Text('A 轴',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: CncColors.textMain)),
                const Spacer(),
                _aBtn(Symbols.refresh, step),
                const SizedBox(width: 8),
                _aBtn(Symbols.rotate_right, step),
              ],
            ),
          ),
          // ⑥ 底部三键（规格 §7-6）：回零 / 软复位 / 解锁（仅报警态点亮，规则不上屏）。
          Container(
            margin: const EdgeInsets.fromLTRB(12, 14, 12, 0),
            child: Row(
              children: [
                _actionKey('回零', doHome,
                    fg: CncColors.textMain,
                    bg: CncColors.card,
                    border: CncColors.border),
                const SizedBox(width: 8),
                _actionKey('软复位', doSoftReset,
                    fg: CncColors.danger,
                    bg: CncColors.card,
                    border: CncColors.dangerBd),
                const SizedBox(width: 8),
                _actionKey(
                  '解锁',
                  canUnlock ? doUnlock : null,
                  fg: canUnlock
                      ? CncColors.danger
                      : CncColors.textSub.withOpacity(0.4),
                  bg: canUnlock ? CncColors.card : CncColors.panelAlt,
                  border:
                      canUnlock ? CncColors.dangerBd : CncColors.panelAlt,
                ),
              ],
            ),
          ),
          const Spacer(flex: 1),
        ],
      ),
    );
  }

  /// DRO 一组：轴字母 12 textSub + 数值 13/700 textMain。
  Widget _dro(String axis, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(axis, style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(width: 4),
        Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: CncColors.textMain)),
      ],
    );
  }

  /// A 列：A 轴接入前显示「——」（textSub 40% 透明度）。
  Widget _droA() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('A', style: TextStyle(fontSize: 12, color: CncColors.textSub)),
        const SizedBox(width: 4),
        Text('——',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: CncColors.textSub.withOpacity(0.4))),
      ],
    );
  }

  /// Z 轴钮（规格 §7-3）：76 宽、圆角 10、边 1px border、字 13.5/600；
  /// 长按连续 / ≤1mm 档连发（复用 JogKey，flat 平面渲染）。
  Widget _zBtn(IconData icon, double step, int sign,
      {required bool enabled,
      required Future<void> Function(String, int) jog,
      required Future<void> Function(String, int) jogStart,
      required Future<void> Function() jogEnd,
      required void Function() jogKeepalive}) {
    return Container(
      width: 76,
      decoration: BoxDecoration(
        color: CncColors.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CncColors.border),
      ),
      child: JogKey(
        '',
        () => jog('z', sign),
        enabled: enabled,
        repeat: step <= 1.0,
        onJogStart: () => jogStart('z', sign),
        onJogKeepalive: jogKeepalive,
        onJogEnd: jogEnd,
        flat: true,
        height: 56,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: CncColors.textMain),
            const SizedBox(width: 4),
            Text(_stepLabel(step),
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: CncColors.textMain)),
          ],
        ),
      ),
    );
  }

  /// 步长胶囊（规格 §7-4）：70 宽、圆角 999、字 12。
  Widget _pill(double v, bool sel) {
    return GestureDetector(
      onTap: () => ref.read(jogStepProvider.notifier).state = v,
      child: Container(
        width: 70,
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: sel ? CncColors.successBg : CncColors.card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: sel ? CncColors.blue : CncColors.border),
        ),
        child: Center(
          child: Text(_stepLabel(v),
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                  color: sel ? CncColors.successFg : CncColors.textSub)),
        ),
      ),
    );
  }

  /// A 轴钮（规格 §7-5）：边 1px border、圆角 9、字 12.5 icon 色。
  /// 接口未通：纯展示，无手势、无标签。
  Widget _aBtn(IconData icon, double step) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: CncColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: CncColors.icon),
          const SizedBox(width: 4),
          Text(_stepLabel(step),
              style: TextStyle(fontSize: 12.5, color: CncColors.icon)),
        ],
      ),
    );
  }

  /// 底部动作键（规格 §7-6）：三等分、圆角 10、高 40、字 12.5。
  Widget _actionKey(String label, VoidCallback? onTap,
      {required Color fg, required Color bg, required Color border}) {
    return Expanded(
      child: SizedBox(
        height: 40,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: border),
            ),
            child: Center(
              child: Text(label,
                  style: TextStyle(fontSize: 12.5, color: fg)),
            ),
          ),
        ),
      ),
    );
  }
}

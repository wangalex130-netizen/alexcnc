import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import '../../l10n/strings_zh.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/jog_key.dart';
import '../../app/config.dart';
import '../../models/jog_profile.dart';
import '../../app/runtime_config.dart';
import '../../app/theme.dart';
import '../../models/machine_status.dart';
import '../../services/hardware_service.dart';
import '../../state/providers.dart';

export '../../widgets/jog_key.dart';

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
      // A1-2：连续模式同样按当前档位给进给（0.1→F300 / 1→F600 / 10→F1500）。
      final sent =
          await widget.hw.jogContinuous(axis, sign, feed: jogFeedForStep(step));
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

    /// 连续点动保活（A2）：按住期间由 JogKey 每 200ms 回调一次。
    ///
    /// 固件 600ms 收不到保活就自行写 0x85 停机 —— 保活是连续模式**能持续**
    /// 的前提，不是可选冗余。用 `_jogActive` 再兜一层：jogStart 未能发出
    /// （外网被拦 / MQTT 未连）时不应继续打扰固件。
    void jogKeepalive() {
      if (!_jogActive) return;
      widget.hw.jogKeepalive();
    }

    /// 八向盘点按（§3.2a）：直边走既有单轴 jog；斜角走 jogXY 一条
    /// `$J=G91 X.. Y..` 联动帧（固件 cnc_net.c:1439-1460 现成），每轴分量 =
    /// 步长÷√2（合成位移 = 标称步长）。屏幕上 = 机床 Y+，故 my = -dy。
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

    /// 软复位：加工中/暂停中会中断作业，故需二次确认；空闲/报警态直接执行。
    Future<void> doSoftReset() async {
      if (!canReset) return;
      final running = mState == MachineState.busy || mState == MachineState.paused;
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
      // 解锁后机器坐标不可信（$X 只是清锁，没有重建坐标系），必须提示重新定原点。
      if (mounted) toast('已解除报警锁定 · 请重新定原点后再加工');
    }

    return Container(
      decoration: BoxDecoration(
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
              Text(S.manualMove,
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
                      style: TextStyle(fontSize: 10, color: CncColors.warning)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // 步进档位
          Row(
            children: [
              Text('步进',
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
          // 八向盘（§3.2a）：8 向 + 中心方位标识，直边长按连续、斜角仅点按
          // —— 与定原点页①盘同款（widgets/octagon_dial.dart，共享组件）。
          Row(
            children: [
              Expanded(
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
                  centerLabel: 'XY',
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 52,
                child: Column(
                  children: [
                    JogKey('Z+', () => jog('z', 1),
                        onJogStart: () => jogStart('z', 1),
                        onJogKeepalive: jogKeepalive,
                        onJogEnd: jogEnd, enabled: canControl,
                        repeat: step <= 1.0),
                    JogKey('Z−', () => jog('z', -1),
                        onJogStart: () => jogStart('z', -1),
                        onJogKeepalive: jogKeepalive,
                        onJogEnd: jogEnd, enabled: canControl,
                        repeat: step <= 1.0),
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
                    JogKey(S.jogReset, doSoftReset,
                        enabled: canReset, repeat: false, danger: true),
                    const SizedBox(height: 6),
                    JogKey('解锁', doUnlock,
                        enabled: canUnlock, repeat: false, danger: true),
                    const SizedBox(height: 6),
                    JogKey('回零', () {
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
          Text(S.t(S.stepJogLong, {'step': step.toStringAsFixed(1)}),
              style: TextStyle(fontSize: 11, color: CncColors.textSub)),
        ],
      ),
    );
  }
}

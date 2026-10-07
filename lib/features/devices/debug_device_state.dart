import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/machine_status.dart';

/// 设备状态模拟（2026-10-04）—— **仅联调/演示用**，生产路径零影响。
///
/// ## 为什么需要
/// 客户机器多数时间处于「离线 / 空闲」，而状态环的**加工中（旋转）**与
/// **报警（双环脉动）**只有在对应真实状态出现时才能看到。
/// 昊总实机反馈「第一台也没有动效」——因为当时 4 台全是**离线**，
/// 而离线按设计就是静态断口环（离线机器不该"动"），属预期行为。
/// 但验收"动效是否好看"不能等真机雕刻一整夜。
///
/// ## 为什么用 Riverpod 而非 ChangeNotifier
/// 初版用 `ChangeNotifier` + 父页 `setState`，**点了没反应** ——
/// 设备卡是独立子组件，父级 setState 不会重建它们（它们不是 inline 定义）。
/// 改成 StateNotifier 后由 provider 驱动，设备卡 watch 才会更新。已踩过。
///
/// ## 边界（刻意收窄）
///  - **仅进程内**：不落盘，App 重启即清；
///  - 开启时只改**演示态的 presence 视图**，**不下发任何指令**、不驱动真机；
///  - 默认关闭；正式包（无 DEBUG_TOOLS define）入口隐藏。
class DebugDeviceState extends StateNotifier<DebugDeviceStateValue> {
  DebugDeviceState._() : super(const DebugDeviceStateValue());

  static final DebugDeviceState instance = DebugDeviceState._();

  bool get enabled => state.enabled;
  MachineState? get simulated => state.simulated;
  double get simulatedProgress => state.simulatedProgress;

  /// 开启/关闭模拟。关闭即恢复真实数据。
  void setEnabled(bool v) {
    if (state.enabled == v) return;
    state = state.copyWith(enabled: v);
  }

  /// 切换模拟状态。null 表示"用真实状态"。
  void setSimulated(MachineState? s) {
    if (state.simulated == s) return;
    // ⚠️ 不能用 copyWith：它的 `simulated ?? this.simulated` 无法把 null 写回去
    //（null 会被当成"没传"），导致「回到真实」这一档永远切不过去。
    state = DebugDeviceStateValue(
      enabled: state.enabled,
      simulated: s,
      simulatedProgress: state.simulatedProgress,
    );
  }

  void setProgress(double p) {
    final v = p.clamp(0.0, 1.0);
    if (state.simulatedProgress == v) return;
    state = state.copyWith(simulatedProgress: v);
  }

  /// 依次轮换，方便快速预览全部形态。
  void cycle() {
    const order = <MachineState?>[
      MachineState.busy,
      MachineState.idle,
      MachineState.alarm,
      MachineState.paused,
      null, // 回到真实
    ];
    final i = order.indexOf(state.simulated);
    setSimulated(order[(i + 1) % order.length]);
  }

  void reset() {
    state = const DebugDeviceStateValue();
  }
}

/// 模拟状态值（不可变）。
class DebugDeviceStateValue {
  final bool enabled;
  final MachineState? simulated;
  final double simulatedProgress;

  const DebugDeviceStateValue({
    this.enabled = false,
    this.simulated,
    this.simulatedProgress = 0.62,
  });

  DebugDeviceStateValue copyWith({
    bool? enabled,
    MachineState? simulated,
    double? simulatedProgress,
  }) =>
      DebugDeviceStateValue(
        enabled: enabled ?? this.enabled,
        simulated: simulated ?? this.simulated,
        simulatedProgress: simulatedProgress ?? this.simulatedProgress,
      );

  @override
  bool operator ==(Object other) =>
      other is DebugDeviceStateValue &&
      other.enabled == enabled &&
      other.simulated == simulated &&
      other.simulatedProgress == simulatedProgress;

  @override
  int get hashCode => Object.hash(enabled, simulated, simulatedProgress);
}

/// Riverdog 入口（设备页 watch 这个 ⇒ 模拟变化会重建设备卡）。
final debugDeviceStateProvider = StateNotifierProvider<DebugDeviceState,
    DebugDeviceStateValue>((ref) => DebugDeviceState.instance);

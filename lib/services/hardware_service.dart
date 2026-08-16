import 'dart:async';

import '../models/broadcast_message.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/telemetry.dart';
import '../models/tool.dart';

/// 链路连接态：UI 据此显示「连接中 / 已连 / 掉线」，不影响功能逻辑。
enum ConnectionState { disconnected, connecting, connected }

/// Hardware boundary for the ESP32 / modified-Grbl controller.
///
/// All wire-protocol JSON (Grbl `$`-commands, status reports, MQTT payloads)
/// is encapsulated inside the implementation. To go live, replace
/// [MockHardwareService] with a real implementation that talks WiFi/Telnet or
/// MQTT to the MCU — the rest of the app never changes.
abstract class HardwareService {
  /// Live machine status, broadcast by the MCU (SSOT).
  Stream<MachineStatus> get statusStream;

  /// 机器异步事件（job_done / alarm / confirm_required 等）一次性提示流。
  /// 与 [statusStream] 分离，避免状态帧反复冲刷 toast/横幅。
  Stream<NotifyEvent> get notifyStream;

  /// 机器遥测帧流（cnc/<deviceId>/telemetry，高频 QoS0），与 [statusStream] 分离，
  /// 避免高频刷新冲刷状态/事件流。
  Stream<Telemetry> get telemetryStream;

  /// 系统级广播流（docs/03 §6 `cnc/broadcast/msg` + §7 `cnc/broadcast/system`）。
  /// 平台/运维下发的全局公告（维护通知 / 设备离线等），与机器 [notifyStream] 分离，
  /// App 仅作顶部横幅 / toast 提示，不污染机器 SSOT 状态。
  Stream<BroadcastMessage> get broadcastStream;

  Future<void> connect();
  Future<void> disconnect();
  Future<MachineStatus> getStatus();

  /// Machine physical work area (mm). Determined by connected model config.
  Future<({double widthMm, double heightMm})> getWorkArea();

  // --- Motion (locked when !isLocalLAN) ---
  Future<void> jog(String axis, double distanceMm); // axis: x | y | z
  Future<void> home(); // homing cycle ($H)
  Future<void> setWorkZero({double x = 0, double y = 0, double z = 0}); // G54

  // --- Spindle / aux ---
  Future<void> startSpindle(double rpm);
  Future<void> stopSpindle();
  Future<void> setAux(String key, bool on); // light | laser | timelapse | fan

  // --- Job control ---
  Future<void> startJob();
  Future<void> pauseJob();
  Future<void> resumeJob();
  Future<void> stopJob(); // soft stop

  // --- ATC ---
  Future<void> updateToolMap(List<Tool> tools);

  // --- Leveling plan ---
  /// 向导 Step5：App 根据云端下发的模型尺寸 + 用户所选模式算好探测点阵，
  /// 下发给 MCU。固件收到后执行真实网格探测并以广播结果为准。
  /// [mode] 0=不调平 / 1=标准 / 2=精细；[cols]/[rows] 为探测点数阵。
  Future<void> setLevelingPlan(
      {required int mode, required int cols, required int rows});

  /// 当前是否为云端模式（命令走 MQTT 网关，不自动连局域网 TCP）。
  bool get isCloudMode;

  /// 云端 MQTT 是否已连接（仅云端模式有意义）。
  bool get isMqttConnected;

  /// 局域网 TCP 是否已连接（仅局域网模式有意义）。
  bool get isTcpConnected;

  /// 释放底层连接（MQTT / TCP socket）。由 Provider 在 dispose 时调用。
  void dispose();
}

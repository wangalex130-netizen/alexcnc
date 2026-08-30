import 'dart:async';

import '../models/broadcast_message.dart';
import '../models/camera_stream_state.dart';
import '../models/job_progress.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/sys_info.dart';
import '../models/telemetry.dart';
import '../models/tool.dart';

/// 链路连接态：UI 据此显示「连接中 / 已连 / 掉线」，不影响功能逻辑。
enum LinkState { disconnected, connecting, connected }

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

  /// 雕刻作业明细流（docs/03 §10.5 `cnc/<deviceId>/job`，QoS1 + retain）。
  /// 与 [statusStream] 分离：作业行号/总行数/百分比高频变化，避免膨胀状态帧。
  Stream<JobProgress> get jobStream;

  /// 机器系统帧流（docs/03 §10.6 `cnc/<deviceId>/sys`，QoS1 + retain，上电一次）。
  /// 设备身份 / 机型 / 固件版本 / 局域网 IP / 启动时间戳，用于设备信息展示与诊断。
  Stream<SysInfo> get sysStream;

  /// 摄像头推流状态流（docs/03 `cnc/<deviceId>/cam`）。
  /// 摄像头对 `stream_start` / `stream_stop` 的回执（`{"streaming":true/false}`）
  /// 与上下线帧（`{"online":true/false}`）。
  /// App 据此判断摄像头是否真的启动了推流，避免只能干等第一帧 MJPEG。
  /// 未订阅该主题（如 Mock）时为空流。
  Stream<CameraStreamState> get cameraStream;

  Future<void> connect();
  Future<void> disconnect();
  Future<MachineStatus> getStatus();

  /// Machine physical work area (mm). Determined by connected model config.
  Future<({double widthMm, double heightMm})> getWorkArea();

  // --- Motion（终局方案：只由机器状态决定可否执行，不再看内外网）---
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

  // --- Camera on-demand streaming (see docs/03 §camera-on-demand) ---
  /// 摄像头按需推流控制：点播放发 `stream_start`，退出预览发 `stream_stop`。
  /// 摄像头固件订阅 `cnc/<deviceId>/cmd`（见 cam_mqtt.c）。
  /// 终局方案下机器控制命令也走同一主题，靠 payload 区分（机器 `cmd` / 摄像头 `action`）。
  /// [deviceId] 省略时取当前实例 deviceId（= 机器码 = 摄像头 ID）。
  void sendCameraStream(String action, {String? deviceId});

  /// 当前是否为云端模式（终局方案：命令走外网 MQTT，不自动连局域网 TCP）。
  bool get isCloudMode;

  /// 云端 MQTT 是否已连接（仅云端模式有意义）。
  bool get isMqttConnected;

  /// 局域网 TCP 是否已连接（仅局域网模式有意义）。
  bool get isTcpConnected;

  /// 链路连接态流：connecting / connected / disconnected，UI 订阅以显示链路状态。
  Stream<LinkState> get connectionState;

  /// 当前链路连接态快照。
  LinkState get currentLinkState;

  /// 最近一次连接/掉线的错误信息（仅用于 UI 诊断）。
  /// null 表示尚未失败或错误已被清除。
  String? get lastConnectionError;

  /// 被 broker 拒绝的订阅主题（SUBACK 返回 0x80）。
  ///
  /// `deny_action=ignore` 下被拒的订阅**不会断线、界面也无任何异常** ——
  /// App 只是永远收不到该主题的帧。这类故障极难排查（表现为"点了没反应"），
  /// 因此在这里显式暴露出来，供联调设置 / 诊断展示。
  /// Mock 恒为空。
  List<String> get deniedSubscriptions;

  /// 手动触发一次重连（取消等待中的退避计时，立即重试）。
  Future<void> reconnect();

  /// 释放底层连接（MQTT / TCP socket）。由 Provider 在 dispose 时调用。
  void dispose();
}

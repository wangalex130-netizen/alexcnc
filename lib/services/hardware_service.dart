import 'dart:async';

import '../models/broadcast_message.dart';
import '../models/camera_stream_state.dart';
import '../models/carve_session.dart';
import '../models/job_progress.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/sys_info.dart';
import '../models/telemetry.dart';
import '../models/tool.dart';

/// 链路连接态：UI 据此显示「连接中 / 已连 / 掉线」，不影响功能逻辑。
enum LinkState { disconnected, connecting, connected }

/// 关键命令的送达 / 回执状态（雕刻启动两段式，2026-09-02）。
///
/// 远程启动改为「App 下发 → 机器待确认 → 客户按物理键动刀」后，命令是否真的
/// 送达机器、机器是否真的进入待确认，App 必须如实呈现，不能"点了就算成功"。
enum CommandDeliveryState {
  /// 无待处理命令。
  idle,

  /// MQTT 未连接，命令已入队，等链路恢复后自动补发。
  queued,

  /// 已发出，正在等机器回执（状态变化或 notify 事件）。
  sent,

  /// 超时未收到回执，正在重发（第 n 次）。
  retrying,

  /// 已确认：机器回执到达（状态变化 / notify / awaitingConfirm）。
  acked,

  /// 重试次数耗尽仍无回执。UI 应提示"指令未送达，请检查机器联网"。
  failed,
}

/// 一条待送达命令的运行时状态，供 UI 显示"指令未送达，正在重试"。
class PendingCommand {
  /// 下发的命令帧（JSON），用于重发。
  final Map<String, dynamic> cmd;

  /// 命令的可读名（用于 UI 文案，如「开始雕刻」）。
  final String label;

  /// 当前送达状态。
  final CommandDeliveryState state;

  /// 已重发次数（0 = 尚未重发）。
  final int retries;

  const PendingCommand({
    required this.cmd,
    required this.label,
    required this.state,
    this.retries = 0,
  });

  PendingCommand copyWith({
    CommandDeliveryState? state,
    int? retries,
  }) =>
      PendingCommand(
        cmd: cmd,
        label: label,
        state: state ?? this.state,
        retries: retries ?? this.retries,
      );
}

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

  /// 软复位（Grbl `Ctrl-X` = 0x18）。立即中止当前运动、清空规划器缓冲。
  ///
  /// 🔴 与 [unlock] 一起构成「报警自救」组合：机器进入 Alarm 后 Jog 全部锁定，
  /// **只有这两个动作仍然可用**，否则 App 永远救不回报警状态。
  /// UI 上不受 `state == idle` 闸门限制（见 `jog_sheet.dart`）。
  Future<void> softReset();

  /// 解除报警锁定（Grbl `$X`）。清除 Alarm/Lock 位，让机器回到可运动状态。
  ///
  /// ⚠️ 安全口径：只清锁，**不自动回零、不自动移动**。解锁后坐标不可信，
  /// 必须由用户在向导里重新定原点/回零。UI 上需二次确认。
  Future<void> unlock();

  // --- Spindle / aux ---
  Future<void> startSpindle(double rpm);
  Future<void> stopSpindle();
  Future<void> setAux(String key, bool on); // light | laser | timelapse | fan

  // --- Job control ---
  Future<void> startJob();
  Future<void> pauseJob();
  Future<void> resumeJob();
  Future<void> stopJob(); // soft stop

  // --- 雕刻主链路 v2（闫安文档 §6.8/6.9，2026-09-03）---
  /// 第一阶段：下发 `prepare_job`，让小屏下载并校验 G-code。
  ///
  /// 🔴 **App 不持有/不上传 G-code**（D2）：只把模型库下发的
  /// `roughingGcodeUrl`/`finishingGcodeUrl` 这个 **HTTPS URL** 传给小屏，
  /// 由小屏自己下载。App 全程不接触 G-code 文件字节。
  ///
  /// [sizeBytes]/[sha256] 后台暂未提供，先传 0/空；按工程师确认的方案 A，
  /// 小屏此时**跳过完整性校验**，只下载即可继续流程。
  /// 后台接口补齐这两个字段后，App 传入真值即可（无需改结构）。
  Future<void> prepareJob({
    required String fileUrl,
    String fileName = 'job.gc',
    int sizeBytes = 0,
    String sha256 = '',
  });

  /// 第二阶段：下发 `confirm`，让小屏开始向 GRBL 流式传输（真实动刀）。
  ///
  /// 必须在 [prepareJob] 的 ACK 成功（阶段 = ready）之后调用。
  Future<void> confirmJob();

  /// 雕刻作业阶段流（preparing / ready / confirming / running / failed）。
  Stream<CarveSession> get carveSession;

  /// 当前雕刻作业快照。
  CarveSession get currentCarveSession;

  /// 清除当前雕刻会话（回到 idle）。用于客户主动放弃 / 关闭失败提示面板。
  void clearCarve();

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

  /// 关键命令的送达 / 回执状态流（雕刻启动两段式，2026-09-02）。
  ///
  /// 只有「关键命令」（开始 / 暂停 / 继续 / 停止雕刻）参与重发与回执跟踪；
  /// Jog、主轴等高频或即时命令不参与（避免重发造成意外运动）。
  /// 无待处理命令时为 [CommandDeliveryState.idle] 且 [pendingCommand] 为 null。
  Stream<CommandDeliveryState> get commandDelivery;

  /// 当前待处理命令快照（null = 无）。UI 据此显示「指令未送达，正在重试（第 n 次）」。
  PendingCommand? get pendingCommand;

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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../app/config.dart';
import '../models/broadcast_message.dart';
import '../models/camera_stream_state.dart';
import '../models/job_progress.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/position.dart';
import '../models/sys_info.dart';
import '../models/telemetry.dart';
import '../models/tool.dart';
import 'device_discovery.dart';
import 'hardware_service.dart';

/// 真实硬件实现。
///
/// **2026-08-28 终局方案**（PC / 云端 / 固件三方确认，替代原 R2 网关转发）：
///  - 不再区分内网 / 外网权限，命令与状态**全部走外网 MQTT Broker**；
///  - ClientId = `android-<deviceId>`（设备维度，不再按账号维度、也不再加随机后缀）；
///  - 命令发布到 `cnc/<deviceId>/cmd`；原 `gw/<deviceId>/cmd` 网关转发、
///    `wan_whitelist` 白名单与 `gw/<deviceId>/ack` 回执主题均已废弃；
///  - 心跳 `{"cmd":"hello"}` 由原局域网 TCP 改为经同一 MQTT 命令主题下发，
///    用于重置机器主控的 15s Feed Hold 定时器。
///
/// 状态 / 事件订阅 `cnc/<deviceId>/status`、`notify`、`telemetry`、`job`、`sys`
/// 与 `cnc/broadcast/#`。离线 / 未连时静默不报错，UI 仅显示为 disconnected。
class RealHardwareService implements HardwareService {
  final String broker;
  final int mqttPort;
  final String mqttUser;
  final String mqttPass;
  final String deviceId;
  final int tcpPort;
  /// 第二步外网开关；第一步（LAN）保持 false，MQTT 链路不启用。
  final bool cloudEnabled;
  // 说明：App 登录身份（userId）已不再参与 MQTT ClientId 派生 —— 终局方案固定为
  // `android-<deviceId>`。userId 现仅用于摄像头中继拉流的 `user=` 鉴权参数，
  // 由 RuntimeConfig.resolvedAppUserId 提供，本服务不再持有该字段。

  /// 局域网 TCP 主机（可变：未手动配置时由 UDP beacon 自动发现覆盖）。
  String _tcpHost;
  bool _mqttConnected = false;
  Timer? _heartbeatTimer;
  /// 固件 15s 内收不到任何命令即 Feed Hold；心跳周期取 10s 留安全余量。
  static const Duration _heartbeatInterval = Duration(seconds: 10);

  final _ctrl = StreamController<MachineStatus>.broadcast();
  /// 机器异步事件流（job_done / alarm / confirm_required 等一次性提示）。
  final _notifyCtrl = StreamController<NotifyEvent>.broadcast();
  /// 机器遥测流（cnc/<deviceId>/telemetry，高频 QoS0）。
  final _telemetryCtrl = StreamController<Telemetry>.broadcast();
  /// 系统级广播流（docs/03 §6 cnc/broadcast/msg + §7 cnc/broadcast/system）。
  final _broadcastCtrl = StreamController<BroadcastMessage>.broadcast();
  /// 雕刻作业明细流（docs/03 §10.5 cnc/<deviceId>/job，QoS1 + retain）。
  final _jobCtrl = StreamController<JobProgress>.broadcast();
  /// 机器系统帧流（docs/03 §10.6 cnc/<deviceId>/sys，QoS1 + retain，上电一次）。
  final _sysCtrl = StreamController<SysInfo>.broadcast();

  /// 摄像头推流状态（cnc/<deviceId>/cam）。2026-08-30 补：此前 App 未订阅该主题。
  final _camCtrl = StreamController<CameraStreamState>.broadcast();

  /// 被 broker 拒绝的订阅主题（SUBACK 0x80）。见 [deniedSubscriptions]。
  final List<String> _deniedSubs = <String>[];
  MqttServerClient? _mqtt;
  Socket? _tcp;
  bool _tcpConnected = false;

  // ---- 连接态（重连 + UI 展示，不改变功能逻辑）----
  LinkState _conn = LinkState.disconnected;
  final _connCtrl = StreamController<LinkState>.broadcast();
  String? _lastConnError;
  Timer? _reconnectTimer;
  Timer? _tcpReconnectTimer;
  int _reconnectAttempts = 0;
  bool _closing = false;

  // ---- 关键命令送达 / 重发队列（雕刻启动两段式，2026-09-02）----
  /// 送达状态广播流：UI 据此显示「已下发 / 指令未送达，正在重试」。
  /// 必须是 broadcast（StreamBuilder 订阅的流若单订阅，页面二次进入会抛
  /// `already listened to` 并把整块子树搞白 —— 2026-08-31 已踩过这个坑）。
  final _cmdCtrl = StreamController<CommandDeliveryState>.broadcast();

  /// 当前等待送达的关键命令（null = 无待处理）。
  PendingCommand? _pending;

  /// MQTT 未连接时暂存的关键命令，链路恢复后按序补发。
  final List<PendingCommand> _cmdQueue = <PendingCommand>[];

  /// 回执超时定时器：下发后 N 秒未收到机器回执即触发重发。
  Timer? _ackTimer;

  /// 关键命令回执等待时长。固件自检 / 待确认广播有延迟，给足窗口避免误重发。
  static const Duration _ackTimeout = Duration(seconds: 5);

  /// 关键命令最大重发次数（不含首次下发）。超限判定 failed，由 UI 提示。
  static const int _maxCmdRetries = 3;

  /// MQTT clientId：终局方案固定为 `android-<deviceId>`（设备维度，无随机后缀）。
  /// 与屏幕 `screen-<deviceId>`、摄像头 `cam-<deviceId>`、云网关 `bridge-aliyun-api`
  /// 互不相同，故多端可同时连同一 Broker 而不互踢。
  ///
  /// **已知限制**：同一台机器被多台手机同时连接时会因 ClientId 重复而互踢。
  /// 工程师确认"暂不考虑此场景"；量产前若需支持，需重新约定命名规则（如补随机后缀）。
  final String _mqttClientId;

  final Map<String, bool> _aux = {
    'light': false,
    'laser': false,
    'timelapse': false,
    'fan': false,
  };

  RealHardwareService({
    this.broker = AppConfig.mqttBroker,
    this.mqttPort = AppConfig.mqttPort,
    this.mqttUser = AppConfig.mqttUser,
    this.mqttPass = AppConfig.mqttPass,
    this.deviceId = AppConfig.deviceId,
    String tcpHost = AppConfig.deviceTcpHost,
    this.tcpPort = AppConfig.deviceTcpPort,
    this.cloudEnabled = false,
  })  : _tcpHost = tcpHost,
        _mqttClientId = 'android-$deviceId';

  /// MQTT 状态广播主题：cnc/<deviceId>/status（按实例 deviceId 推导，App 订阅）
  String get mqttStatusTopic => 'cnc/$deviceId/status';

  /// MQTT 命令下发主题：cnc/<deviceId>/cmd
  /// 终局方案：App 直接发布，固件（屏幕 / 主控）订阅该主题；
  /// 原 `gw/<deviceId>/cmd` 网关转发与 wan_whitelist 白名单已废弃。
  String get mqttCmdTopic => 'cnc/$deviceId/cmd';

  /// 摄像头命令主题：cnc/<deviceId>/cmd（摄像头固件订阅，见 cam_mqtt.c）。
  /// 终局方案下与机器控制命令**同一个主题**，靠 payload 区分：
  /// 机器帧为 {'cmd': ...}，摄像头帧为 {'action': 'stream_start'/'stream_stop'}。
  /// 按需推流经此下发 stream_start/stream_stop。
  String mqttCamCmdTopic(String id) => 'cnc/$id/cmd';

  /// App 在线状态主题（LWT + 上线发布，retain）：cnc/<deviceId>/app
  String get mqttAppTopic => 'cnc/$deviceId/app';

  /// MQTT 事件通知主题：cnc/<deviceId>/notify（job_done / alarm / confirm_required 等）
  String get mqttNotifyTopic => 'cnc/$deviceId/notify';

  /// MQTT 遥测主题：cnc/<deviceId>/telemetry（温度/转速/进给/坐标，QoS0 高频）
  String get mqttTelemetryTopic => 'cnc/$deviceId/telemetry';

  /// 系统级消息广播主题（docs/03 §6）：cnc/broadcast/msg
  ///  {level:info|warn|error, title, body, target}
  String get mqttBroadcastTopic => 'cnc/broadcast/msg';

  /// 系统级事件广播主题（docs/03 §7）：cnc/broadcast/system
  ///  {event:device_offline|..., deviceId, ts}
  String get mqttSystemTopic => 'cnc/broadcast/system';

  /// 雕刻作业明细主题（docs/03 §10.5）：cnc/<deviceId>/job（QoS1 + retain）
  ///  {file, line, total, percent, phase}
  String get mqttJobProgressTopic => 'cnc/$deviceId/job';

  /// 机器系统帧主题（docs/03 §10.6）：cnc/<deviceId>/sys（QoS1 + retain，上电一次）
  ///  {id, model, fw, ip, bootAt}
  String get mqttSysInfoTopic => 'cnc/$deviceId/sys';

  /// 摄像头状态主题（docs/03 §camera-on-demand）：cnc/<deviceId>/cam
  ///  摄像头固件发布 {"streaming":true/false}（流控回执）与 {"online":true/false}（上下线）。
  ///  注意：**不是** cnc/<deviceId>/status —— status 是机器状态专用主题，
  ///  摄像头发过去会被 App 解析成 idle，导致加工中 Jog 被误解锁（08-29 安全修复）。
  String get mqttCamStatusTopic => 'cnc/$deviceId/cam';

  @override
  Stream<MachineStatus> get statusStream => _ctrl.stream;

  /// 异步事件流：UI 订阅以弹 toast / 横幅（与 statusStream 分离）。
  @override
  Stream<NotifyEvent> get notifyStream => _notifyCtrl.stream;

  /// 遥测流：UI 订阅以展示温度/转速/进给/坐标读数（与 statusStream 分离）。
  @override
  Stream<Telemetry> get telemetryStream => _telemetryCtrl.stream;

  /// 系统级广播流：UI 订阅以弹横幅/通知（与 notifyStream 分离，源自 docs/03 广播主题）。
  @override
  Stream<BroadcastMessage> get broadcastStream => _broadcastCtrl.stream;

  /// 雕刻作业明细流：UI 订阅以展示行号/总行数/百分比/阶段（与 statusStream 分离）。
  @override
  Stream<JobProgress> get jobStream => _jobCtrl.stream;

  /// 机器系统帧流：UI 订阅以展示设备信息（机型/固件/IP/在线时长）。
  @override
  Stream<SysInfo> get sysStream => _sysCtrl.stream;

  /// 摄像头推流状态流：UI 订阅以判断摄像头是否真的启动了推流。
  @override
  Stream<CameraStreamState> get cameraStream => _camCtrl.stream;

  /// 连接态流：connecting / connected / disconnected，UI 订阅以显示链路状态。
  Stream<LinkState> get connectionState => _connCtrl.stream;
  LinkState get currentLinkState => _conn;

  @override
  Stream<CommandDeliveryState> get commandDelivery => _cmdCtrl.stream;

  @override
  PendingCommand? get pendingCommand => _pending;

  /// 最近一次连接失败的错误信息，供 UI 诊断用。
  @override
  String? get lastConnectionError => _lastConnError;

  @override
  List<String> get deniedSubscriptions => List<String>.unmodifiable(_deniedSubs);

  /// 取消退避计时并立即重试一次（用于 UI 手动重连 / 设置页诊断）。
  @override
  Future<void> reconnect() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (cloudEnabled) {
      await _connectMqtt();
    } else {
      await connect();
    }
  }

  /// 当前是否为云端模式（命令走 MQTT 网关，不自动连局域网 TCP）。
  bool get isCloudMode => cloudEnabled;

  /// 云端 MQTT 是否已连接（仅云端模式有意义）。
  bool get isMqttConnected => _mqttConnected;

  /// 局域网 TCP 是否已连接（仅局域网模式有意义）。
  bool get isTcpConnected => _tcpConnected;

  @override
  Future<void> connect() async {
    if (cloudEnabled) {
      // 终局方案：统一走外网 MQTT 主链路，不再自动连局域网 TCP。
      // 命令一律发布到 cnc/<deviceId>/cmd（原网关 gw/<deviceId>/cmd 已废弃）。
      await _connectMqtt();
      return;
    }
    // 第一步局域网：UDP beacon 自动发现真机 IP，再直连 TCP。
    if (_tcpHost == AppConfig.deviceTcpHost) {
      try {
        final b = await DeviceDiscovery.discoverViaBeacon(
            timeout: const Duration(seconds: 3));
        if (b != null && b.ip.isNotEmpty) _tcpHost = b.ip;
      } catch (_) {
        // 无 beacon 网络时静默，走已配置地址
      }
    }
    _connectTcp();
  }

  Future<void> _connectMqtt() async {
    if (_conn == LinkState.connected) return;
    _setConn(LinkState.connecting);
    try {
      // 每次重连都新建 client，避免复用已断开实例的脏状态。
      // clientId 用终局方案约定的 android-<deviceId>（设备维度），与屏幕 screen-<deviceId>、
      // 摄像头 cam-<deviceId>、云网关 bridge-aliyun-api 互不相同，多端不会互踢。
      final client = MqttServerClient(broker, _mqttClientId);
      client.port = mqttPort;
      client.secure = true;                          // 启用 TLS（8883）
      // 注意：必须显式用 Object 收参。mqtt_client 10.5.0 的 MqttServerClient.onBadCertificate
      // 字段声明为 bool Function(X509Certificate)?，但库内部会 as bool Function(Object)?，
      // 若写成 (cert) => true 被推断成 X509Certificate 参数就会在运行时 cast 失败
      //（报错：type '(X509Certificate)=>bool' is not a subtype of '((Object)=>bool)?'）。
      client.onBadCertificate = (Object cert) => true; // 信任自签证书，仅联调期；上线换正式 CA 后删除此行
      client.keepAlivePeriod = 30;
      client.logging(on: false);
      client.onDisconnected = _onMqttDisconnected;
      // 订阅被 broker 拒绝（SUBACK 0x80）时记录。
      // deny_action=ignore 下连接照常、界面无异常，只是永远收不到该主题的帧 ——
      // 这是最难排查的一类故障（表现为"点了没反应"），必须显式留痕。
      // 2026-08-30：cnc/<id>/cam 当前就处于这个状态（acl.conf 未给 app-demo 开订阅）。
      client.onSubscribeFail = (String topic) {
        if (!_deniedSubs.contains(topic)) {
          _deniedSubs.add(topic);
        }
        // ignore: avoid_print
        print('[MQTT] subscribe DENIED (ACL): $topic');
      };
      // App LWT：断线时 Broker 代发 offline（retain），使其他端能感知 App 掉线。
      // 上线后下方主动发布 online（retain）覆盖，呈现"在线"最新态。
      // 注意：acl.conf 需放行 app-demo 对 cnc/<deviceId>/app 的 PUBLISH，否则 will 被丢弃（连接仍成功）。
      // mqtt_client 的 LWT 通过 MqttConnectMessage 链式配置，再赋值给 connectionMessage。
      client.connectionMessage = MqttConnectMessage()
          .withWillTopic(mqttAppTopic)
          .withWillMessage(jsonEncode({'online': false}))
          .withWillQos(MqttQos.atLeastOnce)
          .withWillRetain()
          .startClean();
      await client.connect(
        mqttUser.isEmpty ? null : mqttUser,
        mqttPass.isEmpty ? null : mqttPass,
      );
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _mqtt = client;
        _mqttConnected = true;
        _lastConnError = null; // 成功后清除历史错误
        client.subscribe(mqttStatusTopic, MqttQos.atLeastOnce);
        client.subscribe(mqttNotifyTopic, MqttQos.atLeastOnce);
        client.subscribe(mqttTelemetryTopic, MqttQos.atMostOnce); // 遥测高频，QoS0
        // docs/03 §6/§7 系统级广播（全局主题，任意设备发起的事件/消息）
        client.subscribe(mqttBroadcastTopic, MqttQos.atLeastOnce);
        client.subscribe(mqttSystemTopic, MqttQos.atLeastOnce);
        // 摄像头推流状态（2026-08-30 补订阅）：此前未订阅，导致发出 stream_start 后
        // 无法确认摄像头是否真的启动，只能干等第一帧 MJPEG（实测约一二十秒）。
        // ⚠️ 依赖 broker 侧：app-demo 的 subscribe 白名单需包含 cnc/+/cam
        //    （见 docs/38 的 M-5）。当前 acl.conf:23 尚未包含，
        //    在开通前这一行会被静默拒绝（deny_action=ignore，SUBACK 0x80 无提示），
        //    由 onSubscribeFail 回调暴露出来，不会影响其它订阅。
        client.subscribe(mqttCamStatusTopic, MqttQos.atLeastOnce);
        // V1.1（docs/03 §10.5/§10.6）设备→服务器上行主题（QoS1 + retain）。
        // 受 broker ACL 限制，默认不订阅；等服务器 ACL 开放后再启用。
        if (AppConfig.v11MqttTopicsEnabled) {
          client.subscribe(mqttJobProgressTopic, MqttQos.atLeastOnce);
          client.subscribe(mqttSysInfoTopic, MqttQos.atLeastOnce);
        }
        // 上线即发布 online（retain），覆盖 LWT 的离线态
        final ob = MqttClientPayloadBuilder();
        ob.addString(jsonEncode({'online': true}));
        client.publishMessage(
            mqttAppTopic, MqttQos.atLeastOnce, ob.payload!,
            retain: true);
        client.updates!.listen(_onMqtt);
        _reconnectAttempts = 0;
        _setConn(LinkState.connected);
        _updateHeartbeat();
        // 补发断连期间排队的关键命令（雕刻启动两段式：指令不能因掉线丢失）
        _flushCmdQueue();
      } else {
        _mqttConnected = false;
        final reason = client.connectionStatus?.returnCode?.toString() ?? 'broker returned non-zero CONNACK';
        _lastConnError = 'MQTT 握手失败：$reason';
        _setConn(LinkState.disconnected);
        _scheduleReconnect();
      }
    } catch (e, st) {
      // 云端不可达：保持离线并尝试重连，不阻断 App；把异常记入 UI 诊断。
      _mqttConnected = false;
      final msg = e.toString();
      _lastConnError = '连接异常：$msg';
      // ignore: avoid_print
      print('[MQTT] connect error: $msg\n$st');
      _updateHeartbeat();
      _setConn(LinkState.disconnected);
      _scheduleReconnect();
    }
  }

  void _onMqttDisconnected() {
    _mqttConnected = false;
    _updateHeartbeat();
    final rc = _mqtt?.connectionStatus?.returnCode;
    final reason = rc != null ? ' (returnCode=$rc)' : '';
    // ignore: avoid_print
    print('[MQTT] disconnected$reason');
    if (_closing) {
      _setConn(LinkState.disconnected);
      return;
    }
    // 纯外网模式下 TCP 永远不通：MQTT 掉线即代表全链路断，广播 disconnected 让
    // UI 显示掉线横幅；局域网模式下 TCP 仍可能独立存活，不在这里覆盖 disconnected。
    if (!_tcpConnected && !_ctrl.isClosed) {
      _ctrl.add(const MachineStatus(state: MachineState.disconnected));
    }
    _lastConnError = 'MQTT 连接被断开$reason';
    _setConn(LinkState.disconnected);
    _scheduleReconnect();
  }

  /// 指数退避重连：2s → 4s → 8s → 16s → 封顶 30s
  void _scheduleReconnect() {
    if (_closing) return;
    _reconnectTimer?.cancel();
    final backoff = [2, 4, 8, 16, 30];
    final secs = backoff[_reconnectAttempts.clamp(0, backoff.length - 1)];
    _reconnectAttempts++;
    _reconnectTimer = Timer(Duration(seconds: secs), () {
      if (_conn != LinkState.connected && !_closing) _connectMqtt();
    });
  }

  void _setConn(LinkState s) {
    if (_conn == s) return;
    _conn = s;
    if (!_connCtrl.isClosed) _connCtrl.add(s);
  }

  void _onMqtt(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final ev in events) {
      final msg = ev.payload;
      if (msg is! MqttPublishMessage) continue;
      // mqtt_client 的 bytesToStringAsString 按 Latin1 解码，中文会乱码。
      // 协议文本是 UTF-8，所以必须显式用 utf8.decode。
      // allowMalformed：固件偶发半包/脏字节时不能让解码抛异常，
      // 否则异常会冒泡到 MQTT 回调里，打断整条订阅循环甚至导致掉线。
      final payload = utf8.decode(msg.payload.message, allowMalformed: true);
      // 遥测帧（QoS0 高频）：仅驱动 telemetryStream，不进 statusStream。
      if (ev.topic == mqttTelemetryTopic) {
        _handleTelemetry(payload);
        continue;
      }
      // docs/03 §6 系统级消息广播：弹横幅/通知，不进 statusStream。
      if (ev.topic == mqttBroadcastTopic) {
        _handleBroadcast(payload);
        continue;
      }
      // docs/03 §7 系统级事件广播（如 device_offline）：弹事件提示，不进 statusStream。
      if (ev.topic == mqttSystemTopic) {
        _handleSystem(payload);
        continue;
      }
      // V1.1（docs/03 §10.5）雕刻作业明细帧：emit 到 jobStream，不进 statusStream。
      if (ev.topic == mqttJobProgressTopic) {
        _handleJob(payload);
        continue;
      }
      // V1.1（docs/03 §10.6）机器系统帧：emit 到 sysStream，不进 statusStream。
      if (ev.topic == mqttSysInfoTopic) {
        _handleSys(payload);
        continue;
      }
      // 摄像头推流状态帧（cnc/<deviceId>/cam）：emit 到 cameraStream，不进 statusStream。
      // 注意：绝不能让摄像头帧流进 _parseAndEmit —— status 主题是机器状态专用，
      // 摄像头帧没有 state/pos，会被解析成 idle 从而误解锁 Jog（08-29 安全修复）。
      if (ev.topic == mqttCamStatusTopic) {
        _handleCam(payload);
        continue;
      }
      _parseAndEmit(payload);
    }
  }

  /// 判定是否为「摄像头状态帧」：带摄像头专属字段、且不含任何机器状态字段。
  /// 命中则直接丢弃，不交给 MachineStatus 解析（理由见 _parseAndEmit 注释）。
  static bool _isCameraStatusFrame(Map<String, dynamic> j) {
    const camMarkers = ['streaming', 'cam', 'camera', 'online'];
    const machineMarkers = ['state', 'pos', 'mpos', 'mp'];
    final hasCam = camMarkers.any(j.containsKey);
    if (!hasCam) return false;
    final hasMachine = machineMarkers.any(j.containsKey);
    return !hasMachine; // 同时带机器字段 → 视为合法机器帧，不拦
  }

  /// 遥测帧解析（R13）：高频 QoS0，仅 emit 到 telemetryStream；字段缺失安全回退 null。
  void _handleTelemetry(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      if (!_telemetryCtrl.isClosed) {
        _telemetryCtrl.add(Telemetry.fromJson(j));
      }
    } catch (_) {
      // 非预期遥测帧静默忽略
    }
  }

  /// docs/03 §6 系统级消息广播解析：emit 到 broadcastStream（UI 弹横幅/通知）。
  /// 2026-08-18：区分 `gcode_url` 型广播——不弹横幅，改走 notifyStream 做中性 toast。
  void _handleBroadcast(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final msg = BroadcastMessage.fromMsg(j);
      if (msg.isGcodeUrl) {
        // PC 端下发刀路 URL：屏幕会 HTTP 下载；App 仅提示用户，不弹横幅/不污染状态。
        if (!_notifyCtrl.isClosed) {
          _notifyCtrl.add(NotifyEvent(
            type: 'gcode_url',
            message: msg.body,
            at: DateTime.now(),
            isAlarm: false,
            data: {
              if (msg.url != null) 'url': msg.url,
              if (msg.fileName != null) 'file': msg.fileName,
              if (msg.size != null) 'size': msg.size,
              if (msg.checksum != null) 'checksum': msg.checksum,
              if (msg.jobId != null) 'jobId': msg.jobId,
            },
          ));
        }
        return;
      }
      if (!_broadcastCtrl.isClosed) {
        _broadcastCtrl.add(msg);
      }
    } catch (_) {
      // 非预期广播帧静默忽略
    }
  }

  /// docs/03 §7 系统级事件广播解析：emit 到 broadcastStream（UI 弹事件提示）。
  void _handleSystem(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      if (!_broadcastCtrl.isClosed) {
        _broadcastCtrl.add(BroadcastMessage.fromSystem(j));
      }
    } catch (_) {
      // 非预期事件帧静默忽略
    }
  }

  /// V1.1（docs/03 §10.5）雕刻作业明细帧解析：emit 到 jobStream。
  /// 字段缺失安全回退 null；脏数据静默忽略。
  void _handleJob(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      if (!_jobCtrl.isClosed) {
        _jobCtrl.add(JobProgress.fromJson(j));
      }
    } catch (_) {
      // 非预期作业帧静默忽略
    }
  }

  /// V1.1（docs/03 §10.6）机器系统帧解析：emit 到 sysStream（上电一次，retain）。
  /// 脏数据静默忽略。
  void _handleSys(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      if (!_sysCtrl.isClosed) {
        _sysCtrl.add(SysInfo.fromJson(j));
      }
    } catch (_) {
      // 非预期系统帧静默忽略
    }
  }

  /// 摄像头推流状态帧解析（docs/03 §camera-on-demand）：emit 到 cameraStream。
  /// 只认 `streaming` / `online` 两个字段；两者皆无的帧视为无效，直接丢弃，
  /// 避免把摄像头帧误当成机器状态帧（会导致 Jog 误解锁）。
  void _handleCam(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      final s = CameraStreamState.fromJson(j);
      if (s.isEmpty) return;
      if (!_camCtrl.isClosed) {
        _camCtrl.add(s);
      }
    } catch (_) {
      // 非预期摄像头帧静默忽略
    }
  }

  Future<void> _connectTcp() async {
    try {
      _tcp = await Socket.connect(_tcpHost, tcpPort,
          timeout: const Duration(seconds: 3));
      _tcpConnected = true;
      _setConn(LinkState.connected); // 第一步唯一通道，TCP 通即"已连"
      _updateHeartbeat();
      _tcp!.listen((data) {
        // TCP 是字节流，粘包/半包都会出现，allowMalformed 防止解码抛异常打断 listen。
        final text = utf8.decode(data, allowMalformed: true);
        for (final line in text.split('\n')) {
          final t = line.trim();
          if (t.isNotEmpty) _parseAndEmit(t);
        }
      }, onDone: () {
        _tcpConnected = false;
        if (!cloudEnabled) _setConn(LinkState.disconnected);
        _updateHeartbeat();
        _scheduleTcpReconnect();
      }, onError: (_) {
        _tcpConnected = false;
        if (!cloudEnabled) _setConn(LinkState.disconnected);
        _updateHeartbeat();
        _scheduleTcpReconnect();
      });
    } catch (_) {
      _tcpConnected = false;
      _updateHeartbeat();
      _scheduleTcpReconnect();
    }
  }

  /// 局域网 TCP 通道：掉线后每 5s 重试，直到连上或 dispose。
  void _scheduleTcpReconnect() {
    _tcpReconnectTimer?.cancel();
    _tcpReconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!_tcpConnected) _connectTcp();
    });
  }

  void _parseAndEmit(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map<String, dynamic>) return;

      // 摄像头状态帧防护（2026-08-29）：
      // docs/32 §4.4 提议摄像头把 online/streaming 发到 cnc/<deviceId>/status。
      // 但 MachineStatus.fromJson 对陌生字段一律回落成「idle + 坐标 0 + 进度 0 +
      // awaitingConfirm=false」，一旦摄像头往 status 主题发帧，就会把
      // 「加工中」刷成「待机」、把报警态清掉、把机旁确认横幅抹掉，
      // 进而**解锁已锁定的 Jog**——这是安全漏洞，必须先拦。
      // 约定：摄像头状态请发专用主题 cnc/<deviceId>/cam，不要占用 status。
      if (_isCameraStatusFrame(j)) return;

      // notify 事件：固件通过 cnc/<deviceId>/notify 广播的异步事件
      // （job_done / alarm / error / tool_changed / confirm_required 等）。
      // 同时驱动两条流：
      //  - notifyStream → 一次性提示（toast + 横幅），不随状态帧反复冲刷；
      //  - statusStream → 维持既有状态联动（awaitingConfirm / job_done / alarm）。
      if (j.containsKey('type')) {
        final type = j['type']?.toString() ?? '';
        final msg = j['msg']?.toString() ?? '';
        MachineStatus notifyStatus;
        switch (type) {
          case 'job_done':
            notifyStatus = const MachineStatus(
              state: MachineState.idle,
              progress: 1.0,
              message: '加工完成',
            );
          case 'alarm':
          case 'error':
            notifyStatus = MachineStatus(
              state: MachineState.alarm,
              message: msg.isEmpty ? type : msg,
            );
          case 'confirm_required':
            notifyStatus = const MachineStatus(
              state: MachineState.busy,
              awaitingConfirm: true,
              message: '等待机旁确认',
            );
          case 'confirm_timeout':
            // 雕刻启动两段式（2026-09-02）：客户未在机器上按物理键，机器已取消
            // 本次启动。固件后补该事件，**收到才显示**，老固件无此事件即无此提示。
            // 状态回到 idle（机器确实取消了），并把待处理命令标记为已送达 ——
            // 命令送到了、机器明确回应"不执行"，绝不能再重发。
            notifyStatus = MachineStatus(
              state: MachineState.idle,
              message: msg.isEmpty ? '确认超时已取消' : msg,
            );
            _settlePendingAcked();
          default:
            notifyStatus = MachineStatus(message: msg.isEmpty ? type : msg);
        }
        // 先发一次性事件（toast/横幅），再发状态联动（保留原行为）
        if (!_notifyCtrl.isClosed) {
          final data = j['data'];
          _notifyCtrl.add(NotifyEvent(
            type: type,
            message: msg.isEmpty ? type : msg,
            at: DateTime.now(),
            code: j['code']?.toString(),
            data: data is Map<String, dynamic> ? data : null,
            ts: (j['ts'] is num) ? (j['ts'] as num).toInt() : null,
          ));
        }
        _checkCmdAck(notifyStatus);
        _ctrl.add(notifyStatus);
        return;
      }

      final parsed = MachineStatus.fromJson(j);
      _checkCmdAck(parsed);
      _ctrl.add(parsed);
    } catch (_) {
      // 非 JSON 行（如 Grbl 原始 <...>）可在此扩展解析
    }
  }

  /// 发布一条命令到 cnc/<deviceId>/cmd。返回是否真的发出去了。
  ///
  /// 终局方案（2026-08-28）：不再区分内外网权限，命令一律经外网 MQTT 发布到
  /// cnc/<deviceId>/cmd（原网关 gw/<deviceId>/cmd 与 wan_whitelist 已废弃）。
  ///
  /// 2026-09-02：改为返回 bool，**不再静默丢弃**（原来直接 `return`）。
  /// 未连上时由 [_dispatch] 决定是否入队补发。
  bool _publish(Map<String, dynamic> cmd) {
    if (_mqtt?.connectionStatus?.state != MqttConnectionState.connected) {
      return false;
    }
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode(cmd));
    _mqtt!.publishMessage(mqttCmdTopic, MqttQos.atLeastOnce, builder.payload!);
    return true;
  }

  /// 命令分发：终局方案下不再区分内外网，**一律经外网 MQTT 下发**到
  /// cnc/<deviceId>/cmd。局域网 TCP 直连代码保留但暂不启用（"暂时停止"），
  /// 后续若要恢复低延迟本地控制，在此处加回 TCP 分支即可。
  ///
  /// 2026-09-02：雕刻启动两段式 —— 关键命令（开始/暂停/继续/停止雕刻）走
  /// [_dispatchCritical] 做送达跟踪与超时重发；其余命令（Jog/主轴/辅助等）
  /// 保持"尽力而为"语义，**绝不重发**（重发运动指令会造成意外位移）。
  void _dispatch(Map<String, dynamic> cmd) {
    final label = _criticalLabelOf(cmd);
    if (label != null) {
      _dispatchCritical(cmd, label);
      return;
    }
    _publish(cmd);
  }

  /// 若 [cmd] 属于「关键命令」，返回其中文名；否则返回 null。
  ///
  /// 🔴 只有**幂等且不涉及运动**的作业控制命令才纳入重发。Jog / 回零 /
  /// 设原点等运动指令一律不重发 —— 一次误重发就是一次意外位移。
  String? _criticalLabelOf(Map<String, dynamic> cmd) {
    if (cmd['cmd'] != 'job') return null;
    switch (cmd['action']) {
      case 'start':
        return '开始雕刻';
      case 'pause':
        return '暂停雕刻';
      case 'resume':
        return '继续雕刻';
      case 'stop':
        return '停止雕刻';
      default:
        return null;
    }
  }

  /// 两条命令是否同类（用于同类命令只保留最后一条，避免排队重发一串旧指令）。
  bool _sameCommandKind(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['cmd'] == b['cmd'] && a['action'] == b['action'];

  /// 下发关键命令并启动送达跟踪。
  void _dispatchCritical(Map<String, dynamic> cmd, String label) {
    // 同类旧命令作废：用户连点两次「开始」，只跟踪最后一次，避免补发两次。
    _cmdQueue.removeWhere((p) => _sameCommandKind(p.cmd, cmd));

    final sent = PendingCommand(
      cmd: cmd,
      label: label,
      state: CommandDeliveryState.sent,
    );
    if (!_publish(cmd)) {
      // 链路未通：入队，等重连后补发。
      _pending = sent.copyWith(state: CommandDeliveryState.queued);
      _cmdQueue.add(_pending!);
      _ackTimer?.cancel();
      _emitCmd(CommandDeliveryState.queued);
      return;
    }
    _pending = sent;
    _emitCmd(CommandDeliveryState.sent);
    _startAckTimer();
  }

  void _startAckTimer() {
    _ackTimer?.cancel();
    _ackTimer = Timer(_ackTimeout, _onAckTimeout);
  }

  /// 回执超时：重发一次（仍失败则继续排队），次数耗尽判 failed。
  void _onAckTimeout() {
    final p = _pending;
    if (p == null || _closing) return;
    if (p.retries >= _maxCmdRetries) {
      _pending = p.copyWith(state: CommandDeliveryState.failed);
      _ackTimer?.cancel();
      _ackTimer = null;
      _emitCmd(CommandDeliveryState.failed);
      return;
    }
    final next =
        p.copyWith(state: CommandDeliveryState.retrying, retries: p.retries + 1);
    _pending = next;
    _emitCmd(CommandDeliveryState.retrying);
    if (!_publish(next.cmd)) {
      // 重发瞬间链路又断了 → 入队等补发，不再起定时器。
      _cmdQueue.add(next);
      _ackTimer?.cancel();
      _ackTimer = null;
      return;
    }
    _startAckTimer();
  }

  /// 链路恢复后补发排队命令。
  void _flushCmdQueue() {
    if (_cmdQueue.isEmpty) return;
    final queued = List<PendingCommand>.from(_cmdQueue);
    _cmdQueue.clear();
    for (final p in queued) {
      if (_publish(p.cmd)) {
        _pending = p.copyWith(state: CommandDeliveryState.sent);
        _emitCmd(CommandDeliveryState.sent);
        _startAckTimer();
      } else {
        _cmdQueue.add(p); // 仍未通，继续排
      }
    }
  }

  /// 判定待处理命令为「已送达」并停止重发。
  ///
  /// 用于机器已明确回应（如 `confirm_timeout` 取消启动）的场景：命令确实送到
  /// 了，只是机器决定不执行。此时**绝不能重发** —— 重发等于绕过客户取消。
  void _settlePendingAcked() {
    final p = _pending;
    if (p == null) return;
    if (p.state == CommandDeliveryState.acked ||
        p.state == CommandDeliveryState.failed) return;
    _pending = p.copyWith(state: CommandDeliveryState.acked);
    _ackTimer?.cancel();
    _ackTimer = null;
    _emitCmd(CommandDeliveryState.acked);
  }

  /// 收到机器帧时调用：若达到该命令的期待状态即判定「已送达」。
  void _checkCmdAck(MachineStatus s) {
    final p = _pending;
    if (p == null) return;
    if (p.state == CommandDeliveryState.acked ||
        p.state == CommandDeliveryState.failed) return;
    if (!_isAckStateFor(p.cmd, s)) return;
    _pending = p.copyWith(state: CommandDeliveryState.acked);
    _ackTimer?.cancel();
    _ackTimer = null;
    _emitCmd(CommandDeliveryState.acked);
  }

  /// [cmd] 的期待到达状态。收到这些状态即认为机器已收到并执行了该命令。
  ///
  /// 兼容老固件：老固件 `awaitingConfirm` 恒 false、收到 start 后直接 `busy`，
  /// 命中 `s.state == MachineState.busy` 分支照样 acked，无需改固件。
  /// `alarm` 也算送达 —— 命令到了，只是机器拒绝执行（UI 另行提示报警）。
  bool _isAckStateFor(Map<String, dynamic> cmd, MachineStatus s) {
    if (cmd['cmd'] != 'job') return true;
    switch (cmd['action']) {
      case 'start':
        return s.awaitingConfirm ||
            s.state == MachineState.busy ||
            s.state == MachineState.alarm;
      case 'pause':
        return s.state == MachineState.paused || s.state == MachineState.alarm;
      case 'resume':
        return s.state == MachineState.busy || s.state == MachineState.alarm;
      case 'stop':
        return s.state == MachineState.idle || s.state == MachineState.alarm;
      default:
        return true;
    }
  }

  void _emitCmd(CommandDeliveryState s) {
    if (!_cmdCtrl.isClosed) _cmdCtrl.add(s);
  }

  /// 局域网 TCP 直连下发。**终局方案下暂不启用**（命令一律走外网 MQTT），
  /// 代码保留以备后续恢复低延迟本地控制；恢复时只需在 [_dispatch] 加回分支。
  void _sendTcp(Map<String, dynamic> cmd) {
    if (_tcpConnected && _tcp != null) {
      _tcp!.write('${jsonEncode(cmd)}\n');
    }
  }

  /// 摄像头按需推流控制（docs/03 §camera-on-demand）：
  /// 点播放发 `stream_start`、退出预览发 `stream_stop`。
  /// 摄像头为纯外网设备，命令只走 MQTT（cnc/<deviceId>/cmd），
  /// 不依赖 cloudEnabled 局域网闸门；MQTT 未连时静默跳过（由调用方在连接态补发）。
  @override
  void sendCameraStream(String action, {String? deviceId}) {
    final id = deviceId ?? this.deviceId;
    if (_mqtt?.connectionStatus?.state != MqttConnectionState.connected) return;
    final builder = MqttClientPayloadBuilder();
    builder.addString(jsonEncode({'action': action}));
    _mqtt!.publishMessage(
        mqttCamCmdTopic(id), MqttQos.atLeastOnce, builder.payload!);
  }

  // ---- 心跳：固件 15s 内收不到任何命令即进入 Feed Hold，App 须周期发 hello ----
  /// 终局方案：局域网 TCP 停用后，心跳改由 **MQTT 连接**驱动，经命令主题
  /// cnc/<deviceId>/cmd 下发 {"cmd":"hello"}（网关白名单已废弃，不会再被 E401 拒绝）。
  /// 目的：用户长时间只看画面、不下发任何命令时，也能持续重置机器主控的
  /// 15s Feed Hold 定时器，避免加工被误暂停。
  void _updateHeartbeat() {
    if (_mqttConnected) {
      _startHeartbeat();
    } else {
      _stopHeartbeat();
    }
  }

  void _startHeartbeat() {
    if (_heartbeatTimer?.isActive == true) return;
    _sendHello(); // 立即先发一帧，随后周期发送
    _heartbeatTimer =
        Timer.periodic(_heartbeatInterval, (_) => _sendHello());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 心跳帧：经 MQTT 命令主题下发（原先走局域网 TCP）。
  /// 注意：机器码与摄像头码统一后，该帧也会被摄像头收到；摄像头固件须忽略
  /// payload 中非 stream_start / stream_stop 的帧。
  void _sendHello() {
    _publish({'cmd': 'hello'});
  }

  @override
  Future<void> disconnect() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _tcpReconnectTimer?.cancel();
    _stopHeartbeat();
    _tcp?.destroy();
    _tcp = null;
    _tcpConnected = false;
    _mqttConnected = false;
    _mqtt?.disconnect();
    _mqtt = null;
    _setConn(LinkState.disconnected);
  }

  @override
  Future<MachineStatus> getStatus() async =>
      const MachineStatus(state: MachineState.disconnected);

  @override
  Future<({double widthMm, double heightMm})> getWorkArea() async {
    // Smart 3020 默认台面；真实值可由固件在状态帧携带后覆盖。
    return (widthMm: 300.0, heightMm: 200.0);
  }

  @override
  Future<void> jog(String axis, double distanceMm) async {
    final cmd = {'cmd': 'jog', 'axis': axis, 'dist': distanceMm};
    _dispatch(cmd);
  }

  @override
  Future<void> home() async {
    final cmd = {'cmd': 'home'};
    _dispatch(cmd);
  }

  @override
  Future<void> softReset() async {
    // {"cmd":"reset"} —— 固件侧等价 Grbl Ctrl-X(0x18)：中止运动 + 清空规划器缓冲。
    final cmd = {'cmd': 'reset'};
    _dispatch(cmd);
  }

  @override
  Future<void> unlock() async {
    // {"cmd":"unlock"} —— 固件侧等价 Grbl `$X`：只清 Alarm/Lock 位。
    // 不回零、不移动；解锁后坐标不可信，必须重新定原点。
    final cmd = {'cmd': 'unlock'};
    _dispatch(cmd);
  }

  @override
  Future<void> setWorkZero({double x = 0, double y = 0, double z = 0}) async {
    final cmd = {'cmd': 'setWorkZero', 'x': x, 'y': y, 'z': z};
    _dispatch(cmd);
  }

  @override
  Future<void> startSpindle(double rpm) async {
    final cmd = {'cmd': 'spindle', 'rpm': rpm};
    _dispatch(cmd);
  }

  @override
  Future<void> stopSpindle() async {
    final cmd = {'cmd': 'spindle', 'rpm': 0};
    _dispatch(cmd);
  }

  @override
  Future<void> setAux(String key, bool on) async {
    _aux[key] = on;
    final cmd = {'cmd': 'aux', 'key': key, 'on': on};
    _dispatch(cmd);
  }

  @override
  Future<void> startJob() async {
    final cmd = {'cmd': 'job', 'action': 'start'};
    _dispatch(cmd);
  }

  @override
  Future<void> pauseJob() async {
    final cmd = {'cmd': 'job', 'action': 'pause'};
    _dispatch(cmd);
  }

  @override
  Future<void> resumeJob() async {
    final cmd = {'cmd': 'job', 'action': 'resume'};
    _dispatch(cmd);
  }

  @override
  Future<void> stopJob() async {
    final cmd = {'cmd': 'job', 'action': 'stop'};
    _dispatch(cmd);
  }

  @override
  Future<void> updateToolMap(List<Tool> tools) async {
    final cmd = {
      'cmd': 'toolMap',
      'tools': tools
          .map((t) => {
                'index': t.index,
                'installed': t.installed,
              })
          .toList(),
    };
    _dispatch(cmd);
  }

  @override
  Future<void> setLevelingPlan(
      {required int mode, required int cols, required int rows}) async {
    final cmd = {
      'cmd': 'leveling',
      'mode': mode,
      'cols': cols,
      'rows': rows,
    };
    _dispatch(cmd);
  }

  bool getAux(String key) => _aux[key] ?? false;

  void dispose() {
    // 🔴 关键修复（2026-08-31）：必须先置 _closing = true，再断开。
    // 原实现直接 _mqtt?.disconnect()（与 disconnect() 方法不同，未置 _closing），
    // 导致断开回调 _onMqttDisconnected() 认为"非主动关闭"，进而调用
    // _scheduleReconnect() 给**已销毁的实例**排一个重连定时器。
    // 旧实例重连时用的 clientId 仍是 android-<deviceId>，与新实例同名
    // → broker 侧互踢 → 新实例被踢 → 又触发重连 → 无限循环，
    // 表现为"MQTT 一下连上、一下断开"的反复闪断（切换/选中机器时必现，
    // 因为硬件服务会随 currentMachineProvider 重建）。
    _closing = true;
    _reconnectTimer?.cancel();
    _tcpReconnectTimer?.cancel();
    _ackTimer?.cancel();
    _ackTimer = null;
    _cmdQueue.clear();
    _pending = null;
    _stopHeartbeat();
    _tcp?.destroy();
    _mqtt?.disconnect();
    _ctrl.close();
    _notifyCtrl.close();
    _telemetryCtrl.close();
    _broadcastCtrl.close();
    _jobCtrl.close();
    _sysCtrl.close();
    _camCtrl.close();
    _connCtrl.close();
    _cmdCtrl.close();
  }
}

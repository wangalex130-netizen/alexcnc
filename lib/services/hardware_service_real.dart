import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../app/config.dart';
import '../models/broadcast_message.dart';
import '../models/machine_status.dart';
import '../models/notify_event.dart';
import '../models/position.dart';
import '../models/telemetry.dart';
import '../models/tool.dart';
import 'device_discovery.dart';
import 'hardware_service.dart';

/// 真实硬件实现。
///
/// **第一步（局域网，默认）**：以 [tcpHost]:[tcpPort]（默认 8899）为**唯一控制 +
/// 状态通道**，App 直连机器（ESP32 TCP Server）。详见 `docs/PROTOCOL.md` Step1。
///
/// **第二步（外网，[cloudEnabled]=true 时启用）**：额外连接云端 MQTT Broker，状态/
/// 事件订阅 cnc/<deviceId>/status、cnc/<deviceId>/notify；命令经网关白名单转发
/// gw/<deviceId>/cmd（R2），网关回执订阅 gw/<deviceId>/ack。帧格式与 TCP 完全一致，
/// 仅传输层不同。
///
/// 两条链路汇入同一 [statusStream]，App 其余代码无需区分来源。离线/未连时静默
/// 不报错，UI 仅显示为 disconnected。连接态以 TCP 为准（第一步唯一通道）。
class RealHardwareService implements HardwareService {
  final String broker;
  final int mqttPort;
  final String mqttUser;
  final String mqttPass;
  final String deviceId;
  final int tcpPort;
  /// 第二步外网开关；第一步（LAN）保持 false，MQTT 链路不启用。
  final bool cloudEnabled;
  /// App 登录身份（契约 auth.client_id_pattern = app-<userId>），用作 MQTT clientId。
  final String appUserId;

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
    this.appUserId = AppConfig.appUserId,
  }) : _tcpHost = tcpHost;

  /// MQTT 状态广播主题：cnc/<deviceId>/status（按实例 deviceId 推导，App 订阅）
  String get mqttStatusTopic => 'cnc/$deviceId/status';

  /// MQTT 命令下发主题：gw/<deviceId>/cmd（经网关白名单转发固件；ACL 已放行 app-demo 发布）
  String get mqttCmdTopic => 'gw/$deviceId/cmd';

  /// 网关 ACK 回执主题：gw/<deviceId>/ack（App 订阅，网关对命令的回执）
  String get mqttAckTopic => 'gw/$deviceId/ack';

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

  /// 连接态流：connecting / connected / disconnected，UI 订阅以显示链路状态。
  Stream<LinkState> get connectionState => _connCtrl.stream;
  LinkState get currentLinkState => _conn;

  /// 最近一次连接失败的错误信息，供 UI 诊断用。
  @override
  String? get lastConnectionError => _lastConnError;

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
      // 第二步外网：仅连云端 MQTT 主链路，不再自动连局域网 TCP。
      // 避免命令被 TCP 通道"吃掉"而云端网关收不到（doc 25 诊断结论）。
      // 命令一律经网关 gw/<deviceId>/cmd 下发。
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
      // clientId 固定为 app-<userId>（契约 auth.client_id_pattern），便于 Broker 侧
      // ACL 按账号维度鉴权与上下线追踪；同一账号重连保持同一身份。
      final client = MqttServerClient(broker, 'app-$appUserId');
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
        client.subscribe(mqttAckTopic, MqttQos.atLeastOnce); // 网关命令回执
        // docs/03 §6/§7 系统级广播（全局主题，任意设备发起的事件/消息）
        client.subscribe(mqttBroadcastTopic, MqttQos.atLeastOnce);
        client.subscribe(mqttSystemTopic, MqttQos.atLeastOnce);
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
    if (_closing) {
      _setConn(LinkState.disconnected);
      return;
    }
    // 纯外网模式下 TCP 永远不通：MQTT 掉线即代表全链路断，广播 disconnected 让
    // UI 显示掉线横幅；局域网模式下 TCP 仍可能独立存活，不在这里覆盖 disconnected。
    if (!_tcpConnected && !_ctrl.isClosed) {
      _ctrl.add(const MachineStatus(state: MachineState.disconnected));
    }
    _lastConnError ??= 'MQTT 连接被断开';
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
      final payload =
          MqttPublishPayload.bytesToStringAsString(msg.payload.message);
      // 网关 ACK 回执：白名单拒绝时回 {ok:false,code:E401,msg}，需弹通知；放行命令无 ack。
      if (ev.topic == mqttAckTopic) {
        _handleGwAck(payload);
        continue;
      }
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
      _parseAndEmit(payload);
    }
  }

  /// 网关命令回执处理（R2）：仅当 ok=false 且 code=E401（白名单外命令被拒）时弹一次
  /// 通知，提示用户当前网络模式不支持该操作；放行命令不回 ack，不弹通知。
  void _handleGwAck(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      if (j['ok'] == true) return; // 放行/无回执：不打扰
      final code = j['code']?.toString() ?? '';
      final msg = j['msg']?.toString() ?? '';
      if (code == 'E401') {
        if (!_notifyCtrl.isClosed) {
          _notifyCtrl.add(NotifyEvent(
            type: 'gw_rejected',
            message: msg.isEmpty ? '远程操作被拒绝（需局域网直连）' : msg,
            at: DateTime.now(),
            isAlarm: true,
          ));
        }
      }
    } catch (_) {
      // ACK 帧非预期格式时静默忽略
    }
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
  void _handleBroadcast(String payload) {
    try {
      final j = jsonDecode(payload) as Map<String, dynamic>;
      if (!_broadcastCtrl.isClosed) {
        _broadcastCtrl.add(BroadcastMessage.fromMsg(j));
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

  Future<void> _connectTcp() async {
    try {
      _tcp = await Socket.connect(_tcpHost, tcpPort,
          timeout: const Duration(seconds: 3));
      _tcpConnected = true;
      _setConn(LinkState.connected); // 第一步唯一通道，TCP 通即"已连"
      _updateHeartbeat();
      _tcp!.listen((data) {
        final text = utf8.decode(data);
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
          default:
            notifyStatus = MachineStatus(message: msg.isEmpty ? type : msg);
        }
        // 先发一次性事件（toast/横幅），再发状态联动（保留原行为）
        if (!_notifyCtrl.isClosed) {
          _notifyCtrl.add(NotifyEvent(
            type: type,
            message: msg.isEmpty ? type : msg,
            at: DateTime.now(),
          ));
        }
        _ctrl.add(notifyStatus);
        return;
      }

      _ctrl.add(MachineStatus.fromJson(j));
    } catch (_) {
      // 非 JSON 行（如 Grbl 原始 <...>）可在此扩展解析
    }
  }

  void _publish(Map<String, dynamic> cmd) {
    // R3：云端模式下命令一律经网关下发（cloudEnabled 已隐含非局域网、无 TCP 直连）。
    //   不再以 _tcpConnected 为闸门，避免命令被局域网 TCP 吃掉而云端收不到（doc 25）。
    if (!cloudEnabled) return;
    final json = jsonEncode(cmd);
    if (_mqtt?.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString(json);
      _mqtt!.publishMessage(
          mqttCmdTopic, MqttQos.atLeastOnce, builder.payload!);
    }
  }

  /// 命令分发：
  ///  - 云端模式（cloudEnabled）：一律经云端 MQTT 网关下发（R2/R3），不依赖局域网 TCP。
  ///  - 局域网模式：经 TCP 直连下发（低延迟，hello 心跳也走 TCP）。
  void _dispatch(Map<String, dynamic> cmd) {
    if (cloudEnabled) {
      _publish(cmd);
    } else if (_tcpConnected) {
      _sendTcp(cmd);
    }
  }

  void _sendTcp(Map<String, dynamic> cmd) {
    if (_tcpConnected && _tcp != null) {
      _tcp!.write('${jsonEncode(cmd)}\n');
    }
  }

  // ---- 心跳：固件 15s 内收不到任何命令即进入 Feed Hold，App 须周期发 hello ----
  /// R3：心跳仅由局域网 TCP 存活驱动。外网模式下 _tcpConnected 为 false，不跑 hello，
  /// 固件存活由 MQTT keepAlive(30s) 维持，App 不额外发空帧污染网关。
  void _updateHeartbeat() {
    if (_tcpConnected) {
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

  /// 心跳帧：R3 改为**仅走局域网 TCP**。hello 不在网关白名单内，若经 gw 下发会被
  /// 网关拒绝（E401）并刷错误日志；外网模式下固件存活靠 MQTT keepAlive(30s)，无需空心跳。
  void _sendHello() {
    final cmd = {'cmd': 'hello'};
    _sendTcp(cmd); // 局域网低延迟通道；未连 TCP 时静默不发（外网由 keepAlive 保活）
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
    _reconnectTimer?.cancel();
    _tcpReconnectTimer?.cancel();
    _stopHeartbeat();
    _tcp?.destroy();
    _mqtt?.disconnect();
    _ctrl.close();
    _notifyCtrl.close();
    _telemetryCtrl.close();
    _broadcastCtrl.close();
    _connCtrl.close();
  }
}

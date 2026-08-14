import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../app/config.dart';
import '../models/machine_status.dart';
import '../models/position.dart';
import '../models/tool.dart';
import 'device_discovery.dart';
import 'hardware_service.dart';

/// 链路连接态：UI 据此显示「连接中 / 已连 / 掉线」，不影响功能逻辑。
enum ConnectionState { disconnected, connecting, connected }

/// 真实硬件实现。
///
/// **第一步（局域网，默认）**：以 [tcpHost]:[tcpPort]（默认 8899）为**唯一控制 +
/// 状态通道**，App 直连机器（ESP32 TCP Server）。详见 `docs/PROTOCOL.md` Step1。
///
/// **第二步（外网，[cloudEnabled]=true 时启用）**：额外连接云端 MQTT Broker，命令/
/// 状态改走主题 cnc/<deviceId>/cmd、cnc/<deviceId>/status；帧格式与 TCP 完全一致，
/// 仅传输层不同，无需重写命令逻辑。
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
  MqttServerClient? _mqtt;
  Socket? _tcp;
  bool _tcpConnected = false;

  // ---- 连接态（重连 + UI 展示，不改变功能逻辑）----
  ConnectionState _conn = ConnectionState.disconnected;
  final _connCtrl = StreamController<ConnectionState>.broadcast();
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

  /// MQTT 状态广播主题：cnc/<deviceId>/status（按实例 deviceId 推导）
  String get mqttStatusTopic => 'cnc/$deviceId/status';

  /// MQTT 命令下发主题：cnc/<deviceId>/cmd
  String get mqttCmdTopic => 'cnc/$deviceId/cmd';

  /// MQTT 事件通知主题：cnc/<deviceId>/notify（job_done / alarm / confirm_required 等）
  String get mqttNotifyTopic => 'cnc/$deviceId/notify';

  @override
  Stream<MachineStatus> get statusStream => _ctrl.stream;

  /// 连接态流：connecting / connected / disconnected，UI 订阅以显示链路状态。
  Stream<ConnectionState> get connectionState => _connCtrl.stream;
  ConnectionState get currentConnectionState => _conn;

  @override
  Future<void> connect() async {
    if (cloudEnabled) await _connectMqtt();
    // 与机器同 Wi-Fi 且用户未手动指定 TCP 主机时，先用 UDP beacon 自动发现真机 IP，
    // 否则走已配置/兜底地址。WAN 模式（cloudEnabled）下 MQTT 已先行连接。
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
    if (_conn == ConnectionState.connected) return;
    _setConn(ConnectionState.connecting);
    try {
      // 每次重连都新建 client，避免复用已断开实例的脏状态。
      // clientId 固定为 app-<userId>（契约 auth.client_id_pattern），便于 Broker 侧
      // ACL 按账号维度鉴权与上下线追踪；同一账号重连保持同一身份。
      final client = MqttServerClient(broker, 'app-$appUserId');
      client.port = mqttPort;
      client.secure = true;                          // 启用 TLS（8883）
      client.onBadCertificate = (cert) => true;      // 信任自签证书，仅联调期；上线换正式 CA 后删除此行
      client.keepAlivePeriod = 30;
      client.logging(on: false);
      client.onDisconnected = _onMqttDisconnected;
      await client.connect(
        mqttUser.isEmpty ? null : mqttUser,
        mqttPass.isEmpty ? null : mqttPass,
      );
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _mqtt = client;
        _mqttConnected = true;
        client.subscribe(mqttStatusTopic, MqttQos.atLeastOnce);
        client.subscribe(mqttNotifyTopic, MqttQos.atLeastOnce);
        client.updates!.listen(_onMqtt);
        _reconnectAttempts = 0;
        _setConn(ConnectionState.connected);
        _updateHeartbeat();
      } else {
        _mqttConnected = false;
        _setConn(ConnectionState.disconnected);
        _scheduleReconnect();
      }
    } catch (_) {
      // 云端不可达：保持离线并尝试重连，不阻断 App
      _mqttConnected = false;
      _updateHeartbeat();
      _setConn(ConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void _onMqttDisconnected() {
    _mqttConnected = false;
    _updateHeartbeat();
    if (_closing) {
      _setConn(ConnectionState.disconnected);
      return;
    }
    _setConn(ConnectionState.disconnected);
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
      if (_conn != ConnectionState.connected && !_closing) _connectMqtt();
    });
  }

  void _setConn(ConnectionState s) {
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
      _parseAndEmit(payload);
    }
  }

  Future<void> _connectTcp() async {
    try {
      _tcp = await Socket.connect(_tcpHost, tcpPort,
          timeout: const Duration(seconds: 3));
      _tcpConnected = true;
      _setConn(ConnectionState.connected); // 第一步唯一通道，TCP 通即"已连"
      _updateHeartbeat();
      _tcp!.listen((data) {
        final text = utf8.decode(data);
        for (final line in text.split('\n')) {
          final t = line.trim();
          if (t.isNotEmpty) _parseAndEmit(t);
        }
      }, onDone: () {
        _tcpConnected = false;
        if (!cloudEnabled) _setConn(ConnectionState.disconnected);
        _updateHeartbeat();
        _scheduleTcpReconnect();
      }, onError: (_) {
        _tcpConnected = false;
        if (!cloudEnabled) _setConn(ConnectionState.disconnected);
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
      // App 目前没有独立 notify 流，将其映射为 MachineStatus 以便 UI 统一消费。
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
        _ctrl.add(notifyStatus);
        return;
      }

      _ctrl.add(MachineStatus.fromJson(j));
    } catch (_) {
      // 非 JSON 行（如 Grbl 原始 <...>）可在此扩展解析
    }
  }

  void _publish(Map<String, dynamic> cmd) {
    if (!cloudEnabled) return; // 第一步（LAN）不启用 MQTT
    final json = jsonEncode(cmd);
    // 第二步主链路：MQTT 命令
    if (_mqtt?.connectionStatus?.state == MqttConnectionState.connected) {
      final builder = MqttClientPayloadBuilder();
      builder.addString(json);
      _mqtt!.publishMessage(
          mqttCmdTopic, MqttQos.atLeastOnce, builder.payload!);
    }
  }

  void _sendTcp(Map<String, dynamic> cmd) {
    if (_tcpConnected && _tcp != null) {
      _tcp!.write('${jsonEncode(cmd)}\n');
    }
  }

  // ---- 心跳：固件 15s 内收不到任何命令即进入 Feed Hold，App 须周期发 hello ----
  /// 任一条链路（LAN TCP / WAN MQTT）存活即保持心跳，全部断开则停。
  void _updateHeartbeat() {
    final up = _tcpConnected || (_mqttConnected && cloudEnabled);
    if (up) {
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

  /// 心跳帧：同时覆盖 LAN（TCP）与外网（MQTT）两条链路。
  /// cloudEnabled=false 时 _publish 内部直接返回，不会误发 WAN 帧。
  void _sendHello() {
    final cmd = {'cmd': 'hello'};
    _sendTcp(cmd); // 局域网低延迟通道
    _publish(cmd); // 外网链路（仅 cloudEnabled 时 _publish 才会真正下发）
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
    _setConn(ConnectionState.disconnected);
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
    _sendTcp(cmd); // LAN 低延迟优先
    _publish(cmd); // 同时经云端兜底
  }

  @override
  Future<void> home() async {
    final cmd = {'cmd': 'home'};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> setWorkZero({double x = 0, double y = 0, double z = 0}) async {
    final cmd = {'cmd': 'setWorkZero', 'x': x, 'y': y, 'z': z};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> startSpindle(double rpm) async {
    final cmd = {'cmd': 'spindle', 'rpm': rpm};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> stopSpindle() async {
    final cmd = {'cmd': 'spindle', 'rpm': 0};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> setAux(String key, bool on) async {
    _aux[key] = on;
    final cmd = {'cmd': 'aux', 'key': key, 'on': on};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> startJob() async {
    final cmd = {'cmd': 'job', 'action': 'start'};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> pauseJob() async {
    final cmd = {'cmd': 'job', 'action': 'pause'};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> resumeJob() async {
    final cmd = {'cmd': 'job', 'action': 'resume'};
    _sendTcp(cmd);
    _publish(cmd);
  }

  @override
  Future<void> stopJob() async {
    final cmd = {'cmd': 'job', 'action': 'stop'};
    _sendTcp(cmd);
    _publish(cmd);
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
    _sendTcp(cmd);
    _publish(cmd);
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
    _sendTcp(cmd);
    _publish(cmd);
  }

  bool getAux(String key) => _aux[key] ?? false;

  void dispose() {
    _reconnectTimer?.cancel();
    _tcpReconnectTimer?.cancel();
    _stopHeartbeat();
    _tcp?.destroy();
    _mqtt?.disconnect();
    _ctrl.close();
    _connCtrl.close();
  }
}

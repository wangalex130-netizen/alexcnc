import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../app/config.dart';
import '../models/machine_status.dart';
import '../models/position.dart';
import '../models/tool.dart';
import 'hardware_service.dart';

/// 链路连接态：UI 据此显示「连接中 / 已连 / 掉线」，不影响功能逻辑。
enum ConnectionState { disconnected, connecting, connected }

/// 真实硬件实现：云端 MQTT（主链路：状态订阅 + 全命令下发）+ 局域网 TCP（低延迟
/// 运动控制 jog/home/定原点）。
///
/// 协议细节见 `docs/PROTOCOL.md`：
/// - 状态广播 topic：cnc/<deviceId>/status（JSON → MachineStatus.fromJson）
/// - 命令下发 topic：cnc/<deviceId>/cmd（JSON 命令帧）
/// - LAN TCP 8899：局域网内把运动命令直发设备，降低 jog 抖动
///
/// 两条链路汇入同一 [statusStream]，App 其余代码无需区分来源。离线/未连时静默
/// 不报错，UI 仅显示为 disconnected。
class RealHardwareService implements HardwareService {
  final String broker;
  final int mqttPort;
  final String mqttUser;
  final String mqttPass;
  final String deviceId;
  final String tcpHost;
  final int tcpPort;

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
  };

  RealHardwareService({
    this.broker = AppConfig.mqttBroker,
    this.mqttPort = AppConfig.mqttPort,
    this.mqttUser = AppConfig.mqttUser,
    this.mqttPass = AppConfig.mqttPass,
    this.deviceId = AppConfig.deviceId,
    this.tcpHost = AppConfig.deviceTcpHost,
    this.tcpPort = AppConfig.deviceTcpPort,
  });

  /// MQTT 状态广播主题：cnc/<deviceId>/status（按实例 deviceId 推导）
  String get mqttStatusTopic => 'cnc/$deviceId/status';

  /// MQTT 命令下发主题：cnc/<deviceId>/cmd
  String get mqttCmdTopic => 'cnc/$deviceId/cmd';

  @override
  Stream<MachineStatus> get statusStream => _ctrl.stream;

  /// 连接态流：connecting / connected / disconnected，UI 订阅以显示链路状态。
  Stream<ConnectionState> get connectionState => _connCtrl.stream;
  ConnectionState get currentConnectionState => _conn;

  @override
  Future<void> connect() async {
    _connectMqtt();
    _connectTcp();
  }

  Future<void> _connectMqtt() async {
    if (_conn == ConnectionState.connected) return;
    _setConn(ConnectionState.connecting);
    try {
      // 每次重连都新建 client，避免复用已断开实例的脏状态
      final client = MqttServerClient(broker, 'alexcnc_${_shortId()}');
      client.port = mqttPort;
      client.keepAlivePeriod = 30;
      client.logging(on: false);
      client.onDisconnected = _onMqttDisconnected;
      await client.connect(
        mqttUser.isEmpty ? null : mqttUser,
        mqttPass.isEmpty ? null : mqttPass,
      );
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _mqtt = client;
        client.subscribe(mqttStatusTopic, MqttQos.atLeastOnce);
        client.updates!.listen(_onMqtt);
        _reconnectAttempts = 0;
        _setConn(ConnectionState.connected);
      } else {
        _setConn(ConnectionState.disconnected);
        _scheduleReconnect();
      }
    } catch (_) {
      // 云端不可达：保持离线并尝试重连，不阻断 App
      _setConn(ConnectionState.disconnected);
      _scheduleReconnect();
    }
  }

  void _onMqttDisconnected() {
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
      _tcp = await Socket.connect(tcpHost, tcpPort,
          timeout: const Duration(seconds: 3));
      _tcpConnected = true;
      _tcp!.listen((data) {
        final text = utf8.decode(data);
        for (final line in text.split('\n')) {
          final t = line.trim();
          if (t.isNotEmpty) _parseAndEmit(t);
        }
      }, onDone: () {
        _tcpConnected = false;
        _scheduleTcpReconnect();
      }, onError: (_) {
        _tcpConnected = false;
        _scheduleTcpReconnect();
      });
    } catch (_) {
      _tcpConnected = false;
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
      if (j is Map<String, dynamic>) _ctrl.add(MachineStatus.fromJson(j));
    } catch (_) {
      // 非 JSON 行（如 Grbl 原始 <...>）可在此扩展解析
    }
  }

  void _publish(Map<String, dynamic> cmd) {
    final json = jsonEncode(cmd);
    // 主链路：MQTT 命令
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

  String _shortId() =>
      DateTime.now().millisecondsSinceEpoch.toRadixString(36);

  @override
  Future<void> disconnect() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _tcpReconnectTimer?.cancel();
    _tcp?.destroy();
    _tcp = null;
    _tcpConnected = false;
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
  Future<void> startSpindle(double rpm) async =>
      _publish({'cmd': 'spindle', 'rpm': rpm});

  @override
  Future<void> stopSpindle() async => _publish({'cmd': 'spindle', 'rpm': 0});

  @override
  Future<void> setAux(String key, bool on) async {
    _aux[key] = on;
    _publish({'cmd': 'aux', 'key': key, 'on': on});
  }

  @override
  Future<void> startJob() async =>
      _publish({'cmd': 'job', 'action': 'start'});

  @override
  Future<void> pauseJob() async =>
      _publish({'cmd': 'job', 'action': 'pause'});

  @override
  Future<void> resumeJob() async =>
      _publish({'cmd': 'job', 'action': 'resume'});

  @override
  Future<void> stopJob() async => _publish({'cmd': 'job', 'action': 'stop'});

  @override
  Future<void> updateToolMap(List<Tool> tools) async => _publish({
        'cmd': 'toolMap',
        'tools': tools
            .map((t) => {
                  'index': t.index,
                  'installed': t.installed,
                })
            .toList(),
      });

  @override
  Future<void> setLevelingPlan(
      {required int mode, required int cols, required int rows}) async {
    _publish({
      'cmd': 'leveling',
      'mode': mode,
      'cols': cols,
      'rows': rows,
    });
  }

  bool getAux(String key) => _aux[key] ?? false;

  void dispose() {
    _reconnectTimer?.cancel();
    _tcpReconnectTimer?.cancel();
    _tcp?.destroy();
    _mqtt?.disconnect();
    _ctrl.close();
    _connCtrl.close();
  }
}

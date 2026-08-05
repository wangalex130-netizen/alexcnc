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
  final String deviceId;
  final String tcpHost;
  final int tcpPort;

  final _ctrl = StreamController<MachineStatus>.broadcast();
  MqttServerClient? _mqtt;
  Socket? _tcp;
  bool _tcpConnected = false;
  final Map<String, bool> _aux = {
    'light': false,
    'laser': false,
    'timelapse': false,
  };

  RealHardwareService({
    this.broker = AppConfig.mqttBroker,
    this.mqttPort = AppConfig.mqttPort,
    this.deviceId = AppConfig.deviceId,
    this.tcpHost = AppConfig.deviceTcpHost,
    this.tcpPort = AppConfig.deviceTcpPort,
  });

  @override
  Stream<MachineStatus> get statusStream => _ctrl.stream;

  @override
  Future<void> connect() async {
    _connectMqtt();
    _connectTcp();
  }

  Future<void> _connectMqtt() async {
    try {
      final client = MqttServerClient(broker, 'alexcnc_${_shortId()}');
      client.port = mqttPort;
      client.keepAlivePeriod = 30;
      client.logging(on: false);
      client.onDisconnected = () {
        // 断线后由外层重连策略处理；此处仅记录
      };
      await client.connect(
        AppConfig.mqttUser.isEmpty ? null : AppConfig.mqttUser,
        AppConfig.mqttPass.isEmpty ? null : AppConfig.mqttPass,
      );
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _mqtt = client;
        client.subscribe(AppConfig.mqttStatusTopic, MqttQos.atLeastOnce);
        client.updates!.listen(_onMqtt);
      }
    } catch (_) {
      // 云端不可达：保持离线，不阻断 App
    }
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
      }, onDone: () => _tcpConnected = false,
          onError: (_) => _tcpConnected = false);
    } catch (_) {
      _tcpConnected = false;
    }
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
          AppConfig.mqttCmdTopic, MqttQos.atLeastOnce, builder.payload!);
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
    _tcp?.destroy();
    _tcp = null;
    _tcpConnected = false;
    _mqtt?.disconnect();
    _mqtt = null;
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
    _tcp?.destroy();
    _mqtt?.disconnect();
    _ctrl.close();
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../app/config.dart';
import '../models/machine_status.dart';

/// 单台设备的在线感知（presence）。
///
/// 与"当前控制机"完全解耦：App 用一条**独立常驻** MQTT 连接订阅
/// **所有绑定设备**的 `cnc/<id>/status`，从而像 PC 监控页 / 服务器后台一样，
/// 在机器列表里同时看到每台机器真实在线状态，而不是只能看当前控制的那一台。
///
/// 数据来源 = MQTT Broker 上的真相（与 PC/服务器同源）：
/// - 设备在线时，固件周期性 / 上电发布 `cnc/<id>/status`（state != disconnected）；
/// - 设备掉线时，Broker 自动代发 LWT `{"state":"disconnected"}`（retain）。
/// 两者共同决定每台设备的 online。
class DevicePresence {
  final bool online;
  final MachineState? state;
  final DateTime lastSeen;

  const DevicePresence({
    this.online = false,
    this.state,
    required this.lastSeen,
  });
}

/// 常驻在线监听服务。
///
/// 独立 clientId（`android-presence-<userId>`），与按设备重建的控制连接互不干扰，
/// 不会因切换当前机器而重连，因此能稳定监听全部绑定设备。
class DevicePresenceService {
  final String broker;
  final int mqttPort;
  final String mqttUser;
  final String mqttPass;

  DevicePresenceService({
    this.broker = AppConfig.mqttBroker,
    this.mqttPort = AppConfig.mqttPort,
    this.mqttUser = AppConfig.mqttUser,
    this.mqttPass = AppConfig.mqttPass,
  });

  final Map<String, DevicePresence> _map = {};
  final _ctrl = StreamController<Map<String, DevicePresence>>.broadcast();
  Stream<Map<String, DevicePresence>> get presenceStream => _ctrl.stream;
  Map<String, DevicePresence> get presence => Map.unmodifiable(_map);

  MqttServerClient? _client;
  final Set<String> _subscribed = {};
  Timer? _staleTimer;
  bool _closing = false;

  /// 启动常驻连接。可重复调用，仅首次生效。
  void init() {
    if (_client != null) return;
    _closing = false;
    _connect();
    _staleTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _checkStale());
  }

  void _connect() {
    final client = MqttServerClient(
      broker,
      'android-presence-${AppConfig.appUserId}',
    );
    client.port = mqttPort;
    client.secure = true; // TLS 8883，与控制连接一致
    client.onBadCertificate = (Object cert) => true; // 联调期信任自签；上线换正式 CA
    client.keepAlivePeriod = 30;
    client.logging(on: false);
    client.onDisconnected = _onDisconnected;
    client.onSubscribeFail =
        (String topic) => print('[presence] subscribe DENIED (ACL): $topic');
    client.connectionMessage = MqttConnectMessage().startClean();
    _client = client;
    client
        .connect(
      mqttUser.isEmpty ? null : mqttUser,
      mqttPass.isEmpty ? null : mqttPass,
    )
        .then((_) {
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        client.updates!.listen(_onMessage);
        for (final id in _subscribed) _sub(id); // 重连后补订阅
      }
    }).catchError((e) => print('[presence] connect error: $e'));
  }

  /// 更新需要监听的绑定设备（sn 列表）。新增订阅、移除解绑设备。
  void updateBoundDevices(List<String> sns) {
    final wanted = sns.where((s) => s.isNotEmpty).toSet();
    for (final id in List<String>.from(_subscribed)) {
      if (!wanted.contains(id)) {
        _subscribed.remove(id);
        _map.remove(id);
      }
    }
    for (final id in wanted) {
      _subscribed.add(id);
      _sub(id);
    }
    _emit();
  }

  void _sub(String id) {
    _client?.subscribe('cnc/$id/status', MqttQos.atLeastOnce);
  }

  void _onMessage(List<MqttReceivedMessage<MqttMessage>> events) {
    var dirty = false;
    for (final ev in events) {
      final msg = ev.payload;
      if (msg is! MqttPublishMessage) continue;
      final t = ev.topic;
      // 只处理 cnc/<id>/status
      if (!t.startsWith('cnc/') || !t.endsWith('/status')) continue;
      final id = t.substring(4, t.length - 7); // 去掉 "cnc/" 与 "/status"
      final payload = utf8.decode(msg.payload.message, allowMalformed: true);
      try {
        final j = jsonDecode(payload) as Map<String, dynamic>;
        final raw = j['state'];
        final offline = raw == 'disconnected';
        _map[id] = DevicePresence(
          online: !offline,
          state: _parseState(raw),
          lastSeen: DateTime.now(),
        );
        dirty = true;
      } catch (_) {
        // 脏帧静默忽略
      }
    }
    if (dirty) _emit();
  }

  MachineState? _parseState(dynamic s) {
    if (s is! String) return null;
    for (final v in MachineState.values) {
      if (v.name == s) return v;
    }
    return null;
  }

  void _onDisconnected() {
    // App 自身 MQTT 断了 → 拿不到任何状态 → 全部判离线（诚实）
    for (final k in _map.keys) {
      _map[k] = DevicePresence(online: false, lastSeen: DateTime.now());
    }
    _emit();
    if (!_closing) {
      Future.delayed(const Duration(seconds: 3), () {
        if (!_closing && _client == null) _connect();
      });
    }
  }

  /// 长期收不到状态帧（>90s）即判离线，覆盖 LWT 偶发丢失。
  void _checkStale() {
    final now = DateTime.now();
    var changed = false;
    for (final e in _map.entries) {
      if (e.value.online &&
          now.difference(e.value.lastSeen).inSeconds > 90) {
        _map[e.key] = DevicePresence(
          online: false,
          state: e.value.state,
          lastSeen: e.value.lastSeen,
        );
        changed = true;
      }
    }
    if (changed) _emit();
  }

  void _emit() => _ctrl.add(Map.unmodifiable(_map));

  void dispose() {
    _closing = true;
    _staleTimer?.cancel();
    _client?.disconnect();
    _client = null;
  }
}

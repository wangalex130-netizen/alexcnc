import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../app/config.dart';
import '../models/machine_status.dart';

/// 单台设备的在线感知（presence）。
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

/// 常驻在线监听服务连接状态。
enum PresenceConnectionState {
  idle,
  connecting,
  connected,
  disconnected,
}

/// 回放最近一次值的广播流：新订阅者立即收到当前值。
///
/// [DevicePresenceService.connectionState] 用广播流，但诊断条 [StreamBuilder] 在连接
/// 早已 `connected` 之后才订阅，普通广播流会永远错过该事件而停在 initialData(idle)，
/// 导致诊断条误显"在线状态同步未启动"并一直转圈。回放当前值可消除该时序竞态。
class _ReplayBroadcaster<T> {
  final StreamController<T> _inner = StreamController<T>.broadcast();
  T? _last;
  bool _closed = false;

  Stream<T> get stream {
    final out = StreamController<T>();
    if (_last != null) out.add(_last as T);
    final sub = _inner.stream.listen(
      out.add,
      onError: out.addError,
      onDone: out.close,
    );
    out.onCancel = sub.cancel;
    return out.stream;
  }

  void add(T value) {
    _last = value;
    if (!_closed) _inner.add(value);
  }

  void close() {
    _closed = true;
    _inner.close();
  }
}

/// 常驻在线监听服务。
///
/// 与"当前控制机"完全解耦：App 用一条**独立常驻** MQTT 连接订阅
/// **所有绑定设备**的 `cnc/<id>/status`，从而像 PC 监控页 / 服务器后台一样，
/// 在机器列表里同时看到每台机器真实在线状态。
///
/// 数据来源 = MQTT Broker 上的真相（与 PC/服务器同源）：
/// - 设备在线时，固件周期性 / 上电发布 `cnc/<id>/status`（state != disconnected）；
/// - 设备掉线时，Broker 自动代发 LWT `{"state":"disconnected"}`（retain）。
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

  final _connCtrl = _ReplayBroadcaster<PresenceConnectionState>();
  // 缓存一次，保证稳定 identity（供 Riverpod select 比对），且新订阅者立即收到当前值。
  late final Stream<PresenceConnectionState> connectionState = _connCtrl.stream;

  MqttServerClient? _client;
  final Set<String> _subscribed = {};
  final Set<String> _deniedSubs = {};
  Timer? _staleTimer;
  Timer? _reconnectTimer;
  bool _closing = false;
  bool _connecting = false;
  String? lastError;

  /// 启动常驻连接。可重复调用，线程安全。
  void init() {
    if (_closing) return;
    if (_client != null) return; // 已连接或连接中
    _connect();
    _staleTimer ??= Timer.periodic(const Duration(seconds: 30), (_) => _checkStale());
  }

  void _setConn(PresenceConnectionState s) {
    _connState = s;
    _connCtrl.add(s);
  }

  /// 暴露当前连接态（非流），供诊断条在订阅前也能直接判读，避免首屏误显"未启动"。
  PresenceConnectionState get currentConnectionState =>
      _connState;
  PresenceConnectionState _connState = PresenceConnectionState.idle;

  Future<void> _connect() async {
    if (_closing || _connecting) return;
    _connecting = true;
    _setConn(PresenceConnectionState.connecting);

    // 断线后旧实例必须彻底废弃，复用已断开的 client 会导致互踢或脏状态。
    _client?.disconnect();
    _client = null;

    final clientId = 'android-presence-${AppConfig.appUserId}';
    final client = MqttServerClient(broker, clientId);
    client.port = mqttPort;
    client.secure = true; // TLS 8883，与控制连接一致
    client.onBadCertificate = (Object cert) => true; // 联调期信任自签；上线换正式 CA
    client.keepAlivePeriod = 30;
    client.logging(on: false);
    client.onDisconnected = _onDisconnected;
    client.onSubscribeFail = (String topic) {
      if (!_deniedSubs.contains(topic)) _deniedSubs.add(topic);
      print('[presence] subscribe DENIED (ACL): $topic');
    };
    // 与控制连接一致：clean session，避免 session 残留导致订阅状态混乱。
    client.connectionMessage = MqttConnectMessage().startClean();

    _client = client;

    try {
      await client.connect(
        mqttUser.isEmpty ? null : mqttUser,
        mqttPass.isEmpty ? null : mqttPass,
      );
      if (client.connectionStatus?.state == MqttConnectionState.connected) {
        _setConn(PresenceConnectionState.connected);
        client.updates!.listen(_onMessage);
        // 重连后补订阅
        for (final id in List<String>.from(_subscribed)) {
          _sub(id);
        }
      } else {
        throw Exception('connection status: ${client.connectionStatus?.state}');
      }
    } catch (e) {
      lastError = e.toString();
      print('[presence] connect error: $e');
      _setConn(PresenceConnectionState.disconnected);
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
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
      if (_subscribed.add(id)) _sub(id);
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
    _setConn(PresenceConnectionState.disconnected);
    // App 自身 MQTT 断了 → 拿不到任何状态 → 全部判离线（诚实）
    for (final k in _map.keys) {
      _map[k] = DevicePresence(online: false, lastSeen: DateTime.now());
    }
    _emit();
    _client = null;
    if (!_closing) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!_closing && _client == null) _connect();
    });
  }

  /// 长期收不到状态帧（>90s）即判离线，覆盖 LWT 偶发丢失。
  void _checkStale() {
    final now = DateTime.now();
    var changed = false;
    for (final e in _map.entries) {
      if (e.value.online && now.difference(e.value.lastSeen).inSeconds > 90) {
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
    _reconnectTimer?.cancel();
    _staleTimer?.cancel();
    _client?.disconnect();
    _client = null;
    _connCtrl.close();
  }
}

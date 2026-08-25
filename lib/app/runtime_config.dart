import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 运行时联调配置：在 App 内覆盖编译期 --dart-define 默认值（[AppConfig]），
/// 保存到 SharedPreferences 持久化，下次启动自动恢复。
///
/// 规则：字段为空字符串 / 0 时回落 [AppConfig] 原值（--dart-define 默认值），
/// 保证默认行为不变。保存后 providers 自动重建服务并触发重连。
class RuntimeConfig {
  final bool useRealBackend;
  final String cloudBaseUrl;
  // ---- 账号/绑定后端地址（登录、我的机器等 /api/auth/*、/api/machine/*）----
  // 与 cloudBaseUrl 默认同域（https://037123.xyz），但独立成字段以便联调时
  // 把登录地址切到工程师给的可达地址，无需重新出包。
  final String backendBaseUrl;
  final String mqttBroker;
  final int mqttPort;
  final String mqttUser;
  final String mqttPass;
  final String deviceTcpHost;
  final int deviceTcpPort;
  final String deviceId;
  final String cameraRtspUrl;
  final String cameraRelayBaseUrl;
  final String cameraRelayToken;
  final String cameraRelayDevice;
  // ---- App 用户标识（MQTT clientId = app-<userId>）----
  final String appUserId;

  const RuntimeConfig({
    this.useRealBackend = false,
    this.cloudBaseUrl = '',
    this.backendBaseUrl = '',
    this.mqttBroker = '',
    this.mqttPort = 0,
    this.mqttUser = '',
    this.mqttPass = '',
    this.deviceTcpHost = '',
    this.deviceTcpPort = 0,
    this.deviceId = '',
    this.cameraRtspUrl = '',
    this.cameraRelayBaseUrl = '',
    this.cameraRelayToken = '',
    this.cameraRelayDevice = '',
    this.appUserId = '',
  });

  // ---- resolved：空值 / 0 回落 AppConfig（--dart-define 默认值）----
  bool get resolvedUseRealBackend => useRealBackend || AppConfig.useRealBackend;
  String get resolvedCloudBaseUrl =>
      cloudBaseUrl.isNotEmpty ? cloudBaseUrl : AppConfig.cloudBaseUrl;
  // ---- 账号后端地址（登录/绑定/我的机器），独立可配，默认回落 AppConfig.backendBaseUrl ----
  String get resolvedBackendBaseUrl =>
      backendBaseUrl.isNotEmpty ? backendBaseUrl : AppConfig.backendBaseUrl;
  String get resolvedMqttBroker =>
      mqttBroker.isNotEmpty ? mqttBroker : AppConfig.mqttBroker;
  int get resolvedMqttPort => mqttPort > 0 ? mqttPort : AppConfig.mqttPort;
  String get resolvedMqttUser =>
      mqttUser.isNotEmpty ? mqttUser : AppConfig.mqttUser;
  String get resolvedMqttPass =>
      mqttPass.isNotEmpty ? mqttPass : AppConfig.mqttPass;
  String get resolvedDeviceTcpHost =>
      deviceTcpHost.isNotEmpty ? deviceTcpHost : AppConfig.deviceTcpHost;
  int get resolvedDeviceTcpPort =>
      deviceTcpPort > 0 ? deviceTcpPort : AppConfig.deviceTcpPort;
  String get resolvedDeviceId =>
      deviceId.isNotEmpty ? deviceId : AppConfig.deviceId;
  String get resolvedCameraRtsp =>
      cameraRtspUrl.isNotEmpty ? cameraRtspUrl : AppConfig.cameraRtspUrl;
  String get resolvedCameraRelayBaseUrl => cameraRelayBaseUrl.isNotEmpty
      ? cameraRelayBaseUrl
      : AppConfig.cameraRelayBaseUrl;
  String get resolvedCameraRelayToken =>
      cameraRelayToken.isNotEmpty ? cameraRelayToken : AppConfig.cameraRelayToken;
  String get resolvedCameraRelayDevice => cameraRelayDevice.isNotEmpty
      ? cameraRelayDevice
      : AppConfig.cameraRelayDevice;
  // ---- App 用户标识 ----
  // 存的是裸 userId（如 demo）；若用户误填了带前导 'app-' 的值（形如 app-demo），
  // 这里兜底去掉，避免 RealHardwareService 拼出 'app-app-demo' 双前缀（R12）。
  String get resolvedAppUserId {
    final raw = appUserId.isNotEmpty ? appUserId : AppConfig.appUserId;
    return raw.startsWith('app-') ? raw.substring(4) : raw;
  }

  Map<String, dynamic> toJson() => {
        'useRealBackend': useRealBackend,
        'cloudBaseUrl': cloudBaseUrl,
        'backendBaseUrl': backendBaseUrl,
        'mqttBroker': mqttBroker,
        'mqttPort': mqttPort,
        'mqttUser': mqttUser,
        'mqttPass': mqttPass,
        'deviceTcpHost': deviceTcpHost,
        'deviceTcpPort': deviceTcpPort,
        'deviceId': deviceId,
        'cameraRtspUrl': cameraRtspUrl,
        'cameraRelayBaseUrl': cameraRelayBaseUrl,
        'cameraRelayToken': cameraRelayToken,
        'cameraRelayDevice': cameraRelayDevice,
        'appUserId': appUserId,
      };

  factory RuntimeConfig.fromJson(Map<String, dynamic> j) => RuntimeConfig(
        useRealBackend: j['useRealBackend'] == true,
        cloudBaseUrl: (j['cloudBaseUrl'] as String?) ?? '',
        backendBaseUrl: (j['backendBaseUrl'] as String?) ?? '',
        mqttBroker: (j['mqttBroker'] as String?) ?? '',
        mqttPort: (j['mqttPort'] as num?)?.toInt() ?? 0,
        mqttUser: (j['mqttUser'] as String?) ?? '',
        mqttPass: (j['mqttPass'] as String?) ?? '',
        deviceTcpHost: (j['deviceTcpHost'] as String?) ?? '',
        deviceTcpPort: (j['deviceTcpPort'] as num?)?.toInt() ?? 0,
        deviceId: (j['deviceId'] as String?) ?? '',
        cameraRtspUrl: (j['cameraRtspUrl'] as String?) ?? '',
        cameraRelayBaseUrl: (j['cameraRelayBaseUrl'] as String?) ?? '',
        cameraRelayToken: (j['cameraRelayToken'] as String?) ?? '',
        cameraRelayDevice: (j['cameraRelayDevice'] as String?) ?? '',
        appUserId: (j['appUserId'] as String?) ?? '',
      );
}

class RuntimeConfigNotifier extends Notifier<RuntimeConfig> {
  static const _key = 'runtime_config_v1';
  Future<void>? _hydrating;

  @override
  RuntimeConfig build() {
    _hydrate();
    return const RuntimeConfig();
  }

  Future<void> _hydrate() => _hydrating ??= _doHydrate();

  Future<void> _doHydrate() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      state = RuntimeConfig.fromJson(j);
    } catch (_) {
      // 解析失败忽略，保持默认
    }
  }

  /// 等待持久化配置加载完成（联调设置页 initState 用，保证回显已保存值）。
  Future<RuntimeConfig> get hydrated async {
    await _hydrate();
    return state;
  }

  Future<void> save(RuntimeConfig cfg) async {
    state = cfg;
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(cfg.toJson()));
  }
}

/// 全局运行时配置（联调设置页可读写，providers 据此重建服务）。
final runtimeConfigProvider =
    NotifierProvider<RuntimeConfigNotifier, RuntimeConfig>(
  RuntimeConfigNotifier.new,
);
/// 运行时配置中心。
///
/// 所有「环境相关」的地址都集中在此，并支持通过 `--dart-define` 在构建时覆盖，
/// 以便 dev / staging / prod 用同一套代码、不同参数出包。默认值贴合当前实验室环境。
///
/// 用法示例（出生产包时）：
///   flutter build apk --release \
///     --dart-define=USE_REAL_BACKEND=true \
///     --dart-define=CLOUD_BASE_URL=https://cnc.your-domain.com \
///     --dart-define=MQTT_BROKER=broker.emqx.io \
///     --dart-define=DEVICE_TCP_HOST=192.168.1.50
class AppConfig {
  const AppConfig._();

  // ---- 摄像头（机器侧面固定头，纯裸画面，无叠加层）----
  // 雄迈模组：同网段手机可直接播放；ONVIF 自动发现作为兜底。
  static const String cameraRtspUrl = String.fromEnvironment(
    'CAMERA_RTSP',
    defaultValue: 'rtsp://admin:abc123456@192.168.1.47:554/11',
  );

  // ---- 后端选择 ----
  // false = 用 Mock 实现（演示/无硬件也可跑）；true = 接真 MQTT/TCP/云端。
  static const bool useRealBackend =
      bool.fromEnvironment('USE_REAL_BACKEND', defaultValue: false);

  // ---- 云端（材质主表 / 任务元数据 / G-code 推送）----
  static const String cloudBaseUrl = String.fromEnvironment(
    'CLOUD_BASE_URL',
    defaultValue: 'https://cnc-api.local',
  );

  // ---- MQTT（云端 Broker，主链路：状态订阅 + 命令下发）----
  static const String mqttBroker = String.fromEnvironment(
    'MQTT_BROKER',
    defaultValue: 'broker.emqx.io',
  );
  static const int mqttPort =
      int.fromEnvironment('MQTT_PORT', defaultValue: 1883);
  static const String mqttUser =
      String.fromEnvironment('MQTT_USER', defaultValue: '');
  static const String mqttPass =
      String.fromEnvironment('MQTT_PASS', defaultValue: '');

  // ---- 设备局域网 TCP（低延迟运动控制：jog / 回零 / 定原点）----
  static const String deviceTcpHost = String.fromEnvironment(
    'DEVICE_TCP_HOST',
    defaultValue: '192.168.1.50',
  );
  static const int deviceTcpPort =
      int.fromEnvironment('DEVICE_TCP_PORT', defaultValue: 8899);

  // ---- 设备标识（用于 MQTT topic 与云端任务下发目标）----
  static const String deviceId =
      String.fromEnvironment('DEVICE_ID', defaultValue: 'alexcnc-001');

  /// MQTT 状态广播主题：cnc/<deviceId>/status
  static String get mqttStatusTopic => 'cnc/$deviceId/status';

  /// MQTT 命令下发主题：cnc/<deviceId>/cmd
  static String get mqttCmdTopic => 'cnc/$deviceId/cmd';
}

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
  // 当前方案：ESP32 CameraWebServer（MJPEG over HTTP，端口 81，无认证）+ 原装 RTSP 摄像头。
  // 默认地址可留空 → 启动时自动发现（先读上次成功缓存，再扫 Wi-Fi 网段
  // 的 81 端口 + 554 RTSP），换网络/换 IP 无需手动配置。
  // 已知摄像头（App 内「联调设置」可一键填入，免去对自动发现的依赖）：
  //   原装摄像头：rtsp://admin:abc123456@192.168.1.205:554/11
  //   ESP32 调试：http://192.168.1.248:81/stream
  // 如需固定地址：--dart-define=CAMERA_RTSP=http://192.168.1.248:81/stream 覆盖，
  // 或在 App 内「联调设置」里填写。
  static const String cameraRtspUrl = String.fromEnvironment(
    'CAMERA_RTSP',
    defaultValue: '',
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

  // ---- 2D 刀路预览（协议 §3.2 渲染矢量）----
  // 2026-08-07 决策链：驱动在电脑端生成 G-code，客户可选择上传至库（上传的是 G-code 本体）。
  // 因此云端有 G-code 即可现算渲染矢量（server.py gcode_to_preview / GET /models/{id}/preview），
  // 无需驱动额外产出 JSON。入口默认开启，但仅对「带 G-code 的模型」（gcodeStatus=sliced 或自带
  // previewUrl）显示预览区块，未上传/未切片的模型不出现空预览。
  // 如需紧急关闭：--dart-define=TOOLPATH_PREVIEW_ENABLED=false。
  static const bool toolpathPreviewEnabled = bool.fromEnvironment(
    'TOOLPATH_PREVIEW_ENABLED',
    defaultValue: true,
  );

  /// MQTT 状态广播主题：cnc/<deviceId>/status
  static String get mqttStatusTopic => 'cnc/$deviceId/status';

  /// MQTT 命令下发主题：cnc/<deviceId>/cmd
  static String get mqttCmdTopic => 'cnc/$deviceId/cmd';
}

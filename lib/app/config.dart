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
  // 当前方案：ESP32 CameraWebServer（MJPEG over HTTP，端口 81，无认证）。
  // 默认地址可留空 → 启动时自动发现（先读上次成功缓存，再扫 Wi-Fi 网段
  // 的 81 端口 + 554 RTSP），换网络/换 IP 无需手动配置。
  // 如需固定地址：--dart-define=CAMERA_RTSP=http://192.168.1.248:81/stream 覆盖，
  // 或在 App 内「联调设置」里填写。
  static const String cameraRtspUrl = String.fromEnvironment(
    'CAMERA_RTSP',
    defaultValue: '',
  );

  // ---- 摄像头云中继（远程监视模式）----
  // 摄像头把 JPEG 帧直推到这台服务器，App 在远程网络下从中继拉 MJPEG 流。
  // 与固件 RELAY: 指令一致：RELAY:<baseUrl>|<token>|<device>|<fps>
  // 示例：--dart-define=CAMERA_RELAY_BASE_URL=http://43.154.192.242:8080
  static const String cameraRelayBaseUrl = String.fromEnvironment(
    'CAMERA_RELAY_BASE_URL',
    defaultValue: 'http://43.154.192.242:8080',
  );
  static const String cameraRelayToken = String.fromEnvironment(
    'CAMERA_RELAY_TOKEN',
    defaultValue: 'lunyee-cnc-relay-7k2p',
  );
  static const String cameraRelayDevice = String.fromEnvironment(
    'CAMERA_RELAY_DEVICE',
    defaultValue: 'cnc-cam-01',
  );

  // ---- 后端选择 ----
  // false = 用 Mock 实现（演示/无硬件也可跑）；true = 接真 MQTT/TCP/云端。
  static const bool useRealBackend =
      bool.fromEnvironment('USE_REAL_BACKEND', defaultValue: false);

  // ---- 账号/绑定后端（A1-A4：注册登录 / 扫码绑定 / 我的机器）----
  // 与 cameraRelayBaseUrl 同机不同端口。配网在屏幕端完成，App 不配网、不加蓝牙。
  // --dart-define=BACKEND_BASE_URL=... 可覆盖。
  static const String backendBaseUrl = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: 'http://43.154.192.242:8081',
  );

  // ---- 云端（材质主表 / 任务元数据 / G-code 推送）----
  static const String cloudBaseUrl = String.fromEnvironment(
    'CLOUD_BASE_URL',
    defaultValue: 'https://037123.xyz',
  );

  // ---- MQTT（云端 Broker，主链路：状态订阅 + 命令下发）----
  static const String mqttBroker = String.fromEnvironment(
    'MQTT_BROKER',
    defaultValue: '43.154.192.242',
  );
  static const int mqttPort =
      int.fromEnvironment('MQTT_PORT', defaultValue: 8883);
  static const String mqttUser =
      String.fromEnvironment('MQTT_USER', defaultValue: 'app-demo');
  static const String mqttPass =
      String.fromEnvironment('MQTT_PASS', defaultValue: 'demo123');

  // ---- 设备局域网 TCP（低延迟运动控制：jog / 回零 / 定原点）----
  static const String deviceTcpHost = String.fromEnvironment(
    'DEVICE_TCP_HOST',
    defaultValue: '192.168.1.50',
  );
  static const int deviceTcpPort =
      int.fromEnvironment('DEVICE_TCP_PORT', defaultValue: 8899);

  // ---- 设备标识（用于 MQTT topic 与云端任务下发目标）----
  static const String deviceId =
      String.fromEnvironment('DEVICE_ID', defaultValue: 'cnc-demo-01');

  // ---- App 用户标识（MQTT clientId = app-<userId>，契约 auth.client_id_pattern）----
  // 注意：这里存的是「裸 userId」（默认 demo），clientId 由 RealHardwareService 拼成
  // app-<userId>。之前默认写 'app-demo' 会导致 clientId 变成 'app-app-demo'（双前缀，R12）。
  static const String appUserId =
      String.fromEnvironment('APP_USER_ID', defaultValue: 'demo');

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

  // ---- V1.1 MQTT 主题开关（docs/03 §10.5/§10.6）----
  // 线上 broker ACL 已于 2026-08-17 从主机内侧重载放行 cnc/<id>/job + cnc/<id>/sys 订阅
  // （单一事实源 deploy/acl.conf，由运维/隔壁 AI 完成）。故默认开启；如需紧急回退可
  // 用 --dart-define=V11_MQTT_TOPICS_ENABLED=false 关闭。
  static const bool v11MqttTopicsEnabled = bool.fromEnvironment(
    'V11_MQTT_TOPICS_ENABLED',
    defaultValue: true,
  );

  /// MQTT 状态广播主题：cnc/<deviceId>/status
  static String get mqttStatusTopic => 'cnc/$deviceId/status';

  /// MQTT 命令下发主题：gw/<deviceId>/cmd（经网关白名单转发固件；与实例级一致）
  static String get mqttCmdTopic => 'gw/$deviceId/cmd';
}

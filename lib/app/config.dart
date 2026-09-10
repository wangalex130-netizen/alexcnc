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

  /// W-11（2026-09-10）：摄像头 RTSP 账号 / 口令 **不再硬编码进仓库**。

  ///

  /// 原先在 `camera_discovery.dart` 内置了出厂默认账号口令（公开仓库可读，且会自动

  /// 补进 RTSP URL 与 Basic 认证头）。现改为构建注入：

  ///   --dart-define=CAMERA_USER=xxx --dart-define=CAMERA_PASS=yyy

  /// **量产方向**：每台摄像头随机口令（NVS 烧录，随绑定关系下发），

  /// App 从后端取凭据而非内置（工单 W-11 ②③，需后端 / 固件配合）。

  /// 未配置（空串）时：不注入账号、不补凭据、不发 Basic 头 —— 匿名探测与已改密的

  /// 摄像头仍可用（RTSP 地址本身若已带 @ 凭据则原样保留）。

  static const String cameraUser = String.fromEnvironment(

    'CAMERA_USER',

    defaultValue: '',

  );

  static const String cameraPassword = String.fromEnvironment(

    'CAMERA_PASS',

    defaultValue: '',

  );



  // ---- 摄像头云中继（App 侧唯一取流通道，内外网同一套）----

  // 摄像头把 JPEG 帧直推到这台服务器，App 按需从中继拉 MJPEG 流（后端鉴权）。

  // 与固件 RELAY: 指令一致：RELAY:<baseUrl>|<token>|<device>|<fps>

  // 示例：--dart-define=CAMERA_RELAY_BASE_URL=http://43.154.192.242:8080

  static const String cameraRelayBaseUrl = String.fromEnvironment(

    'CAMERA_RELAY_BASE_URL',

    defaultValue: 'http://39.106.144.53:8080',

  );

  /// 中继 token 同样**不再写死在仓库里**（原默认值是明文 token，公开仓库可读）。

  ///

  /// 现默认空串，实际值由构建注入；内部联调包由 CI 从 Actions Secrets 注入。

  static const String cameraRelayToken = String.fromEnvironment(

    'CAMERA_RELAY_TOKEN',

    defaultValue: '',

  );

  // 2026-08-25 对齐「量产统一机器码」决策：摄像头 device_id = 机器码（同一字符串）。

  // 2026-08-30：兜底默认值由 'cnc-demo-01' 改为**空**。

  // 真实模式下拉流设备码取「当前选中机器」的 sn；留空时由调用方返回空 URL 并提示

  // 「请先选择机器」，而不是静默去拉某一台写死的机器（见 docs/38 A-1）。

  // 联调需要固定目标时用 --dart-define=CAMERA_RELAY_DEVICE=<机器码> 覆盖。

  static const String cameraRelayDevice = String.fromEnvironment(

    'CAMERA_RELAY_DEVICE',

    defaultValue: '',

  );



  // ---- 后端选择 ----

  // false = 用 Mock 实现（演示/无硬件也可跑）；true = 接真 MQTT/TCP/云端。

  static const bool useRealBackend =

      bool.fromEnvironment('USE_REAL_BACKEND', defaultValue: true);



  // ---- 账号/绑定后端（A1-A4：注册登录 / 扫码绑定 / 我的机器）----

  // 2026-08-21 对齐 PC 工程师《安卓用户登陆接口》：账号服务挂在内容面同域名

  // https://037123.xyz（/api/auth/* 命名空间），不再走独立 8081 端口。

  // 配网在屏幕端完成，App 不配网、不加蓝牙。

  // --dart-define=BACKEND_BASE_URL=... 可覆盖。

  static const String backendBaseUrl = String.fromEnvironment(

    'BACKEND_BASE_URL',

    defaultValue: 'https://037123.xyz',

  );



  // ---- 固件升级（OTA，docs/31）----

  // 固件托管服务：与 cameraRelayBaseUrl 同机不同端口（8090）。

  // 本轮只接 camera（服务已就绪）；screen/board 上线后填地址即可，App 代码不用大改。

  static const String fwBaseUrl = String.fromEnvironment(

    'FW_BASE_URL',

    defaultValue: 'http://43.154.192.242:8090',

  );

  // ---- 固件升级「可升级」拉取式检查（docs/56 §3.8，2026-09-08 决策）----
  // 与 fwBaseUrl 不同：这是「App 打开时静默检查是否有新固件」的聚合接口，
  // 由 PC 工程师提供（返回 {available,latest[]} 或 {available:false}）。
  // 接口就绪前留空 → App 不显示绿点（服务端不主动推送，符合产品决策）。
  // 联调时用 --dart-define=FIRMWARE_CHECK_URL=https://... 覆盖。
  static const String firmwareCheckUrl = String.fromEnvironment(

    'FIRMWARE_CHECK_URL',

    defaultValue: '',

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

  /// 凭据**不再写死在仓库里**（原来这里写死了出厂默认账号与口令，公开仓库任何人可读）。

  ///

  /// 现默认值改为空串；实际值由构建注入（`--dart-define=MQTT_USER=...`），

  /// 内部联调包由 CI 从 Actions Secrets 注入，详见 .github/workflows/build.yml。

  /// ⚠️ 轮换凭据时**只需改 Secret，无需改代码**。

  static const String mqttUser =

      String.fromEnvironment('MQTT_USER', defaultValue: '');

  static const String mqttPass =

      String.fromEnvironment('MQTT_PASS', defaultValue: '');

  /// W-01（2026-09-10，P0）：是否旁路 MQTT TLS 证书校验（**仅限联调**）。

  ///

  /// 默认 false = 强制校验证书链。原实现无条件 `onBadCertificate => true`，

  /// 会让同网络 / 路径上的中间人劫持会话、注入伪造状态帧（伪造成 idle 解锁 Jog）。

  /// 联调期 Broker 仍是自签证书时，构建加 `--dart-define=MQTT_ALLOW_SELF_SIGNED=true`；

  /// **正式包一律不带此参数**（Broker 需挂正式 CA 证书或做证书钉扎）。

  static const bool mqttAllowSelfSigned = bool.fromEnvironment(

    'MQTT_ALLOW_SELF_SIGNED',

    defaultValue: false,

  );



  // ---- 设备局域网 TCP（低延迟运动控制：jog / 回零 / 定原点）----

  static const String deviceTcpHost = String.fromEnvironment(

    'DEVICE_TCP_HOST',

    defaultValue: '192.168.1.50',

  );

  static const int deviceTcpPort =

      int.fromEnvironment('DEVICE_TCP_PORT', defaultValue: 8899);



  // ---- 设备标识（用于 MQTT topic 与云端任务下发目标）----

  // 2026-08-30：默认值由 'cnc-demo-01' 改为**空**。

  // 真实模式下设备 ID 一律来自「用户选中的绑定机器」的 sn（后端 code 字段）；

  // 把某个机器码写死在默认值里，会让"未选机器"时静默指向某一台具体机器

  // —— 测试期是串台，量产期是事故（见 docs/38 A-1）。

  // 联调需要固定目标时用 --dart-define=DEVICE_ID=<机器码> 覆盖，不写死在默认值里。

  static const String deviceId =

      String.fromEnvironment('DEVICE_ID', defaultValue: '');



  // ---- App 用户标识（不再参与 MQTT clientId 派生）----

  // 终局方案（2026-08-28）：MQTT clientId 固定为 android-<deviceId>，与 userId 无关。

  // 本值现仅用于摄像头中继拉流的 `user=` 鉴权参数（relay.py 按账号做绑定鉴权）。

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



  /// MQTT 命令下发主题：cnc/<deviceId>/cmd

  /// 终局方案（2026-08-28）：App 直接发布，原网关 gw/<deviceId>/cmd 已废弃。

  static String get mqttCmdTopic => 'cnc/$deviceId/cmd';

}



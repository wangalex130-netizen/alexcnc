# 30 · 配网模式变更与 App A1-A4 改造 · 四端同步通知（2026-08-20）

> 发出方：App 任务（王总已确认） ｜ 接收方：屏幕端 / 摄像头端 / MQTT 端 / 阿里云端
> 状态：App 侧已推 main 并出包（commit `799ef84`，APK `app-release-a1a4.apk`）
> 关联：docs/29（MQTT 配合清单）、APP 端改造任务单_A1-A4.md

---

## 一、一句话总结

**配网改为在屏幕端完成（ESP32 搜 WiFi 入网），App 不再做配网、不加蓝牙。** App 已按 A1-A4 落地「注册账号 → 扫码绑定机器码 → 我的机器列表 → 远程拉流」，拉流地址由后端绑定接口返回、不再写死。各端按本单核对各自待办即可。

## 二、新配网模式（全端共识基线）

```
机器开机
  └─ 屏幕(ESP32)搜索 WiFi → 客户输入家庭 WiFi 密码 → 屏幕入网
        └─ 双 WiFi：屏幕连家庭网；控制板经屏幕联入同一网络（一次连接，两端上网）
  └─ MQTT 收到「机器注册进网」信息（机器唯一码已在线）
客户在电脑端 / App 端注册用户账号
  └─ 扫机器唯一码（机身二维码 / 铭牌 CNC-XXXX...）→ 客户号 ↔ 机器唯一码绑定
        └─ 形成固定「机器 ID 账户」（一客户可绑多机）
MQTT 转发视频流服务器连上这台机器的摄像头 → 客户远程看
```

## 三、App 侧已完成（A1-A4，已推 main）

| 编号 | 内容 |
|---|---|
| A1 | 账号：注册/登录页 + auth_service + 登录态；后端地址 `backendBaseUrl` 默认 `https://037123.xyz`（2026-08-21 对齐 PC 工程师接口，账号服务挂内容面域名）；登录后 MQTT clientId 用真实 `userId` |
| A2 | 扫码绑定：识别 `CNC-` 二维码 → `POST /api/auth/bind`；手动输入兜底；409/404 中文提示 |
| A3 | 我的机器列表 + 拉流解耦：`relay_url/cam_device` 由绑定接口返回，控制台/全屏/延时摄影三处统一改用，未绑定时回退原固定地址 |
| A4 | 我的页：删除「网络配对与连接」蓝牙配网抽屉，改为「我的机器 / 注册账号 / 退出登录」，顶部显示真实账号 |

## 四、各端待办

### 4.1 屏幕端（嵌入式：崔工 / 耿工）

1. **机器唯一码与 MQTT deviceId 的关系**：确认机身二维码/铭牌的 `CNC-XXX` 与 MQTT topic 的 `deviceId`（如 `cnc-demo-01`）**是否同一串**。若不同，需给出映射规则（`CNC-XXX ↔ cnc-xxx ↔ 摄像头 cam_device`），云端按此映射。
2. **机器入网注册**：屏幕连上 WiFi 后，通过 MQTT 上报一次 `cnc/<deviceId>/sys`（复用 V1.1 sys 帧），确保包含 `id / model / fw / ip`，让云端知道「这台机器在线」。
3. **机身二维码**：确保机器上有可被 App 扫描的 `CNC-` 码（屏幕显示二维码或机身铭牌），与绑定接口 `machineSn` 一致。
4. **刀仓/设备配置接口**：保持既有 `037123.xyz` 内容面接口（设备绑定/四刀仓配置）不变，与 App「我的设备/刀具库」共用同一 `deviceCode`/`slot` 语义（见此前同步）。

### 4.2 摄像头端

1. **relay 推流保持**：摄像头（机器侧面固定头）继续按 `RELAY:<baseUrl>|<token>|<device>|<fps>` 向中继推 MJPEG/RTSP；App 远程拉流地址改为 `{relay_url}/stream/{cam_device}?token=...`。
2. **cam_device 命名对齐**：确认摄像头 `cam_device`（如 `cnc-cam-01`）与绑定接口返回一致，联调占位码 `CNC-CAM01 → cnc-cam-01`。
3. **无新增工作**：本模式不要求摄像头参与配网/绑定，保持现状即可。

### 4.3 MQTT 端（隔壁）

1. **机器注册进网**：确认 `cnc/<deviceId>/sys` 已承载「机器入网注册」语义（含 id/model/fw/ip）；必要时在 `docs/03` 补一段「机器入网注册」说明。
2. **CNC 码 ↔ deviceId 映射**：与屏幕端确认后，把映射关系写入契约文档（云端按此实现 bind 查询）。
3. **ACL 无需改动**：App 登录后 clientId 变 `app-<userId>-<唯一后缀>`，broker 按用户名（app-demo / app-<userId>）鉴权，不受影响。
4. **系统 Push（Phase 2）**：按 docs/28 v2 推进（REST 上报 token、notify 可选 accountId、Android FCM 一期），与本单不冲突。

### 4.4 阿里云端（秦工）

1. **账号/绑定后端上线（挂 037123.xyz /api/auth/*）**：实现 5 个接口——`POST /api/auth/register`、`POST /api/auth/android/login`、`POST /api/auth/bind`、`GET /api/auth/my/machines`、`GET /api/auth/stream`（契约见 §五；登录接口已由 PC 工程师文档确认，其余为方案 A 假设待确认）。
2. **账号服务维护绑定关系**：`accountId ↔ machineSn`（一客户多机）；提供 `CNC-XXX` 机器码 → `cam_device`/`relay_url` 的查询能力。
3. **relay 鉴权**：`GET /api/auth/stream?device=&token=&user=` 供 relay 拉流前校验（未绑定返回 403，App 显示「无权限」）。
4. **内容面保持**：设备绑定/刀仓配置（`037123.xyz/api/user/device/*`、`/api/device/bit-config/*`）继续维护，与 App/屏幕共用。

## 四点五、视频流如何到达 App 账户（机制说明，全端共识）

> 常见误解是「视频流服务器收到机器唯一 ID 后，主动把流推给对应 App 账户」。
> **实际不采用主动推送**，而是「摄像头持续推流进中继 → App 按需拉流 → 中继经云端鉴权后放流」。

### 为什么不做「按机器 ID 主动推送」

1. **推给谁 / 推到哪**：App 可能未打开、被系统杀掉、切换网络（IP 变化）、一账号多手机——服务器无法持续知道 App 的实时位置；要主动推必须让 App 维持常驻长连接，复杂且费电。
2. **无法鉴权**：一旦「按 ID 推送」，等于任何拿到机器 ID 的人都能看画面，安全不可控。
3. **耦合过深**：推送模式要求服务器同时知道「机器 ↔ 摄像头 ↔ 用户」的实时状态，业务逻辑全堆在视频服务器上。

### 实际流程（6 步，配合时序图）

```
摄像头 ──0.持续推流MJPEG──► 中继服务器(relay:8080 蓄流)
App ──1.我的机器列表(Bearer)──► 阿里云后端
阿里云后端 ──2.返回 relay_url+cam_device──► App
App ──3.请求拉流(带token)──► 中继服务器
中继服务器 ──4./api/auth/stream 校验权限──► 阿里云后端
阿里云后端 ──5.allow / 403──► 中继服务器
中继服务器 ──6.视频流放行到这台App──► App
```

| 步骤 | 说明 |
|---|---|
| 0 | 摄像头**持续**把流推到中继（不管有没有人看都在推，中继当蓄水池） |
| 1–2 | App 登录后从后端拿「我的机器」，后端只返回**去哪看**（relay_url + cam_device），不返回画面 |
| 3–5 | App 到中继拉流；中继先调 `/api/auth/stream` 问后端「这个用户有权限看这台机器吗」，有则 allow，未绑定则 403 |
| 6 | 鉴权通过才把流放给这台 App |

### 机器唯一 ID 的作用

屏幕码 + 摄像头码在阿里云后端合并成**机器唯一 ID**，作为绑定关系主键：
`机器ID ↔ 绑定账户 ↔ cam_device ↔ relay_url`。App 只认「我的机器」，中继只认「放流」，**双方都不需要知道对方是谁**，全靠后端鉴权中转。

### 对阿里云端的落地要求

- 后端**只需要提供「绑定关系查询 + 鉴权接口」**（`/api/my/machines`、`/api/auth/stream`），**不需要实现推送服务**。
- `/api/auth/stream` 由中继在拉流前调用：`GET /api/auth/stream?device=<cam_device>&token=<relay_token>&user=<userId>` → `{allow:true}` 或 `{allow:false}`。

## 五、App 调用的后端 API 契约（供云端实现）

> 2026-08-21 更新：账号接口统一挂 `/api/auth/*` 前缀、基址 `https://037123.xyz`（PC 工程师《安卓用户登陆接口.docx》确认登录接口，其余路径为方案 A 假设，待 PC 工程师确认后微调）。

| 接口 | 请求 | 成功 | 失败 |
|---|---|---|---|
| `POST /api/auth/register` | `{"email","password"}`（密码加密） | `{userId, token}` | 409 已存在 / 400 |
| `POST /api/auth/android/login` | `{"email","password"}`（密码加密） | `{userId, token}` | 401 |
| `POST /api/auth/bind` | Bearer；`{"machineSn":"CNC-..."}` | `{machine:{sn,cam_device,relay_url,online}}` | 401 / 404 / 409 已绑定 |
| `GET /api/auth/my/machines` | Bearer | `{machines:[...]}`（可空） | 401 |
| `GET /api/auth/stream` | relay 调 | `{allow:true}` | 403 |

> 基址默认 `https://037123.xyz`（`--dart-define=BACKEND_BASE_URL` 可覆盖）。
> 密码加密：密钥由刘昊霖（Myers）提供，App 端 `AuthService.encryptPassword` 已留接口，密钥到位前明文联调。

## 六、端口与服务清单（确认项）

| 项 | 地址 | 状态 |
|---|---|---|
| 账号/绑定后端 | `https://037123.xyz`（/api/auth/*） | 登录接口 PC 已确认；其余待确认 |
| 视频 relay | `http://43.154.192.242:8080` | 已有 |
| MQTT broker | `43.154.192.242:8883`（TLS） | 已有 |
| 内容面 API | `https://037123.xyz` | 已有（与账号服务同域） |
| 机器码映射 | `CNC-XXX ↔ cnc-xxx ↔ cam_device` | 待屏幕端确认 |

## 七、待确认事项（请各端回复）

1. **屏幕端**：`CNC-XXX` 机器码与 MQTT `deviceId` 是否同串？映射规则是什么？
2. **阿里云端（PC 工程师）**：`/api/auth/*` 其余 4 个接口路径是否如方案 A 假设（register/bind/my-machines/stream）？登录返回字段（userId/token）？密码加密密钥（Myers）何时下发？`/api/auth/stream` 是否已接入 relay 校验？
3. **摄像头端**：当前 `cam_device` 命名是否为 `cnc-cam-01`？relay 是否持续出帧？
4. **MQTT 端**：`cnc/<deviceId>/sys` 是否可承载「入网注册」？是否需要新增主题？

## 八、验收标准（对齐后全端一致）

1. App 注册 → 登录 → 扫码绑定 `CNC-` 码 → 我的机器出现该机 → 远程看到画面。
2. 未绑定该机的其他账号看不到流（403，App 显示「无权限」）。
3. 屏幕端配网后机器自动入网注册，App 端无需任何配网操作。
4. 延时摄影、雕刻流程、局域网直连控制不受影响。

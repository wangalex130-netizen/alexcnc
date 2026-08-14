# alexcnc · 统一硬件 / 云端协议契约 v2.0

> **⚠️ 已合并到终版契约**：`docs/三任务一致性终稿.md`。  
> 本文档保留历史讨论脉络，**请以 `三任务一致性终稿.md` 为唯一权威契约**。  
> 终版变更：#4 帧格式由「MQTT 封套 + App 映射」改为 **「APP 扁平 JSON 为线协议真值，src/dst/seq/v/ts 由 MQTT 层承载」**；其余 10 项与本文档一致。

> **阅读对象**：嵌入式（固件）/ MQTT 服务器 / App（Flutter）三方
> **变更来源**：合并《三文档一致性校对报告》（`consistency-review.html`）、控制服务器侧 `docs/12-consensus.md`、固件部署核对结论后的统一版本。
> **两个关键拍板**：① 帧格式采用「APP 扁平 JSON 为线协议真值」；② 状态机采用 App 枚举 `idle/homing/busy/paused/alarm/disconnected`。

---

## 0. 一句话流程

```
App UI ──调用──▶ HardwareService / CloudService（抽象接口）
                        │
        三方实现 ────────┤  RealHardwareService  （App ↔ 机器：LAN TCP:8899 / WAN MQTT）
                        └  RealCloudService     （App ↔ 云端 REST）
```

机器 = **ESP32-S3 屏幕（大脑，MQTT clientId = `screen-{deviceId}`）+ STM32F407 主控（执行层）**。407 默认由屏幕 UART 管辖，不直接连 MQTT；`bridge-*` 保留为 407 独立联网的可选身份（当前不用）。

---

## 1. 三大设计原则

1. **机器是唯一真值源（SSOT）**  
   App 不裁决坐标、刀仓、状态；只监听机器广播的状态并渲染。所有 `MachineStatus` 由 MCU 产生。

2. **资产闭环：手机绝不持有真实 G-code**  
   切片文件由云端经局域网 / MQTT **直接下推给 MCU**。App 只取任务元数据 `TaskMetadata` 和极小的 2D 矢量渲染 JSON。App 永不下载 / 存储实体 G-code。

3. **LAN / WAN 鉴权**  
   手机与机器同 Wi-Fi → `isLocalLAN = true`（全功能：Jog、回零、开切）。  
   手机走 4G/5G 公网 / 云端 MQTT → `isLocalLAN = false`（监视模式：锁死 Jog / 开切，仅留 监控 + pause/resume/stop + light/fan + OTA）。

---

## 2. 传输层

### 2.1 局域网（LAN）—— TCP:8899 直连

- **端口固定 `8899`**。机器侧开 TCP Server（`0.0.0.0`），App 作为 TCP Client 直连 `机器IP:8899`，长连接，双向收发。
- 报文：**换行分隔的 JSON 帧**（每条以 `\n` 结尾）。命令/状态走同一连接。
- 断线后 App 每 5s 重连；`disconnect()` 主动关闭不再重连。
- 不依赖任何 Broker / 云端 / 外网。
- 机器联网后广播 mDNS：`alexcnc-<sn>.local`（Service：`_alexcnc._tcp.local`，port **8899**）。
- 参考实现：`server/fake_firmware.py --tcp`。

### 2.2 外网（WAN）—— MQTT Broker

- **主链路**：云端 MQTT Broker（生产环境）。
  - 生产端口：**8883 TLS**，关匿名，私有 Broker 域名。
  - 本地/开发联调端口：**1883**（仅限内网/本机，不上生产）。
  - WebSocket 端口统一为 **8083**（避免 EMQX 8083 vs Mosquitto 9001 混用；Mosquitto 部署需显式改成 8083 或文档注明）。
- **主题命名空间（每设备隔离）**：

| 主题 | 方向 | QoS | Retain | 说明 |
|------|------|-----|--------|------|
| `cnc/<deviceId>/cmd` | App/PC → 机器 | 1 | 否 | 命令下发（唯一下行通道） |
| `cnc/<deviceId>/status` | 机器 → App/PC | 1 | 是 | 权威状态，新订阅者立即可见 |
| `cnc/<deviceId>/notify` | 机器 → App/PC | 1 | 否 | 事件通知：job_done / alarm 等 |
| `cnc/<deviceId>/telemetry` | 机器 → App/PC | 0 | 否 | 高频遥测（坐标/速度，10Hz），可选 |
| `cnc/<deviceId>/log` | 机器 → App/PC | 0 | 否 | 调试日志，默认关闭 |
| `cnc/broadcast/#` | 机器/云端 → 全部 | 1 | 否 | 全局广播 |
| `sys/#` | admin / 云端 | 1 | 视场景 | 注册 / ACL 同步（仅 admin） |

- **App 至少订阅**：`cnc/<deviceId>/status` + `cnc/<deviceId>/notify`（否则收不到 job_done / alarm）。`telemetry` / `log` 可选。
- **clientId 规则**：
  - 手机 App：`app-<userId>`
  - 机器屏幕：`screen-<deviceId>`
  - 电脑端：`pc-<userId>`
  - 407 独立联网（预留）：`bridge-<deviceId>`
  - 设备运维：`admin`
- **ACL 原则**：
  - `app-*` 只能向自己绑定的 `cnc/{deviceId}/cmd` 发布，只能订阅自己绑定设备的 `status/notify/telemetry/log` 和 `cnc/broadcast/#`。
  - `screen-{id}` 只能发布 `cnc/{id}/status|notify|telemetry|log`，只能订阅 `cnc/{id}/cmd` 和 `cnc/broadcast/#`。
  - 多租户按 `deviceId` 隔离；任何终端无法伪造他人状态。

### 2.3 报文格式：MQTT 封套 + App 内部扁平映射

** wire（MQTT / TCP 之上必须统一）**：

```json
{
  "v": 1,
  "type": "cmd" | "status" | "notify" | "telemetry" | "log",
  "seq": 1001,
  "ts": 1723440000123,
  "src": "app-u123",
  "dst": "cnc-demo-01",
  "payload": { }
}
```

字段含义：
- `v`：协议版本，当前为 1；向后兼容时 +1。
- `type`：帧类型。
- `seq`：发送端单调递增序号，用于排重、溯源、调试。
- `ts`：发送时 Unix 毫秒时间戳。
- `src` / `dst`：源/目标身份，按 §2.2 clientId 规则。`dst` 可为 `cnc-<deviceId>` 或 `broadcast`。
- `payload`：业务载荷，见 §2.4 / §3。

** App 内部（业务/UI/模型层，保持不变）**：

App 继续使用扁平 JSON，业务层无需改动：

```json
// 命令内部格式
{ "cmd": "jog", "axis": "x", "dist": 1.0, "feed": 600 }
{ "cmd": "job", "action": "start" }
{ "cmd": "hello", "model": "LY_3020_2.0", "serial": "<唯一码>", "proto": 1 }

// 状态内部格式
{ "state": "busy", "pos": { "x": 1.0, "y": 0.5, "z": -1.2 }, ... }
```

** 映射关系（由 `RealHardwareService` 封装层负责）**：

| 内部命令 | wire payload |
|---|---|
| `{"cmd":"jog","axis":"x","dist":1.0,"feed":600}` | `{"action":"jog","params":{"x":1.0,"feed":600}}` |
| `{"cmd":"home"}` | `{"action":"home","params":{}}` |
| `{"cmd":"setWorkZero","x":0,"y":0,"z":0}` | `{"action":"setWorkZero","params":{"x":0,"y":0,"z":0}}` |
| `{"cmd":"spindle","rpm":12000}` | `{"action":"spindle","params":{"rpm":12000}}` |
| `{"cmd":"aux","key":"light","on":true}` | `{"action":"aux","params":{"key":"light","on":true}}` |
| `{"cmd":"job","action":"start"}` | `{"action":"job","params":{"action":"start"}}` |
| `{"cmd":"toolMap","tools":[...]}` | `{"action":"toolMap","params":{"tools":[...]}}` |
| `{"cmd":"leveling","mode":1,"cols":5,"rows":4}` | `{"action":"leveling","params":{"mode":1,"cols":5,"rows":4}}` |
| `{"cmd":"hello","model":"...","serial":"...","proto":1}` | `{"action":"hello","params":{"model":"...","serial":"...","proto":1}}` |
| `{"cmd":"gcode","lines":[...],"compensation":"firmware"}` | `{"action":"gcode","params":{"lines":[...],"compensation":"firmware"}}` |
| `{"cmd":"job","action":"prepare","gcodeUrl":"http://...","compensation":"firmware"}` | `{"action":"job","params":{"action":"prepare","gcodeUrl":"...","compensation":"firmware"}}` |

**状态 / 通知 / 遥测**：wire payload 直接等于 App 内部扁平对象。收到后把 `payload` 传给业务层即可。

> 设计理由：封套提供 `src/dst/seq/v`，支撑多设备路由、消息溯源、防重放、外网网关按 dst 校验、OTA 版本演进；App 内部保持扁平，业务/UI/模型零改动。

### 2.4 命令映射表（内部扁平 + wire payload）

| App 方法 | 内部 JSON | wire payload action | 固件 / 主控动作 |
|---|---|---|---|
| `jog(axis, distMm)` | `{"cmd":"jog","axis":"x","dist":1.0}` | `jog` | `G91 G0 X1.0` 或 Grbl 实时 `$J=G91 X1 Fxxx`；`dist` 带正负号；内部可选 `feed` 映射到 `params.feed` |
| `home()` | `{"cmd":"home"}` | `home` | `$H` 回机械原点（带锁机保护） |
| `setWorkZero(x,y,z)` | `{"cmd":"setWorkZero","x":0,"y":0,"z":0}` | `setWorkZero` | `G10 L20 P1 X0 Y0 Z0` |
| `startSpindle(rpm)` | `{"cmd":"spindle","rpm":12000}` | `spindle` | `M3 S12000`；`rpm=0` → `M5` |
| `stopSpindle()` | `{"cmd":"spindle","rpm":0}` | `spindle` | `M5` |
| `setAux(key, on)` | `{"cmd":"aux","key":"light","on":true}` | `aux` | `key` ∈ `light` / `laser` / `timelapse` / `fan`；自定义 `$` 或 M-code |
| `startJob()` | `{"cmd":"job","action":"start"}` | `job` | 触发机器执行已落盘的 G-code |
| `pauseJob()` | `{"cmd":"job","action":"pause"}` | `job` | 软暂停（保留坐标） |
| `resumeJob()` | `{"cmd":"job","action":"resume"}` | `job` | 继续 |
| `stopJob()` | `{"cmd":"job","action":"stop"}` | `job` | 软停止（抬刀 / 回安全位） |
| `confirm()` | `{"cmd":"confirm"}` | `confirm` | **仅供联调/演示**；正式形态为机身屏物理按钮，量产固件可忽略 |
| `updateToolMap(tools)` | `{"cmd":"toolMap","tools":[...]}` | `toolMap` | 下发 ATC 刀仓映射；固件四刀位传感器只校验在位 |
| `setLevelingPlan(...)` | `{"cmd":"leveling","mode":1,"cols":5,"rows":4}` | `leveling` | 下发调平网格方案；cols/rows 由 App 按云端模型尺寸算好 |
| `hello` | `{"cmd":"hello","model":"...","serial":"...","proto":1}` | `hello` | 连接建立后上报机型与唯一码 |

### 2.5 `notify` 事件格式（机器 → App）

App 必须订阅 `cnc/<deviceId>/notify`：

```json
{
  "type": "job_done",
  "taskId": "task-001",
  "msg": "加工完成"
}
```

常见 `type`：`job_done` / `alarm` / `error` / `tool_changed` / `confirm_required`（D9 等待机旁确认提示）。具体枚举由 MQTT 服务器侧契约 `docs/02/03/05/10/11` 与 `contract/topics.json` 维护，App 侧消费时未知 type 兜底显示 `msg`。

---

## 3. 状态广播 `statusStream`（机器 → App）

内部扁平 JSON Schema（wire payload 与此一致）：

```json
{
  "state": "idle",
  "pos":  { "x": 12.34, "y": 5.60, "z": -2.10 },
  "mpos": { "x": 12.34, "y": 5.60, "z": -2.10 },
  "rpm":  12000,
  "feed": 600,
  "progress": 0.42,
  "etaSec": 180,
  "msg": "ok",
  "scIndex": 3,
  "scTotal": 5,
  "download": 0.6,
  "awaitingConfirm": false,
  "aux": { "light": true, "laser": false, "timelapse": false, "fan": false },
  "tools": [
    { "index": 1, "name": "3.175平底刀", "material": "钨钢", "length": 30.0, "installed": true },
    { "index": 2, "name": "1.5球刀",    "material": "钨钢", "length": 22.0, "installed": true },
    { "index": 3, "name": "0.8尖刀",    "material": "硬质合金", "length": 25.0, "installed": true },
    { "index": 4, "name": "—", "installed": false }
  ]
}
```

字段说明：
- `state`：`idle` · `homing` · `busy` · `paused` · `alarm` · `disconnected`。
- `pos`：G54 工作坐标 (mm)。
- `mpos` / 别名 `mp`：机器坐标 (mm)。
- `rpm` / 别名 `spindle`：主轴转速 rpm；关闭时为 null。
- `feed`：mm/min；无进给时为 null。
- `progress` / 别名 `prog`：加工进度 0..1。
- `etaSec` / 别名 `eta`：预计剩余秒；无任务为 null。
- `scIndex` / `scTotal`：自检阶段进度（固件拥有）。**统一为 5 阶段**（见 §4.1）。
- `download`：G-code 文件下载进度 0..1；无下载任务为 null。
- `awaitingConfirm`：D9 是否正等待机旁物理确认。
- `aux`：增加 `fan` 字段；云端 WAN 可操作 light / fan / OTA。
- `tools`：ATC 刀仓（4 槽）。

---

## 4. 状态机 `MachineState`

枚举值（三方统一）：

`disconnected` · `idle` · `homing` · `busy` · `paused` · `alarm`

合法迁移：

```
idle ──home()──▶ homing ──▶ idle
idle ──job prepare──▶ download(progress) ──▶ ready ──startJob──▶ awaitingConfirm(标志位) ──物理确认──▶ busy
idle ──startJob──▶ busy ──pauseJob()──▶ paused ──resumeJob()──▶ busy
busy / paused ──stopJob()──▶ idle
busy ──(异常)──▶ alarm ──(复位)──▶ idle
任意 ──disconnect()──▶ disconnected
```

- `ready` 与 `awaitingConfirm` 是**标志位 / 子状态**，不是独立枚举。
- **自检不是独立态**：`busy` 状态下通过 `scIndex/scTotal` 表达进度。

### 4.1 自检流水线（固件拥有）

- `scTotal` 固定为 **5**，对应固件真实源码的 5 步：
  1. `pp_matched`（配对/门限检查）
  2. `pp_lev`（调平结果确认）
  3. `pp_tool`（刀仓/刀具确认）
  4. `pp_warm`（主轴预热）
  5. `pp_all`（全部就绪）
- 时序参考（固件当前实现）：`[1100, 3300, 1600, 1800, 900]` ms，合计约 8.7s。
- App **只渲染**，不自己计时；`scIndex >= scTotal` 后进入加工态（`progress` / `etaSec`）。

---

## 5. G-code 下发链路（D10：命令与文件分离）

**不变式**：App 永不持有 G-code。真实切片文件由云端经 LAN / MQTT **直推 MCU**。

标准流程：

```
① 电脑端/云端把 G-code 存到文件服务 → 得到可下载 URL（预签名）
② 下发 job prepare：{"cmd":"job","action":"prepare","gcodeUrl":"http://.../gcode/task-001","compensation":"firmware"}
③ 机器 HTTP 异步下载 → 广播 download 进度（0..1）→ 完成后 state=ready
④ 用户点 startJob → 机器广播 awaitingConfirm=true → 机身屏弹「确认加工」
⑤ 机旁物理按钮确认后，固件执行「自检(sc 0→5) → 加工(progress/eta)」，完成后 state=idle
```

- `compensation` 是**任务属性声明**（`host` 或 `firmware`），每次任务只有一个补偿方，防止重复叠加。
- `gcode` 帧保留为兼容/调试通道（小文件）：`{"cmd":"gcode","lines":[...],"compensation":"..."}`，机器收到后同样落盘存储，再走 ④⑤ 流程。
- 下载失败/校验失败：广播 `state=alarm` + `msg` 原因，可重发 `job prepare` 重试。

---

## 6. 设备唯一码与注册（D5/D7）

- `deviceId == serial == 机器唯一码`，三文档统一使用该值作为 MQTT 主题隔离与账号绑定依据。
- 连接建立后，机器主动发 `hello` 命令帧（见 §2.4）上报机型与唯一码。
- `sys/register` 是 broker 层 ACL 同步机制（admin/云端），与 `hello` 命令帧**互补互引**：
  - `hello` = 连接层身份声明；
  - `sys/register` = broker 层权限/ACL 同步。
- 绑定流：用户注册个人账户 → 手机/电脑输入或扫描机器唯一码 → 云端建立「账号 ↔ 机器」绑定 → 之后按唯一码进入该机器管理。一账号可挂多台，当前**单机连接**（切换即断开上一台）。

---

## 7. LAN / WAN 鉴权与白名单

`RealHardwareService.connect()` 判定：
- 手机与机器在**同一子网**（或连的是本地 MQTT broker）→ `isLocalLAN = true`（全功能）。
- 走公网 / 云端 MQTT → `false`（监视模式）。

**外网（WAN）允许的操作**：
- 监控（状态/遥测/日志查看）
- `pauseJob()` / `resumeJob()` / `stopJob()`
- `setAux(key, on)`：`light` / `fan`
- OTA 触发（白名单）

**外网禁止**：Jog、startJob、home、setWorkZero、spindle 起转等涉及运动/起转的操作。

---

## 8. CloudService REST 契约（App ↔ 云端）

| 方法 | 路径 | 返回 |
|---|---|---|
| `fetchMaterials()` | `GET /api/v1/materials` | `[MaterialSpec]` JSON |
| `getTaskById(id)` | `GET /api/v1/tasks/{id}` | `TaskMetadata` JSON |
| `getActiveTask()` | `GET /api/v1/tasks/active` | `TaskMetadata` JSON（可选） |
| `getInspiration(page)` | `GET /api/v1/library/inspiration?page=0` | `[LibraryItem]` JSON |
| `getMySpace()` | `GET /api/v1/library/mine` | `[LibraryItem]` JSON |
| `pushDiagnostics(log)` | `POST /api/v1/diagnostics` | `202 Accepted` |
| `pushTaskToMachine(taskId)` | `POST /api/v1/devices/{deviceId}/jobs` | `{"accepted":true,...}` |
| 电脑端上传任务 | `POST /api/v1/tasks` | `201 {"ok":true,"id":...}` |
| G-code 下载 | `GET /api/v1/gcode/{taskId}` | G-code 文本（预签名 URL） |

### MaterialSpec JSON

```json
{
  "key": "pine",
  "name": "松木",
  "visual": "wood",
  "swatch": "#D7B49E",
  "rpm": 10000,
  "feed": 1500,
  "plunge": 400,
  "toolIds": ["t_flat_3175", "t_ball_3175"],
  "note": "软木，进给可快；3.175 平底刀粗雕 + 3.175 球头刀浮雕"
}
```

> 材质参数表云端主表，三端（机身屏 / App / 网页）共用；App 拉取后本地缓存兜底离线。

---

## 9. 摄像头 RTSP

- 局域网 RTSP 直连端口以真机实测为准：**`rtsp://admin:abc123456@<ip>:554/11`**。
- 视频面不经 MQTT；本地预览 + 推腾讯云视频面。

---

## 10. 三方交付清单（Done 标准）

### APP 侧
- [ ] `RealHardwareService` 增加 MQTT 封套编解码层（`MqttFrameCodec`）：内部扁平 ↔ wire envelope 双向映射。
- [ ] 订阅 `cnc/<deviceId>/status` + `cnc/<deviceId>/notify`；可选订阅 `telemetry` / `log`。
- [ ] WAN 模式白名单补 `light` / `fan` / OTA。
- [ ] `MachineStatus` / 文档中 `scTotal` 默认值/示例改为 **5**。
- [ ] `config.dart` / 文档：1883 仅联调，生产 8883 TLS + 关匿名。
- [ ] 更新 `docs/PROTOCOL.md` 引用到本统一契约。

### MQTT 服务器侧
- [ ] 文档/设计稿中 `8080` → `8899`。
- [ ] RTSP `:81` → `:554`。
- [ ] Mosquitto 部署补齐 `mosquitto.conf` / `acl.conf` / `passwd`，避免默认开放配置与 EMQX 安全模型不一致。
- [ ] WebSocket 端口统一（推荐统一为 8083，或在文档中明确 EMQX/Mosquitto 差异）。
- [ ] 提供 `notify` / `telemetry` / `log` 的 payload schema 给 App 侧确认。

### 固件侧
- [ ] WiFi 连上后调用 `mqtt_client_start()`，真正启动 MQTT 客户端。
- [ ] `MQTT_BROKER_URI_DEFAULT` 指向部署的私有 broker（内网 `:1883` 或云端 `:8883` + 证书），不再默认 `broker.emqx.io`。
- [ ] MQTT 主题从 `grbl/command|status|log` 改为 `cnc/<deviceId>/cmd|status|notify|telemetry|log`，并订阅 `cnc/<deviceId>/cmd` + `cnc/broadcast/#`。
- [ ] 加身份：`screen-<deviceId>` + 密码；连云端走 TLS。
- [ ] `deviceId` / broker / 凭据存 NVS，可配置化，不写死。
- [ ] LAN TCP Server 按 **8899** 实现，解析 §2.4 命令帧，广播 §3 状态帧（含 `scIndex/scTotal=5`）。
- [ ] 文档措辞："ESP32-SX 主控" 改为 "ESP32-S3 屏幕 + STM32F407 主控"；澄清 407 跑 GRBL 还是自研协议。

---

## 附：历史版本对照

| 旧表述 | 统一后表述 |
|---|---|
| 局域网 `TCP:8080` | `TCP:8899` |
| MQTT 全局 `grbl/command` | `cnc/<deviceId>/cmd` |
| 自检 8 阶段 | 自检 5 阶段 |
| 状态 `run` / `selfcheck` | `busy` + `scIndex/scTotal` |
| 摄像头 RTSP `:81` | `:554` |
| 命令扁平上 wire | 内部扁平 + wire 封套映射 |

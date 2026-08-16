# alexcnc · 硬件 / 云端协议对接文档

> **⚠️ 已合并到终版契约**：`docs/三任务一致性终稿.md`。本文档保留面向固件同事的速查内容，**数值/命名冲突时请以终稿为准**。

> **阅读对象**：嵌入式 / 固件同事
> **目的**：告诉你 App（Flutter）侧预留了什么接口、期望你们（ESP32-S3 屏幕 + GRBL）按什么报文格式对接。
> **当前状态**：仓库里现在是 `MockHardwareService` / `MockCloudService`（纯内存模拟），UI 已全部跑通。你们只实现真实通信层，App 其余代码 **0 改动**。

---

## 0. 一句话流程

```
App  UI  ──调用──▶  HardwareService / CloudService（抽象接口）
                         │
         你们实现 ───────┤  RealHardwareService  （App ↔ ESP32，WiFi/TCP 或 MQTT）
                         └  RealCloudService     （App ↔ 云端，REST 或 MQTT）
                         │
                    providers.dart 第 11 / 23 行，把 Mock 换成 Real
```

---

## 1. 三大设计原则（对接时必须遵守）

1. **ESP32 是唯一真值源（SSOT）**
   App 不裁决坐标、刀仓、状态；它只监听 ESP32 广播的状态并渲染。所有 `MachineStatus` 由 MCU 产生。
2. **资产闭环：手机绝不持有真实 G-code**
   切片文件由云端经局域网 / MQTT **直接下推给 MCU**。App 只取：
   - 任务元数据 `TaskMetadata`（尺寸、材质建议等轻量字段）
   - 极小的 **2D 矢量渲染 JSON**（用于实时轨迹预览）
   App 永不下载 / 存储实体 G-code 文件。
3. **LAN / WAN 鉴权**
   手机与 ESP32 同 Wi-Fi → `isLocalLAN = true`（全功能：Jog、回零、开切）。
   手机走 4G/5G 公网 / 云端 MQTT → `isLocalLAN = false`（监视模式：锁死 Jog / 开切，仅留监控 + pause/resume/stop + light/fan + OTA）。

---

## 2. HardwareService 契约（App ↔ ESP32）

接口定义见 `lib/services/hardware_service.dart`。下面是每个方法期望的**出站命令**与对应的 **Grbl / 固件动作**。

### 2.1 传输架构（分阶段）

> 分两步走：**第一步先做局域网（LAN），第二步再上外网（WAN）**。两步**报文格式完全一致**，仅传输层不同，固件代码可平滑过渡。

#### 🟢 第一步（局域网，当前要做）：TCP:8899 直连

- **唯一控制 + 状态通道 = ESP32 本地 TCP Server，端口 `8899`**。App 作为 TCP Client 直连 `机器IP:8899`，长连接，双向收发。
- 报文：**换行分隔的 JSON 帧**（每条命令/状态以 `\n` 结尾），与 Grbl 风格逐行交互兼容。
- 命令帧（App→机器）与状态帧（机器→App）走**同一连接**。
- 断线 App 侧每 5s 重连；`disconnect()` 主动关闭不再重连。
- **不依赖任何 Broker / 云端 / 外网**。
- ESP32 侧用 **AsyncTCP Server**（非阻塞、单客户端串行帧即可），这是最低门槛、最易对齐的路径。
- 参考实现：`server/fake_firmware.py --tcp`（可直接照抄的服务端骨架）。

#### 🔵 第二步（外网，已实现）：云端 MQTT Broker 中继

- 主链路切换为**云端 MQTT Broker**（出厂即用、WAN 远程天然打通）：
  - 状态订阅：`cnc/<deviceId>/status`
  - 命令下发：`gw/<deviceId>/cmd`（**经网关白名单转发固件**，R2；非直发 `cnc/<deviceId>/cmd`）
  - 事件通知：`cnc/<deviceId>/notify`（job_done / alarm / confirm_required 等）
  - 遥测订阅：`cnc/<deviceId>/telemetry`（温度/转速/进给/坐标，QoS0 高频）
  - 网关回执：`gw/<deviceId>/ack`（白名单外命令回 E401，App 弹红色通知）
  - 生产端口：**8883 TLS** + 关匿名 + 私有 Broker 域名；**1883 仅本地联调**。
- ESP32 新增 **MQTT Client** 连同一 Broker；TCP:8899 局域网增强保留（同 Wi-Fi 时运动命令直发降抖动）。
- App 侧把 `RealHardwareService(cloudEnabled: true)` 即可启用，**命令/状态帧无需改动**；命令统一经 `_dispatch`：局域网 TCP 直连优先，未连 TCP 才走 `gw/` 网关。

#### 公共要求（两步都适用）

- 报文：**换行分隔的 JSON 帧**（每条以 `\n` 结尾）。`statusStream` 实时状态广播（约 5–10 Hz）。
- ESP32 双核可同时跑 MQTT Client + AsyncTCP Server + Grbl 解析 + 状态机（工业成熟组合，资源充足）。
- 报文字段见 §2.3，命令见 §2.2——**第一步请严格按此实现**。

### 2.2 命令映射表

| App 方法 | 出站 JSON | 固件 / Grbl 等价动作 |
|---|---|---|
| `jog(axis, distMm)` | `{"cmd":"jog","axis":"x","dist":1.0}` | `G91 G0 X1.0`（或 Grbl 实时 `$J=G91 X1 Fxxx`）；`dist` 带正负号 |
| `home()` | `{"cmd":"home"}` | `$H` 回机械原点（带锁机保护） |
| `setWorkZero(x,y,z)` | `{"cmd":"setWorkZero","x":0,"y":0,"z":0}` | `G10 L20 P1 X0 Y0 Z0`（写 G54 工件零点） |
| `startSpindle(rpm)` | `{"cmd":"spindle","rpm":12000}` | `M3 S12000`；`rpm=0` → `M5` |
| `stopSpindle()` | `{"cmd":"spindle","rpm":0}` | `M5` |
| `setAux(key, on)` | `{"cmd":"aux","key":"light","on":true}` | `key` ∈ `light`(机箱照明) / `laser`(红点激光) / `timelapse`(延时摄影) / `fan`（散热风扇）；自定义 `$` 或 M-code |
| `startJob()` | `{"cmd":"job","action":"start"}` | 触发 MCU 开始执行**已落盘（SD/Flash）的 G-code**（固件统一跑「物理确认 → 自检 → 加工」）。**App 不发 G-code**；文件经 D10 下载链路先落盘，动作经 D9 物理确认门禁 |
| `pauseJob()` | `{"cmd":"job","action":"pause"}` | 软暂停（保留坐标） |
| `resumeJob()` | `{"cmd":"job","action":"resume"}` | 继续 |
| `stopJob()` | `{"cmd":"job","action":"stop"}` | 软停止（抬刀 / 回安全位） |
| `confirm()`（D9，仅调试/演示用） | `{"cmd":"confirm"}` | 安全确认门禁。**正式形态为机身屏物理按钮**，由固件内部触发；此命令仅供联调模拟，量产固件可忽略 |
| `updateToolMap(tools)` | `{"cmd":"toolMap","tools":[{"index":1,"installed":true},{"index":2,"installed":false}]}` | 下发 ATC 刀仓映射（仅占用位；**具体哪把刀由 App 侧 updateToolMap 维护，固件四刀位传感器只校验在位**） |
| `setLevelingPlan(mode, cols, rows)` | `{"cmd":"leveling","mode":1,"cols":5,"rows":4}` | 下发调平网格方案；`mode`∈0/1/2（跳过/标准/精细），`cols/rows` 由 App 按**云端下发的模型尺寸**算好后填好发给机器；机器按此网格执行扫描 |
| `connect()` / `disconnect()` | 建立 / 断开 TCP | — |
| `getStatus()` | 拉取一次当前状态 | 返回单帧 status |

### 2.3 statusStream 状态广播（ESP32 → App）JSON Schema

字段与 `lib/models/machine_status.dart` 的 `MachineStatus` **完全一致**：

```json
{
  "state": "idle",            // idle | homing | busy | paused | alarm | disconnected
  "pos":  { "x": 12.34, "y": 5.60, "z": -2.10 },   // G54 工作坐标 (mm)
  "mpos": { "x": 12.34, "y": 5.60, "z": -2.10 },   // 机器坐标 (mm)；别名 "mp" 也接受
  "rpm":  12000,              // 主轴转速 rpm；关闭时为 null；别名 "spindle" 也接受
  "feed": 600,                // mm/min；无进给时为 null
  "progress": 0.42,           // 加工进度 0..1；别名 "prog" 也接受
  "etaSec": 180,              // 预计剩余秒；无任务为 null；别名 "eta" 也接受
  "msg": "ok",                // 可选状态描述
  "scIndex": 3,               // 自检阶段进度（固件拥有自检流水线）：当前第几阶段
  "scTotal": 5,               // 自检总阶段数（固件源码真值）；0 = 无/未上报
  "download": 0.6,            // D10 G-code 文件下载进度 0..1；无下载任务为 null
  "awaitingConfirm": true,    // D9 是否正等待机旁物理确认；false/null = 不等待
  "aux": { "light": true, "laser": false, "timelapse": false, "fan": false },
  "tools": [                  // ATC 刀仓（4 槽）
    { "index": 1, "name": "3.175平底刀", "material": "钨钢", "length": 30.0, "installed": true },
    { "index": 2, "name": "1.5球刀",    "material": "钨钢", "length": 22.0, "installed": true },
    { "index": 3, "name": "0.8尖刀",    "material": "硬质合金", "length": 25.0, "installed": true },
    { "index": 4, "name": "—", "installed": false }
  ]
}
```

> **自检流水线（决策②：固件拥有）**：`scIndex`/`scTotal` 由固件在 `startJob()` 后统一广播；App **只渲染**，不自己计时。`scTotal` 固定为 **5**，App 据此显示「自检中 3/5」并自动在 `scIndex>=scTotal` 后进入加工态。

### 2.4 G-code 下发链路（D10：命令与文件分离，HTTP 下载落盘）

> 资产闭环不变式：**App 永不持有 G-code**。2026-08-07 起（D10）：**MQTT/TCP 只传控制指令与
> 下载链接，不传文件本体**；G-code 一律经 **HTTP 下载（预签名 URL）** 异步落机器本地存储
> （SD/Flash）后执行，**不做流式/滴流传输**。

**标准流程（云端 / 局域网统一同一套）**：

```
① 电脑端/云端把 G-code 存到文件服务 → 得到可下载 URL（预签名）
② 下发 job 命令（带 gcodeUrl）：{"cmd":"job","action":"prepare","gcodeUrl":"http://.../gcode/task-001","compensation":"firmware"}
③ 机器收到后 HTTP 异步下载 → 广播 download 进度（0..1）→ 完成后 state=ready
④ 用户点开始 → 机器广播 awaitingConfirm=true → 机身屏弹「确认加工」→ 机旁物理按钮
⑤ 确认后固件执行「自检(sc 0→5) → 加工(progress/eta)」，完成后 state=idle
```

- **文件服务**：外网 = ② 的 G-code 托管（预签名 URL）；局域网 = `server.py` 提供
  `GET /api/v1/gcode/{taskId}` 端点（网关把文件传给它或直接上传）。
- **`gcode` 帧保留为兼容通道**（小文件/调试）：`{"cmd":"gcode","lines":[...],"compensation":"..."}`；
  机器收到后同样落盘存储，再走 ④⑤ 流程——**两种来源进入同一执行引擎**。
- 下载失败/校验失败：广播 `state=alarm` + `msg` 原因，可重发 `job prepare` 重试（建议支持断点续传，P2）。
- 内置 `SAMPLE_GCODE` 可直接跑通演示；真机接入时由切片服务产出真实 G-code。

### 2.5 MQTT 外网通道（第二步，**已实现，主外网链路**）

> 2026-08-15 落地：外网命令经**网关白名单** `gw/<deviceId>/cmd` 转发固件（R2），
> 状态/事件仍由固件直发 `cnc/<deviceId>/*`；App 在线态经 LWT 声明。第一步请用 §2.1「TCP:8899 直连」实现。

**主题清单（App 视角，username = app-demo 经 ACL 授权）：**

| 方向 | 主题 | 用途 |
|---|---|---|
| 订阅 | `cnc/<deviceId>/status` | 固件状态帧（SSOT） |
| 订阅 | `cnc/<deviceId>/notify` | 事件（job_done / alarm / confirm_required 等） |
| 订阅 | `cnc/<deviceId>/telemetry` | 遥测帧（温度/转速/进给/坐标，QoS0 高频，R13） |
| 订阅 | `cnc/broadcast/msg` | 系统级业务广播（docs/03 §6：`{level,title,body,target}`，维护通知/警告/紧急） |
| 订阅 | `cnc/broadcast/system` | 系统级事件广播（docs/03 §7：`{event,deviceId,ts}`，如 `device_offline`） |
| 订阅 | `gw/<deviceId>/ack` | 网关命令回执；白名单外命令回 `{"ok":false,"code":"E401"}` |
| 发布 | `gw/<deviceId>/cmd` | 命令经网关白名单转发固件（R2）；局域网内 TCP 直连优先、未连 TCP 才走此 |
| 发布 | `cnc/<deviceId>/app` | App 在线态：连接时发 `{"online":true}` retain；异常断线 Broker 代发 LWT `{"online":false}` retain |

- 生产端口：**8883 TLS**；本地联调可用 **1883**。
- 命令帧 `gw/<deviceId>/cmd` 格式与 §2.2 完全一致（含 `gcodeUrl` 下载链接，**MQTT 不传文件本体**）。
- 网关对 `gw/<deviceId>/cmd` 按设备白名单放行（aux/pause 等安全命令）或拒绝（jog/hello 等运动类回 E401），拒绝时 App 弹红色通知。
- `hello` 心跳**仅走局域网 TCP**（不进 `gw/`，否则被 E401 拒绝并刷错误日志；外网靠 MQTT keepAlive 保活）。

### 2.6 设备唯一码与注册（D5/D7，机器始终在线模型）

> 机器经**机身屏配网**（屏幕搜索 WiFi → 输密码）连网后，向云端②注册并保持在线：
> - 第一步（局域网）：TCP 连接建立后 App 可选发 `hello` 拿机型/唯一码核对；
> - 第二步（外网）：机器 MQTT 连上②后**必须**先发 `hello` 注册（唯一码即设备身份，②据此鉴权）。

```json
// 机器 → App/②（连接建立后上报机型与唯一码）
{"cmd": "hello", "model": "LY_3020_2.0", "serial": "<机器唯一码>", "proto": 1}
```

**绑定流（D5/D6）**：用户注册个人账户 → 手机/电脑**输入或扫描机器唯一码** → ② 建立「账号 ↔ 机器」绑定
→ 之后按唯一码选择进入该机器管理。一账号可挂多台，当前**单机连接**（切换即断开上一台）。

### 2.7 任务补偿与调平结果回传（D8，双 G-code 生产路径）

> 语义：**每次任务只有一个补偿方（二选一）**——`compensation` 是**任务属性声明**，让机器知道
> "这段 G-code 是否已补偿过"，防止不知道而**重复叠加（过补偿）**。两条路径调平算法同一套（D2），
> 标记只决定谁执行、不改变怎么算。详见《三端双云-系统交互梳理说明书》§4.6。

**补偿标记（下发任务时可选，默认 `firmware`）**：

```json
// 路径一：上位机已重写 Z 的 G-code（机器按行执行，不再补偿）
{"cmd": "gcode", "lines": ["G21", "G90", "G1 Z-1 F200", "..."], "compensation": "host"}

// 路径二：云端下发原始 G-code（固件做网格实时补偿）
{"cmd": "gcode", "lines": ["G21", "G90", "..."], "compensation": "firmware"}
```

**调平结果回传（路径一：机器 → 上位机）**：

```json
{"cmd": "levelingResult", "taskId": "pc-task-1", "cols": 3, "rows": 2,
 "spacingMm": 50, "grid": [[0.0, 0.1, 0.05], [0.2, 0.15, 0.1]]}
```

- 机器执行完 `setLevelingPlan` 网格探测后，把每个点的 Z 偏差填入 `grid`（行为序，行优先）回传；
- 上位机据此重算补偿 G-code（compensation=host）再下发；`compensation=firmware` 时固件自留网格，不依赖回传。

### 2.8 物理安全确认（D9，任何任务/动作的门禁）

> 语义：凡涉及**主轴起转**或**坐标大范围移动**的动作（含任务开始前的回零/移刀/起转），机器
> 必须先在**机身屏弹出高优先级「确认加工」界面**，用户**机旁按物理按钮**确认后才执行；
> 未确认则保持 `awaitingConfirm=true` 待命，不产生任何运动/起转。与 D3"远程功能参数无需
> 屏上确认"并存——这是不可绕过的安全联锁。

**状态与触发**：

```jsonc
// 机器广播（等待确认中）
{ "state": "idle", "awaitingConfirm": true, "msg": "请在机身屏确认加工" }
// 用户按下物理按钮后（固件内部确认，无需网络命令）
{ "state": "busy", "awaitingConfirm": false, "scIndex": 0, "scTotal": 5 }
```

- **触发时机**：`startJob` 后进入实际运动前（回零/移刀/主轴起转之前）；P2 可扩展为「jog 单次
  大位移（如 >10mm）」或「暂停后长时间恢复」再次触发。
- **确认载体**：**物理按钮**（硬件形态待产品确认，建议实体键 + 长按 2s 防误触）；固件在按钮
  事件中内部置位，**不应依赖网络 `confirm` 命令**（`confirm` 命令仅供联调模拟，量产忽略）。
- **超时策略**：未确认无限等待；用户可在机身屏取消（回到 idle）。
- **App/电脑端表现**：收到 `awaitingConfirm=true` 时显示「等待机旁确认」并禁用「开始」，不替用户确认。

---

## 3. CloudService 契约（App ↔ 云端）

接口定义见 `lib/services/cloud_service.dart`。

### 3.1 REST 接口

| 方法 | 路径 | 返回 |
|---|---|---|
| `fetchMaterials()` | `GET /api/v1/materials` | `[MaterialSpec]` JSON（云端主表，见决策⑦）|
| `getTaskById(id)` | `GET /api/v1/tasks/{id}` | `TaskMetadata` JSON |
| `getActiveTask()` | `GET /api/v1/tasks/active` | `TaskMetadata` JSON（可选） |
| `getInspiration(page)` | `GET /api/v1/library/inspiration?page=0` | `[LibraryItem]` JSON |
| `getMySpace()` | `GET /api/v1/library/mine` | `[LibraryItem]` JSON（含电脑端上传任务，方案 A/S2） |
| `pushDiagnostics(log)` | `POST /api/v1/diagnostics` | `202 Accepted` |
| `pushTaskToMachine(taskId)` | `POST /api/v1/devices/{deviceId}/jobs` | `{"accepted":true,...}`（云端把 G-code 存为文件，返回 `gcodeUrl` 预签名下载链接，App 不持有）|
| **电脑端上传任务（新）** | `POST /api/v1/tasks` | `201 {"ok":true,"id":...}`（ArtiMaker 上传生成的任务，body=TaskMetadata JSON + 可选 `gcode`/`thumbnailUrl`；写入②后 App 图库「我的空间」可见） |
| **G-code 文件下载（新，D10）** | `GET /api/v1/gcode/{taskId}` | 机器 HTTP 拉取 G-code 文本（预签名 URL 即指此端点；局域网 server.py 已支持，外网②同构） |

> **电脑端对接示例（方案 A / S2，`server.py` 已支持）**：
> ```bash
> curl -X POST http://192.168.1.22:8787/api/v1/tasks -H "content-type: application/json" -d '{
>   "id": "pc-task-1", "name": "电脑端设计的铭牌", "widthMm": 120, "heightMm": 60,
>   "depthMm": 2, "boardThicknessMm": 3, "recommendedSpindleRpm": 12000,
>   "recommendedFeedRate": 600, "defaultMaterialKey": "absdual",
>   "defaultToolId": "t_v60_3175",
>   "requiredTools": [{"toolId": "t_v60_3175", "role": "精雕/刻线"}],
>   "thumbnailUrl": "https://.../thumb.png",
>   "gcode": ["G21","G90","G1 X5 Y5 F600","M30"]
> }'
> # 之后 App「图库 → 我的空间」即可看到该任务；点开走向导，startJob 时②按此任务 G-code 推机器
> ```

#### MaterialSpec JSON（对应 `lib/data/material_db.dart`，云端主表）

> 决策⑦：一张参数表，三端（机身屏 / App / 网页）共用；App 拉取后本地缓存兜底离线。切片 G-code 里的真实加工参数同样来自云端，App 仅展示。

```json
{
  "key": "pine",
  "name": "松木",
  "visual": "wood",            // wood | plywood | acrylic | plastic | foam | leather | pcb | brass | bakelite | metal
  "swatch": "#D7B49E",         // 图标底色
  "rpm": 10000,
  "feed": 1500,
  "plunge": 400,
  "toolIds": ["t_flat_3175", "t_ball_3175"],
  "note": "软木，进给可快；3.175 平底刀粗雕 + 3.175 球头刀浮雕"
}
```

#### TaskMetadata JSON（对应 `lib/models/task_metadata.dart`）

```json
{
  "id": "task-001",
  "name": "胡桃木杯垫",
  "widthMm": 80,
  "heightMm": 80,
  "depthMm": 3,
  "boardThicknessMm": 8,
  "recommendedSpindleRpm": 12000,
  "recommendedFeedRate": 600,
  "thumbnailUrl": "https://..."
}
```

#### LibraryItem JSON（模型库条目，对应 `lib/models/library_item.dart`）

> 完整格式见 `docs/模型库数据格式与接口定义.md`；列表接口返回 P0 精简字段，
> 详情接口 `GET /api/v1/models/{id}` 返回全量（P0+P1+P2）。

```json
{
  "id": "mod-1001",
  "title": "复古木雕花纹板",
  "author": "ArtiMaker",
  "category": "木雕",
  "tags": ["浮雕", "国风", "入门"],
  "difficulty": "入门",
  "coverUrl": "https://cdn.example.com/mod-1001/cover.jpg",
  "imageUrls": ["https://cdn.example.com/mod-1001/1.jpg", "https://cdn.example.com/mod-1001/2.jpg"],
  "isPublic": true,
  "materialKey": "pine",
  "materialPreset": "松木",
  "toolId": "t_flat_3175",
  "requiredTools": [
    {"toolId": "t_flat_3175", "role": "粗雕/轮廓"},
    {"toolId": "t_v60_3175", "role": "精雕/刻线"}
  ],
  "widthMm": 145, "heightMm": 95, "depthMm": 3, "boardThicknessMm": 3,
  "duration": "38分钟", "durationSec": 2280,
  "gcodeStatus": "sliced",
  "isHero": false,
  "heroTag": null,
  "syncTime": null,
  "isHistory": false
}
```

> `isPublic=true` → 灵感共享库；`false` → 我的云端空间；`isHistory=true` → 成功加工记录（历史复用）。

### 3.2 渲染 JSON（2D 矢量，仅此，不给 G-code）

云端从 G-code 抽取极简矢量下发给 App，用于实时轨迹预览（控制台 / 向导 Step6）：

```json
{
  "units": "mm",
  "bounds": { "w": 300, "h": 200 },
  "paths": [
    { "type": "travel", "pts": [[20,20],[180,20]] },
    { "type": "cut",    "pts": [[180,20],[180,100],[60,100]] }
  ]
}
```

### 3.3 资产闭环（重申）

真实切片文件由云端经 LAN / MQTT **直推 MCU**，App 永不下载 / 存储实体 G-code。

---

## 4. LAN / WAN 鉴权逻辑

- `RealHardwareService.connect()` 时判定：
  - 手机与 ESP32 在**同一子网**（或连的是本地 MQTT broker）→ `isLocalLAN = true`（全功能）。
  - 走公网 / 云端 MQTT → `false`（监视模式）。
- App 据此在 UI **自动**锁死 Jog / 开切，仅留监控 + Stop / Pause。
- `isLocalLANProvider`（`lib/state/providers.dart`）由 `RealHardwareService` 在连接时更新；**开发期可用 App 顶部按钮手动切换**做测试。

---

## 5. 状态机 `MachineState`

枚举值（与 `lib/models/machine_status.dart` 一致）：
`disconnected` · `idle` · `homing` · `busy` · `paused` · `alarm`
（D9/D10 扩展：`ready` 表示 G-code 已落盘待执行；`awaitingConfirm` 作为状态帧标志位而非独立枚举）

合法迁移：

```
idle ──home()──▶ homing ──▶ idle
idle ──job prepare──▶ download(progress) ──▶ ready ──startJob──▶ awaitingConfirm(待物理确认) ──▶ busy
idle ──startJob──▶ busy ──pauseJob()──▶ paused ──resumeJob()──▶ busy
busy / paused ──stopJob()──▶ idle
busy ──(异常)──▶ alarm ──(复位)──▶ idle
任意 ──disconnect()──▶ disconnected
```

---

## 6. 示例交互

**Jog X+1mm（App → ESP32 → App）**

```jsonc
// App 发送
{ "cmd": "jog", "axis": "x", "dist": 1.0 }

// ESP32 广播（statusStream）
{ "state": "idle", "pos": { "x": 1.0, "y": 0.0, "z": 0.0 }, "mp": { "x": 1.0, "y": 0.0, "z": 0.0 },
  "spindle": null, "feed": null, "prog": 0, "eta": null, "aux": { "light": false, "laser": false, "timelapse": false },
  "tools": [ { "index": 1, "installed": true, "name": "3.175平底刀", "length": 30.0 } ] }
```

**开切（App 只发触发，G-code 由云端已在 MCU 队列）**

```jsonc
// App 发送
{ "cmd": "job", "action": "start" }

// ESP32 广播
{ "state": "busy", "pos": { "x": 1.0, "y": 0.5, "z": -1.2 }, "mp": { "x": 1.0, "y": 0.5, "z": -1.2 },
  "spindle": 12000, "feed": 600, "prog": 0.07, "eta": 168, "tools": [ ... ] }
```

---

## 7. 嵌入式交付清单（Done 标准）

### 第一步（局域网，先交付）
- [ ] ESP32 起 **AsyncTCP Server:8899**（`0.0.0.0`），按 §2.2 解析命令帧、按 §2.3 广播状态帧（含 `scIndex/scTotal` 自检）。
- [ ] 自检流水线：收到 `job start` 后 `scTotal=5`，固件自行推进 `scIndex 0→5`，再进 `progress` 加工；App 只读不计时。
- [ ] **D10 下载链路**：实现 HTTP 下载器 + SD/Flash 存储；支持 `job prepare{gcodeUrl}` → 下载 → 广播 `download` 进度 → `ready`；`gcode` 帧同样落盘进同一执行引擎。
- [ ] **D9 物理确认**：`ready` 后广播 `awaitingConfirm=true`；机身屏弹「确认加工」高优先级界面；物理按钮按下后进入 `busy`（自检→加工）；未确认保持待命、不运动不起转。
- [ ] 接收 `leveling` 帧并按网格执行扫描。
- [ ] 局域网联调：`server/fake_firmware.py --tcp` 可被 App 直连跑通 Jog / 回零 / 开切 / RTSP（见 `docs/本地联调指南.md`）。

### 第二步（外网，后续）
- [ ] `RealHardwareService(cloudEnabled:true)`：实现云端 MQTT Client，按 §2.5 主题通信（帧格式同第一步）。
- [ ] `RealCloudService implements CloudService`：实现 REST（或 MQTT），按 §3 接口与 JSON Schema。
- [ ] 联调：同 Wi-Fi 全功能；切 4G 后 App 自动变为监视模式（Jog / 开切锁死）。
- [ ] 把 `deviceId` 命名、端口号（默认 8899）与 App 侧对齐（如需改默认值，同步改 `RealHardwareService`）。

---

## 附：App 侧已预留的"假数据"清单（联调后可删）

- `lib/services/hardware_service_mock.dart`：内存模拟状态流，Jog / 主轴 / 开切都有状态翻转。
- `lib/services/cloud_service_mock.dart`：模拟任务元数据、灵感库、我的云端空间、历史记录。
- 向导 Step3 / 4 / 6 的传感器态、3020 底板、预检流水线、2D 轨迹均用 Mock 驱动，待真实数据接入即"活"。

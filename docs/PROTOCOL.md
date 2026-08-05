# alexcnc · 硬件 / 云端协议对接文档

> **阅读对象**：嵌入式 / 固件同事
> **目的**：告诉你 App（Flutter）侧预留了什么接口、期望你们（ESP32 固件 + 云端）按什么报文格式对接。
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
   手机走 4G/5G 公网 / 云端 MQTT → `isLocalLAN = false`（监视模式：锁死 Jog / 开切，仅留监控 + 软停 Stop / Pause）。

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

#### 🔵 第二步（外网，后续）：云端 MQTT Broker 中继

- 主链路切换为**云端 MQTT Broker**（出厂即用、WAN 远程天然打通）：
  - 状态订阅：`cnc/<deviceId>/status`
  - 命令下发：`cnc/<deviceId>/cmd`
  - App 默认连 `broker.emqx.io`（测试），量产后换成你们自有 Broker 域名。
- ESP32 新增 **MQTT Client** 连同一 Broker；TCP:8899 局域网增强保留（同 Wi-Fi 时运动命令直发降抖动）。
- App 侧把 `RealHardwareService(cloudEnabled: true)` 即可启用，**命令/状态帧无需改动**。

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
| `setAux(key, on)` | `{"cmd":"aux","key":"light","on":true}` | `key` ∈ `light`(机箱照明) / `laser`(红点激光) / `timelapse`(延时摄影)；自定义 `$` 或 M-code |
| `startJob()` | `{"cmd":"job","action":"start"}` | 触发 MCU 开始执行**云端已下发**的队列任务（固件统一跑「自检 → 加工」）。**App 不发 G-code** |
| `pauseJob()` | `{"cmd":"job","action":"pause"}` | 软暂停（保留坐标） |
| `resumeJob()` | `{"cmd":"job","action":"resume"}` | 继续 |
| `stopJob()` | `{"cmd":"job","action":"stop"}` | 软停止（抬刀 / 回安全位） |
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
  "scTotal": 8,               // 自检总阶段数；0 = 无/未上报
  "aux": { "light": true, "laser": false, "timelapse": false },
  "tools": [                  // ATC 刀仓（4 槽）
    { "index": 1, "name": "3.175平底刀", "material": "钨钢", "length": 30.0, "installed": true },
    { "index": 2, "name": "1.5球刀",    "material": "钨钢", "length": 22.0, "installed": true },
    { "index": 3, "name": "0.8尖刀",    "material": "硬质合金", "length": 25.0, "installed": true },
    { "index": 4, "name": "—", "installed": false }
  ]
}
```

> **自检流水线（决策②：固件拥有）**：`scIndex`/`scTotal` 由固件在 `startJob()` 后统一广播；App **只渲染**，不自己计时。App 据此显示「自检中 3/8」并自动在 `scIndex>=scTotal` 后进入加工态。

### 2.4 G-code 局域网推送（第一步）

> 资产闭环不变式：**App 永不持有 G-code**。第一步用 **PC 伴随服务 `server.py`** 充当模型库 + G-code 源。

- App 选好模型后调用 `pushTaskToMachine(taskId)` → `POST /api/v1/devices/{id}/jobs`。
- `server.py` 收到后把 G-code 经**局域网 TCP:8899** 以 `{"cmd":"gcode","lines":[...]}` 帧推给机器（见 `server.py` 的 `push_gcode_to_machine`）。
- 随后 App 发 `{"cmd":"job","action":"start"}`，机器（已缓冲 G-code）开始执行。
- 内置 `SAMPLE_GCODE` 可直接跑通演示；真机接入时由切片服务产出真实 G-code。

### 2.5 MQTT 备选（第二步，当前不做）

- 状态发布：`cnc/<deviceId>/status`
- 命令订阅：`cnc/<deviceId>/cmd`

payload 与上面 JSON 完全一致。第一步请用 §2.1「TCP:8899 直连」实现。

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
| `getMySpace()` | `GET /api/v1/library/mine` | `[LibraryItem]` JSON |
| `pushDiagnostics(log)` | `POST /api/v1/diagnostics` | `202 Accepted` |
| `pushTaskToMachine(taskId)` | `POST /api/v1/devices/{deviceId}/jobs` | `{"accepted":true,...}`（云端把切片 G-code 直推 MCU，App 不持有）|

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
  "toolIds": ["t_flat_3175", "t_ball_15"],
  "note": "软木，进给可快；3.175 平底刀粗雕 + 1.5 球头刀浮雕"
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

#### LibraryItem JSON（对应 `lib/models/library_item.dart`）

```json
{
  "id": "insp-1",
  "title": "赛博朋克发光铭牌",
  "author": "NeoCraft",
  "imageUrl": "https://...",
  "isPublic": true,
  "materialPreset": "双色亚克力",
  "category": "亚克力",
  "duration": "8分10秒",
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

合法迁移：

```
idle ──home()──▶ homing ──▶ idle
idle ──startJob()──▶ busy ──pauseJob()──▶ paused ──resumeJob()──▶ busy
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
- [ ] 自检流水线：收到 `job start` 后 `scTotal=8`，固件自行推进 `scIndex 0→8`，再进 `progress` 加工；App 只读不计时。
- [ ] 接收 `gcode` 帧并缓冲；`job start` 执行已缓冲的 G-code。
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

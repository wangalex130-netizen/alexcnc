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

### 2.1 传输建议

- **局域网**：ESP32 起一个 TCP 服务（建议端口 `8899`），App 以**换行分隔的 JSON 帧**通信（每条命令以 `\n` 结尾）。
- 也可用 **MQTT**（见 2.4）。两条路报文一致。
- `statusStream` 是实时状态广播（约 5–10 Hz）。

### 2.2 命令映射表

| App 方法 | 出站 JSON | 固件 / Grbl 等价动作 |
|---|---|---|
| `jog(axis, distMm)` | `{"cmd":"jog","axis":"x","dist":1.0}` | `G91 G0 X1.0`（或 Grbl 实时 `$J=G91 X1 Fxxx`）；`dist` 带正负号 |
| `home()` | `{"cmd":"home"}` | `$H` 回机械原点（带锁机保护） |
| `setWorkZero(x,y,z)` | `{"cmd":"setWorkZero","x":0,"y":0,"z":0}` | `G10 L20 P1 X0 Y0 Z0`（写 G54 工件零点） |
| `startSpindle(rpm)` | `{"cmd":"spindle","rpm":12000}` | `M3 S12000`；`rpm=0` → `M5` |
| `stopSpindle()` | `{"cmd":"spindle","rpm":0}` | `M5` |
| `setAux(key, on)` | `{"cmd":"aux","key":"light","on":true}` | `key` ∈ `light`(机箱照明) / `laser`(红点激光) / `timelapse`(延时摄影)；自定义 `$` 或 M-code |
| `startJob()` | `{"cmd":"job","action":"start"}` | 触发 MCU 开始执行**云端已下发**的队列任务。**App 不发 G-code** |
| `pauseJob()` | `{"cmd":"job","action":"pause"}` | 软暂停（保留坐标） |
| `resumeJob()` | `{"cmd":"job","action":"resume"}` | 继续 |
| `stopJob()` | `{"cmd":"job","action":"stop"}` | 软停止（抬刀 / 回安全位） |
| `updateToolMap(tools)` | `{"cmd":"toolMap","tools":[{"index":1,"installed":true,"name":"3.175平底刀","length":30.0}]}` | 下发 ATC 刀仓映射 |
| `connect()` / `disconnect()` | 建立 / 断开 TCP | — |
| `getStatus()` | 拉取一次当前状态 | 返回单帧 status |

### 2.3 statusStream 状态广播（ESP32 → App）JSON Schema

字段与 `lib/models/machine_status.dart` 的 `MachineStatus` **完全一致**：

```json
{
  "state": "idle",            // idle | homing | busy | paused | alarm | disconnected
  "pos":  { "x": 12.34, "y": 5.60, "z": -2.10 },   // G54 工作坐标 (mm)
  "mp":   { "x": 12.34, "y": 5.60, "z": -2.10 },   // 机器坐标 (mm)
  "spindle": 12000,           // rpm；主轴关闭时为 null
  "feed": 600,                // mm/min；无进给时为 null
  "prog": 0.42,               // 加工进度 0..1
  "eta": 180,                 // 预计剩余秒；无任务为 null
  "msg": "ok",                // 可选状态描述
  "aux": { "light": true, "laser": false, "timelapse": false },
  "tools": [                  // ATC 刀仓（4 槽）
    { "index": 1, "name": "3.175平底刀", "material": "钨钢", "length": 30.0, "installed": true },
    { "index": 2, "name": "1.5球刀",    "material": "钨钢", "length": 22.0, "installed": true },
    { "index": 3, "name": "0.8尖刀",    "material": "硬质合金", "length": 25.0, "installed": true },
    { "index": 4, "name": "—", "installed": false }
  ]
}
```

### 2.4 MQTT 备选

- 状态发布：`cnc/<deviceId>/status`
- 命令订阅：`cnc/<deviceId>/cmd`

payload 与上面 JSON 完全一致。

---

## 3. CloudService 契约（App ↔ 云端）

接口定义见 `lib/services/cloud_service.dart`。

### 3.1 REST 接口

| 方法 | 路径 | 返回 |
|---|---|---|
| `getTaskById(id)` | `GET /api/tasks/{id}` | `TaskMetadata` JSON |
| `getActiveTask()` | `GET /api/tasks/active` | `TaskMetadata` JSON（可选） |
| `getInspiration(page)` | `GET /api/library/inspiration?page=0` | `[LibraryItem]` JSON |
| `getMySpace()` | `GET /api/library/mine` | `[LibraryItem]` JSON |
| `pushDiagnostics(log)` | `POST /api/diagnostics` | `202 Accepted` |

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

- [ ] `RealHardwareService implements HardwareService`：实现 WiFi / TCP（或 MQTT）通信，按 §2.2 命令、§2.3 状态广播。
- [ ] `RealCloudService implements CloudService`：实现 REST（或 MQTT），按 §3 接口与 JSON Schema。
- [ ] `lib/state/providers.dart` 第 11 行、第 23 行把 `Mock*` 换成 `Real*`；App 编译通过、GitHub Actions 出 APK 可装。
- [ ] 联调：同 Wi-Fi 下 Jog / 回零 / 开切可用；切 4G 后 App 自动变为监视模式（Jog / 开切锁死）。
- [ ] 把本协议文档里 `cnc/<deviceId>` 的 `deviceId` 命名、端口号（默认 8899）与 App 侧对齐（如需改默认值，同步改 `RealHardwareService`）。

---

## 附：App 侧已预留的"假数据"清单（联调后可删）

- `lib/services/hardware_service_mock.dart`：内存模拟状态流，Jog / 主轴 / 开切都有状态翻转。
- `lib/services/cloud_service_mock.dart`：模拟任务元数据、灵感库、我的云端空间、历史记录。
- 向导 Step3 / 4 / 6 的传感器态、3020 底板、预检流水线、2D 轨迹均用 Mock 驱动，待真实数据接入即"活"。

# alexcnc 推送通知系统 · 详细工程实施方案（新手工程师版）

> 版本：v2 详细实施方案 · 2026-09-09
> 读者对象：**刚接手、不了解项目背景的工程师**。本文自包含，不需要先读其他文档也能开工。
> 关联权威契约（细节以这些为准）：`docs/43`(屏幕/固件契约与防坑) · `docs/50`(雕刻历史接口) · `docs/52`(G-code 访问) · `docs/53`(推送寻址与权限) · `docs/B阶段-推送后端接口契约.md`(个推通道)
> 适用范围：屏幕固件 / PC 端 / 云端(阿里云 API) / App(Flutter) 四端
> 不在范围：① 断刀检测 / YOLO 火焰视觉（纯研究，不进推送清单）；② 维护提醒（维护方案未定，以后再做）

---

## 0. 决策速览（给负责人的一句话版）

- **App 是"监控兜底"不是"控制通知器"**：客户在 PC 或 App 自身流程上操作时，手机不被控制类事件刷屏；只有客户**离开后**才需要知道的结果与危险才推。
- **只推结果与危险**：雕刻完成、雕刻失败/异常、急停/防护门/限位（安全类强制不可关）。
- **控制类事件永不推送**：G-code 就绪、加工开始、物理确认、进度里程碑——两端（App 发起 / PC 发起）都不推。
- **物理确认(`awaitingConfirm`)**：仅 App 内横幅、不推送、可关（它不是危险，是闸门）。
- **寻址 100% 在云端**：设备/PC 只产数据，绝不判断"发给谁"；个推只当通道，按 `alias=userId` 下发。
- 详细矩阵、协议、各端代码级 TODO 见下文。

---

## 1. 系统架构总览（先看这张图）

```
┌─────────────┐       ┌──────────────┐       ┌──────────────────────┐
│  手机 App    │       │  PC 客户端    │       │  屏幕固件 (ESP32-S3)   │
│ (Flutter)   │       │ (Win / Mac)  │       │  480x272 LCD + 配网    │
│ 监控+控制+通知│       │ 发起雕刻      │       │ 驱动 GRBL MCU (主控)   │
└──────┬──────┘       └──────┬───────┘       └───────────┬──────────┘
       │                     │                          │ UART (GRBL $J/G/S + 换行)
       │ REST / MQTT         │ REST                     │
       │                     │                          ▼
       │                     │                  ┌──────────────────┐
       │                     │                  │  GRBL MCU (雕刻机) │
       ▼                     ▼                  └──────────────────┘
┌──────────────────────────────────────────────────────────┐
│              云端后端 (阿里云 API, 业务层)                   │
│  账号 / 机器绑定 / 在线模型库 / 雕刻历史 / 推送网关 / 个推凭据  │
└───────────────┬───────────────────────────────┬──────────┘
                │ MQTT 5.0                       │ REST (G-code 预签名等)
                ▼                                ▼
        ┌───────────────┐                ┌─────────────────┐
        │  EMQX Broker   │◀─────── RTSP/MJPEG ───────▶│  摄像头 (ESP32)   │
        │  (腾讯云部署)   │                └─────────────────┘
        └───────┬───────┘                        │
                │ 个推下行(离线)                   │ 推流
                ▼                                ▼
        ┌───────────────┐                ┌─────────────────┐
        │  个推 GeTui    │                │  Relay 中继       │
        │ (离线推送通道)  │                │ (RTSP → HLS)     │
        └───────┬───────┘                └─────────┬────────┘
                │                                   │
                ▼                                   ▼
         手机 App (离线通知)                    手机 App (实时视频 HLS)
```

### 1.1 各组件职责（你只需要知道这些）

| 组件 | 是什么 | 在推送里做什么 |
|---|---|---|
| **手机 App** | Flutter 写的安卓/iOS 客户端 | 管理个推 CID 生命周期、本地弹通知、显示偏好开关；**也是 PC 雕刻时的"监控兜底"**（客户关了 PC 后掏出 App 看实时图+状态） |
| **PC 客户端** | Windows/Mac 桌面软件 | 发起雕刻（自生成刀路直驱 或 调云端 G-code）；**只上报任务、不发通知** |
| **屏幕固件** | 机器上的 ESP32-S3（带屏） | 真正主控：把 GRBL MCU 状态打包成 MQTT 状态帧广播出去；产生 `notify` 事件 |
| **GRBL MCU** | 雕刻机主控板 | 干活的地方；屏幕经 UART 用功能码(`$J`/`G`/`S`)+换行控制 |
| **云端后端** | 阿里云上的 REST API | **推送的大脑**：维护账号↔机器绑定、消费 MQTT 事件、按规则调个推下发 |
| **EMQX Broker** | 腾讯云托管的 MQTT 5.0 服务 | 设备↔云↔App 的实时消息总线 |
| **个推 GeTui** | 第三方推送通道 | 只在 App **离线/杀进程**时兜底送达；在线时走 MQTT 不用它 |
| **Relay 中继** | 视频转发服务 | 摄像头 RTSP/MJPEG → 转 HLS，App 拉流看实时监控（与推送并列的"监控"通道） |

### 1.2 三条数据流（理解"为什么这样设计"）

1. **控制流**：App/PC → 云端 REST → MQTT `cnc/<deviceId>/cmd` → 屏幕 → GRBL。
2. **状态流（推送的数据源）**：GRBL/屏幕 → MQTT `cnc/<deviceId>/status` + `cnc/<deviceId>/notify` → 云端消费 → 在线则经 MQTT 回 App / 离线则经个推推 App。
3. **视频流（监控兜底）**：摄像头 → Relay → HLS → App 拉流。**这就是 PC 发起时 App 的正确角色**：客户关了 PC 后，打开 App 看实时画面，而不是等推送。

---

## 2. 通信方式与协议（新人必读）

### 2.1 MQTT 5.0（实时消息总线）

- **Broker**：EMQX（腾讯云）。设备/App 用 MQTT 5.0 连接。
- **主题命名空间**：`cnc/<deviceId>/...`，其中 `<deviceId>` 是**贯穿全系统的唯一设备码**（屏幕 ESP32 = 摄像头烧录 ID = 阿里云绑定主键，同一个字符串）。
- **关键主题**：

  | 主题 | 方向 | 用途 | 必读细节 |
  |---|---|---|---|
  | `cnc/<deviceId>/status` | 设备→云/App | 状态帧（JSON） | **LWT 也挂这个主题**，载荷 `{"state":"disconnected"}`，QoS1+retain；⚠️ 不能发纯字符串 |
  | `cnc/<deviceId>/notify` | 设备→云 | 事件通知（`job_done`/`alarm`/`canceled`） | 云端据此回写历史+触发推送 |
  | `cnc/<deviceId>/cmd` | 云/App→设备 | 下行指令 | 同一主题混 3 种帧，靠字段区分（见下） |
  | `cnc/broadcast/#` | — | 广播 | 屏幕订阅，收到要处理否则取消订阅 |

- **同一 `cnc/<deviceId>/cmd` 上有三种帧，必须按字段精确匹配**（来自 `docs/43` B7）：
  - `{"cmd":"jog",...}` → 机器指令，处理；
  - `{"action":"stream_start"}` → **摄像头指令，屏幕必须忽略**；
  - `{"cmd":"hello"}` → 心跳，**只更新在线状态，不得触发任何运动/复位**。
  - ⚠️ 用字段精确匹配，不要用子串搜索（`strstr`）——历史上因此误触发。

- **MQTT 5.0 User Properties**（用于链路追踪/路由）：`src` / `dst` / `seq` / `v` / `ts`。
- **授权准则**（`docs/43` A3）：能自动触发的节点（中继/自愈）不给权限；由人触发的（App/屏幕按钮/云网关响应用户操作）可以给。**cnc-relay 禁用；云网关允许但禁止自动重发。**

### 2.2 REST API（阿里云业务层）

- **Base URL**：`CLOUD_BASE_URL`（测试环境地址待定；App 当前用运行时开关 `USE_REAL_BACKEND` + `CLOUD_BASE_URL` 切换，未写死）。
- **鉴权**：`Authorization: Bearer <token>`，登录后云端据 token 推导 `accountId`（= userId）。
- **与本功能相关的端点**（现有/待建）：

  | 方法 | 路径 | 用途 | 状态 |
  |---|---|---|---|
  | POST | `/api/v1/push/device` | App 上报个推 CID + 偏好开关 | **待建**（B阶段 §2.1） |
  | POST | `/api/v1/push/unbind` | 登出/切账号解绑 CID | **待建**（B阶段 §2.2） |
  | GET | `/api/v1/push/online?userId=` | 查询用户是否在线（可选增强） | 待建 |
  | GET | `/api/v1/push/log` | App 启动/切前台兜底拉取（去重） | 待建 |
  | POST | `/api/v1/tasks` | **PC 发起**时登记 `JobRecord(source="pc")` | 待建/对齐 |
  | GET | `/api/v1/devices/{deviceId}/jobs` | 雕刻历史列表 | 待建（docs/50 §3.1） |
  | DELETE | `/api/v1/devices/{deviceId}/jobs/{taskId}` | 删除历史（软删） | 待建（docs/50 §3.5） |
  | POST | `/api/v1/devices/{deviceId}/jobs` | App 发起雕刻（落库起点） | 部分存在 |

### 2.3 状态帧 JSON 契约（推送的数据源，来自 `docs/43`）

屏幕每个状态变化都发一帧到 `cnc/<deviceId>/status`。**字段名/枚举错了 App 会静默失真、极难排查**，固件务必照此：

```json
{
  "state": "busy",            // 6 枚举之一（见下），唯一安全闸门
  "rpm": 12000,               // 主轴转速（数值）
  "spindle": true,            // 主轴是否运转（布尔）—— 与 rpm 同发，二选一会丢数据
  "progress": 0.42,           // 进度，必须 0..1（发 0..100 会被 clamp 成 1，进度条瞬间满）
  "awaitingConfirm": false,   // 机旁物理确认待处理（置 true → App 弹防呆横幅）
  "alarm_code": 0,            // 下划线命名！不是 alarmCode
  "grbl_online": true,        // 下划线命名！GRBL 掉线置 false
  "job": "logo.nc",           // 当前加工文件名（空闲为 null）
  "download": 0,              // 下载进度 0..1（当前 App 未消费，预留）
  "scTotal": 0,               // 自检总数：仅自检期发 5，否则发 0（常驻会卡死自检）
  "scIndex": -1,              // 自检进度
  "error": null               // 报警原因字符串，或 {"msg":"","code":""}
}
```

**`state` 6 枚举（只能发这 6 个）**：`disconnected` | `idle` | `homing` | `busy` | `paused` | `alarm`
- ⚠️ 协议文档状态机里的 `download`/`ready` **不在枚举内**，发了会被静默回落成 `idle` → App 的 Jog 安全闸门(`canControl => state==idle`)被错误解锁。**下载进度用 `download` 字段，就绪用 `awaitingConfirm`，绝不发 `download`/`ready` 作为 state。**
- ⚠️ 网络断连发 `disconnected`，**不要**回落成 `idle`（否则离线显示成在线、Jog 被误解锁）。

### 2.4 `notify` 事件（历史回写 + 推送触发源）

屏幕在关键节点发到 `cnc/<deviceId>/notify`（最小必要字段，具体字段对齐 `PROTOCOL.md` §10.7 / `docs/50` §4.2）：

```json
{ "type": "job_done",  "taskId": "task-001", "status": "done",     "ts": 1757117400000 }
{ "type": "alarm",     "taskId": "task-001", "alarmCode": "E_STOP", "ts": 1757117500000 }
{ "type": "canceled",  "taskId": "task-001", "status": "canceled", "ts": 1757117600000 }
```
云端消费：① 回写 `jobs` 表（status/finishedAt/durationSec）；② 触发对应推送事件。

### 2.5 G-code 访问模型（来自 `docs/52`）

- **App 永不持有 G-code**：只从云端模型库下载预签名链接(`gcodeUrl`)，HTTP 下载落盘后执行。
- 双路径补偿：本地设计→上位机(`compensation:host`) / 云端模型库(`compensation:firmware`)，**每次任务只能一个补偿方**，重复补偿废工件。
- PC 端从云库调用时，需把 G-code 上传云（生成 `gcodeUrl`）。

### 2.6 个推 GeTui（离线推送通道）

- SDK：`getuiflut`（Flutter 侧已集成）。
- **服务端**：用主 App 独立应用凭据（**AppID `2BrsBCR7hU9a1COnJw8P87`** / AppKey / MasterSecret）调个推 REST API。
- **寻址主键 = `alias = userId`（accountId），不是 CID**。CID 是「设备×安装」级，重装 App 会变（已实测证实），拿 CID 当业务标识会永久失联。
- **离线通道硬前提**：自分发 APK 杀进程后无系统通道 → 需上架**小米/OPPO/vivo/华为商店**启用厂商通道；海外走 **FCM**（Google Play 专版 `com.getui:sdk-for-gj`）。
- ⚠️ 推送**文案禁止出现"个推"二字**（实测被服务端拦截）。

---

## 3. 推送功能设计（详细）

### 3.1 产品原则（为什么这样定）

客户用 PC 发起雕刻 → 他看 PC 信息、在机器旁交互，**不需要手机参与、也不会去翻手机通知**；但雕刻中他可能关了 PC，这时才掏出 App 看实时监控。所以：
- **PC 发起**：手机只作监控兜底（拉取式），**仅结果(完成)与危险(异常)推送**。
- **App 发起**：手机是发起界面，客户点完"确认雕刻"需走到机器按确认 → 此时 App 弹**横幅**提醒（非推送），雕刻中也只推结果/危险。
- 通用：**控制类事件（下载完成/开始/确认/进度）永不推送**——客户正盯着发起界面。

### 3.2 事件总表（14 类，后端只差接线）

| # | `extras.event` | 含义 | 数据来源 | 推送？ | 开关档 | 强制 |
|---|---|---|---|---|---|---|
| 1 | `complete` | 雕刻完成 | `notify` `job_done` / `jobs.status→done` | ✅ 两端 | 完成类 | 否 |
| 2 | `failed` | 雕刻失败/取消 | `notify` `canceled` / `jobs.status→failed/canceled` | ✅ 两端 | 告警类 | 否 |
| 3 | `alert` | 加工告警(通用) | 状态帧 `alarm_code`/`error` | ✅ 两端 | 告警类 | 否 |
| 4 | `safety` | 急停/防护门/限位 | 状态帧 `alarm_code` 高危子类 | ✅ 两端 | **安全类** | **是(不可关)** |
| 5 | `gcode_ready` | G-code 下载/就绪 | `gcodeUrl` 生成 / `download` | ❌ 两端不推 | — | — |
| 6 | `start` | 加工开始 | `state` `idle→busy` 边沿 | ❌ 两端不推 | — | — |
| 7 | `awaitingConfirm` | 物理确认待处理 | 状态帧 `awaitingConfirm=true` | ❌ 不推；App 发起仅横幅 | — | — |
| 8 | `progress` | 进度里程碑 | `progress` 阈值 | 🟡 默认关 | 完成类(可选) | 否 |
| 9 | `device_offline` | 机器离线 | LWT / `grbl_online=false`（防抖 2min） | ✅ | 设备类 | 否 |
| 10 | `device_online` | 机器上线 | CONNECT / LWT 清除（稳 30s） | ✅ | 设备类 | 否 |
| 11 | `bind_success` | 绑定成功 | `machine_owner` 插入 | ✅ | 运营类 | 否 |
| 12 | `unbind` | 解绑/转让 | `machine_owner` 删除（清历史） | ✅ | 运营类 | 否 |
| 13 | `new_login` | 新设备登录(账号安全) | `user_push_device` 新 cid 行 | ✅ | 运营类 | 否(建议默认开) |
| 14 | `announcement` | 系统公告 | 运营后台 | ✅ | 运营类 | 否 |

### 3.3 PC 发起 vs App 发起 推送矩阵

**PC 发起**（PC 是主控制台，人在机器旁）：

| 事件 | 推 App？ | 理由 |
|---|---|---|
| 物理按键确认 / G-code 下载完成 / 加工开始 / 进度 | ❌ 不推 | 人在 PC 与机器旁，推了是骚扰 |
| 雕刻完成 | ✅ | 客户可能已关 PC 离开 |
| 雕刻异常/失败 / 急停门限位 | ✅（safety 强制） | 客户可能已离开，危险必告 |

**App 发起**（手机是发起界面，需走到机器按确认）：

| 事件 | 推 App？ | 分类 | 理由 |
|---|---|---|---|
| G-code 下载完成 / 加工开始 | ❌ 不推 | — | 客户在 5 步流程里看着 |
| 物理确认待处理 | ⚠️ **仅 App 内横幅，不推送** | 非紧急闸门 | 走到机器按确认；非危险、不强制、可关 |
| 进度里程碑 | 🟡 默认关 | 进度 | 防刷屏 |
| 雕刻完成 | ✅ | 完成类 | 客户可能已离开 |
| 雕刻异常/失败 | ✅ | 告警类 | 客户可能已离开 |
| 急停/门/限位 | ✅（强制） | 安全类 | 真实危险 |

**对称结论**：两端推送集合完全一致 = `{complete, failed/alert, safety}`。唯一差异是 App 发起多一个 `awaitingConfirm` 的 App 内横幅。因此 `source` 字段对**推送过滤**影响很小（两端同过滤），其价值在：① 历史标"来自电脑端"；② 决定 `awaitingConfirm` 呈现方式。

### 3.4 推送数据流时序（重点看云端这一层）

```
[设备] 屏幕发 cnc/<deviceId>/status 或 /notify
   │  (MQTT)
   ▼
[EMQX] 转发给云端订阅者
   │
   ▼
[云端] 消费消息：
   1. 更新 jobs 表状态（完成/失败/告警）
   2. 判定 extras.event（complete/failed/alert/safety/device_offline...）
   3. 查 machine_owner 表 → ownerUserId（寻址 100% 在云端）
   4. 按 source + event 路由：
        - 控制类(gcode_ready/start/awaitingConfirm/progress) → 丢弃，不推
        - 设备/运营类 → 查用户该档开关，关则跳过
        - safety → 无视开关强制推
   5. 判在线/离线 + 防抖：
        - 离线满 2min 才推 device_offline；上线稳 30s 才推 device_online
        - 离线有效期 24h，过期不补（避免"三小时前的完成通知"）
   6. 调个推 push_by_alias(ownerUserId, title, body, extras)
   │  (个推 REST)
   ▼
[个推] 解析 alias → 该用户全部活跃 CID → 送达
   │
   ▼
[App] onNotificationMessageArrived 回调 → flutter_local_notifications 弹栏
      + 按 extras.event 路由样式 + safety 即使关也弹 + 点击跳对应页
```

> 若用户**在线**（App 在前台且 MQTT 连着），优先走 MQTT `cnc/<deviceId>/notify` 实时流，不走个推（避免双发）。在线判定用 `is_user_online` 或 MQTT 连接态。

### 3.5 `extras` 下发结构（云端↔App 必须一致）

```json
{
  "event": "complete",
  "deviceId": "cnc-001",
  "deviceName": "我的雕刻机",
  "taskId": "task-001",
  "modelName": "松木铭牌",
  "alarmCode": null,
  "confirmHint": null,
  "source": "pc"
}
```
字段说明：云端下发、App 解析须字段名一致；`source`(app/pc) 供 App 决定 `awaitingConfirm` 是否弹横幅。

### 3.6 5 档通知开关（原 B阶段 2 档 → 扩 5 档）

| 档位 | 含事件 | 强制送达 |
|---|---|---|
| 完成类 | `complete`、`progress`(默认关) | 可关 |
| 告警类 | `failed`、`alert` | 可关 |
| 安全类 | `safety`（急停/门/限位） | **强制不可关** |
| 设备类 | `device_offline`(防抖2min)、`device_online`(稳30s) | 可关 |
| 运营类 | `bind_success`、`unbind`、`new_login`(建议默认开)、`announcement` | 可关 |

> `awaitingConfirm` **不进开关**（App 内横幅，非推送）。开关字段名云端表与 App 上报须一致。

### 3.7 防抖与有效期

- 机器离线：收到 LWT / `grbl_online=false` 后**满 2 分钟**才推 `device_offline`（Wi-Fi 抖一下不误报）。
- 机器上线：稳定 **30 秒**才推 `device_online`。
- 离线消息**24h 有效期**，过期不补推。

---

## 3.8 固件升级通知：拉取式（非推送）· 2026-09-08 决策

> **重要更正**：固件可升级**不再走推送事件**（已从 §3.2 事件总表、§3.6 开关、§4.1 网关、`extras.event` 解析中移除 `firmware_update`）。

**产品决策（与工程师确认）**：
1. 阿里云已有固件升级接口（PC 工程师提供），新固件放在阿里云；**服务端不主动推送**「有新固件」给 App。
2. App 打开后**静默检查云端一次**（命中 `AppConfig.firmwareCheckUrl`，聚合接口返回 `{available,latest[]}`）。
3. 若有可升级固件，在「我的」页 **固件升级** 入口后显示**绿色小点**提示（见 App `fwUpdateAvailableProvider`）。
4. 用户点进固件升级页后，页面内 `_checkAll` 再次核对云端并回写绿点状态；可手动选择升级机器/摄像头固件。
5. **全程无推送弹窗**：App 离线或刚打开都不会弹出固件升级通知。

**App 端实现（已完成）**：
- `lib/state/firmware_update_provider.dart`：`FwUpdateNotifier` + `fwUpdateAvailableProvider`（bool），`build()` 时静默 `checkCloudUpdate()`。
- `lib/features/firmware/firmware_service.dart`：`checkCloudUpdate()` 命中 `FIRMWARE_CHECK_URL`（接口未提供时安全返回 false）。
- `lib/features/profile/profile_page.dart`：固件升级入口接 `_FwUpdateDot`（绿点），监听 `fwUpdateAvailableProvider`。
- `lib/features/firmware/firmware_page.dart`：`_checkAll` 完成后回写 `fwUpdateAvailableProvider`。
- `lib/app/app.dart`：挂载 `fwUpdateAvailableProvider` 触发 App 打开时一次性检查。

**待 PC 工程师提供**：`FIRMWARE_CHECK_URL` 指向的聚合接口（响应形如 `{available:true, latest:[{type,version,changelog}]}`）。接口就绪前绿点不显示，不影响现有功能。

## 4. 各端实施指南（给工程师的 TODO + 伪代码）

### 4.1 云端（工作量最大头）

#### 4.1.1 数据库表

**(a) `user_push_device`（B阶段 §1，扩 5 档开关）**

```sql
CREATE TABLE user_push_device (
    id            BIGINT AUTO_INCREMENT PRIMARY KEY,
    user_id       VARCHAR(64)  NOT NULL,        -- 业务用户（alias 寻址键）
    cid           VARCHAR(64)  NOT NULL,        -- 个推 ClientID（设备×安装唯一）
    platform      VARCHAR(16)  NOT NULL DEFAULT 'android',
    device_id     VARCHAR(64),                   -- 当前绑定机器（诊断用）
    notify_complete BOOLEAN NOT NULL DEFAULT TRUE,
    notify_alert    BOOLEAN NOT NULL DEFAULT TRUE,
    notify_safety   BOOLEAN NOT NULL DEFAULT TRUE,  -- 实际上强制，字段保留但恒 true
    notify_device   BOOLEAN NOT NULL DEFAULT TRUE,
    notify_ops      BOOLEAN NOT NULL DEFAULT TRUE,
    is_active     BOOLEAN      NOT NULL DEFAULT TRUE,  -- 退出/切账号置 false
    last_active   DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    created_at    DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    updated_at    DATETIME(3)  NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
    UNIQUE KEY uk_user_cid (user_id, cid),
    KEY idx_user_active (user_id, is_active)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

**(b) `machine_owner`（绑定关系，寻址唯一数据源，docs/53）** — 已有则复用：`machine_id → owner_user_id`。解绑/转让须同步删此记录 + 清该账号在此机历史。

**(c) `jobs`（雕刻历史，docs/50）** — 字段见 §2.2/§3.2；`source` 必填。

**(d) `push_log`（兜底拉取，B阶段 §5）** — 云端写推送记录，App `GET /api/v1/push/log` 补拉去重（水位 `deliveredAt`）。

#### 4.1.2 REST 接口（B阶段 §2）

- `POST /api/v1/push/device`：body `{token(CID), deviceId, userId, platform, notifyComplete, notifyAlert, notifySafety, notifyDevice, notifyOps}` → UPSERT `user_push_device`（冲突 `(user_id,cid)` 更新并 `is_active=true`）；userId 非空可再调个推 `bindAlias` 幂等。
- `POST /api/v1/push/unbind`：body `{token, userId}` → `UPDATE ... SET is_active=false` + 个推 `unbindAlias`。
- `GET /api/v1/push/online?userId=`：返回 `{online, activeDevices, lastActive}`（可选增强）。
- `GET /api/v1/push/log`：返回该用户未读推送（App 启动/切前台补拉）。

#### 4.1.3 MQTT 消费（核心）

```python
# 订阅 cnc/+/status 与 cnc/+/notify（EMQX 通配）
def on_status(device_id, frame):
    # 1) 更新在线态（带防抖时间戳）
    update_device_online(device_id, frame.get("state") != "disconnected")
    # 2) 危险告警 → 直接触发 safety 事件
    if frame.get("alarm_code") in HIGH_RISK:   # E_STOP / DOOR / LIMIT ...
        emit_push(device_id, event="safety",
                  title="安全告警", body=f"机器触发{frame['alarm_code']}")
    # 3) 物理确认 → 仅记状态，不推（App 自己拉状态帧弹横幅）
    # 4) 加工开始边沿 idle->busy → 记日志，不推

def on_notify(device_id, msg):
    # 回写 jobs 表
    if msg["type"] == "job_done":
        update_job(msg["taskId"], status="done", finishedAt=msg["ts"])
        emit_push(device_id, event="complete", title="雕刻完成", body="任务已完成")
    elif msg["type"] == "alarm":
        update_job(msg["taskId"], status="failed")
        emit_push(device_id, event="alert", title="雕刻异常", body=msg.get("alarmCode"))
    elif msg["type"] == "canceled":
        update_job(msg["taskId"], status="canceled")
        emit_push(device_id, event="failed", title="雕刻已取消", body="")
```

#### 4.1.4 推送网关（路由 + 开关 + 安全强制 + 防抖）

```python
def emit_push(device_id, event, title, body, extras=None):
    owner = db.get("SELECT owner_user_id FROM machine_owner WHERE machine_id=?", device_id)
    if not owner:
        return  # 未绑定，无目标（符合隔离红线）
    user_id = owner["owner_user_id"]
    extras = {"event": event, "deviceId": device_id, **(extras or {})}

    # 控制类事件：两端都不推
    if event in ("gcode_ready", "start", "awaitingConfirm", "progress"):
        if event == "progress" and not switch_on(user_id, "notify_complete"):
            return
        # progress 默认关；其余控制类直接 return
        if event != "progress":
            return

    # 设备/运营类：查开关
    if event in ("device_offline", "device_online") and not switch_on(user_id, "notify_device"):
        return
    if event in ("bind_success", "unbind", "new_login", "announcement") \
       and not switch_on(user_id, "notify_ops"):
        return
    if event in ("complete",) and not switch_on(user_id, "notify_complete"):
        return
    if event in ("failed", "alert") and not switch_on(user_id, "notify_alert"):
        return
    # safety：无视开关，强制推

    # 防抖（设备类）
    if event == "device_offline" and not debounce_offline(device_id, gap=120):
        return
    if event == "device_online" and not debounce_online(device_id, gap=30):
        return

    # 下发：优先 alias（覆盖该用户全部设备）
    getui.push_by_alias(user_id, title, body, extras)
    # 写 push_log 供 App 兜底拉取
    db.insert("push_log", user_id=user_id, event=event, title=title, body=body, extras=extras)
```

#### 4.1.5 个推服务端集成（示例，凭据用主 App 独立应用）

```python
# 1) 取 token：POST https://restapi.getui.com/v2/{APP_ID}/auth
#    body: { "sign": "<sha256(APP_KEY+timestamp+MASTER_SECRET)>", "timestamp": ..., "appkey": APP_KEY }
#    返回 auth_token（2h 有效，缓存）
# 2) 推送：POST https://restapi.getui.com/v2/{APP_ID}/push/single/alias
#    header: token: <auth_token>
#    body: { "alias": user_id, "request": { "notification": {"title":..,"body":..},
#            "push_message": {"notification": {...}, "transmission": "<extras JSON>" } } }
# 注：实际字段以个推开放平台 REST 文档为准；本例给出寻址与 extras 透传结构。
APP_ID = "2BrsBCR7hU9a1COnJw8P87"   # 主 App 独立应用
```

#### 4.1.6 其余触发源

- **绑定成功/解绑**：`machine_owner` 表变更时触发 `bind_success` / `unbind`（解绑同步清该账号在此机 `jobs` 的 `deletedAt`）。
- **新设备登录**：`user_push_device` 出现该 `user_id` 的新 `cid` 行 → `new_login`。
- **系统公告**：运营后台 → `announcement`（全量或按账号）。

#### 4.1.7 在线/离线检测（防抖实现）

- 用 EMQX **webhook**（`client.connected` / `client.disconnected` 事件）或订阅 `$SYS/brokers/.../clients/<clientId>/connected`，更新 `device_online` 表 + 时间戳；网关据此做 2min/30s 防抖。
- 或：云端每次收到 `cnc/<deviceId>/status` 非 disconnected 帧即刷新 `last_seen`；超过阈值无帧则判离线（同样防抖）。

### 4.2 屏幕固件（ESP32）

**已有（契约级，照发即可）**：状态帧全字段 + `notify`(`job_done`/`alarm`/`canceled`) + LWT。
**需确认真落地（避免 App 静默失真）**：
1. `awaitingConfirm` 在机旁物理确认时置 `true`（`docs/43` C8，量产由机身屏按钮触发）。
2. `alarm_code`/`error` 在限位/仓盖/防护门/急停时填**具体子类值**（如 `E_STOP`/`DOOR`/`LIMIT`），供云端区分 `safety`。
3. `state` 真实流转（`idle→homing→busy→paused→alarm→disconnected`），云端靠 `idle→busy` 判开始、靠 `disconnected` 判离线。
4. 字段名严格：`alarm_code`/`grbl_online` 下划线；`progress` 0..1；`spindle`+`rpm` 同发；`scTotal` 仅自检期非 0。
5. **不为通知写任何新逻辑**——只产数据，寻址是云端的事。

### 4.3 PC 端

**已有**：能发起雕刻（自生成刀路直驱 或 调云端 G-code）。
**必须做**：
1. 发起即 `POST /api/v1/tasks` 登记 `JobRecord`：`{taskId(云端分配或自生成唯一), modelName, params, deviceId, source:"pc", gcode:null}`（`docs/50` §3.6）。**即使刀路本地生成也要登记**，否则云端无此任务、完成通知漏发。
2. 从云库调用时，把 G-code 上传云生成 `gcodeUrl`（`docs/52`）。
3. **自己不发任何 notify**；完成/异常由屏幕 `notify` 回写云端，云端按 source 路由。
**对齐**：与 App 共享同一 `jobs` 表、同一 `taskId` 规则 → App 历史页显"来自电脑端"（`source=pc`）。

### 4.4 App 端（Flutter）

**已有（真机验证 `f49bbc66`）**：个推 init/CID/隐私合规 + `alias=userId` 三处修复（登录补绑/登出解绑/重装自愈）+ 前台本地通知(`flutter_local_notifications`) + `POST_NOTIFICATIONS` 权限 + `push/log` 兜底 + `awaitingConfirm` 横幅。
**必须做**：
1. 偏好开关 UI：从 2 档扩 **5 档**（完成/告警/安全/设备/运营），上报字段名与云端 `user_push_device` 一致。
2. 解析新 `extras.event` 类型（`complete`/`failed`/`alert`/`safety`/`device_*`/`bind_*`/`new_login`/`announcement`）路由到对应本地通知样式。
3. **`safety` 类即使开关关也展示**（强制）。
4. 点击通知跳对应页（历史详情 / 机器页 / 设置）。
5. `awaitingConfirm`：App 发起时弹横幅"请到机器按下确认键"（已是横幅，确认不推送）。
6. 监控视图（实时图+状态）已通用，PC/App 发起都覆盖，**无需 source 分支**。
**对齐**：`extras`/字段名与云端一致；**文案禁出现"个推"二字**（实测被拦）。

---

## 5. 联调与验收清单

- [ ] 后端建 `user_push_device`(5 档) + `push_log`；`POST /api/v1/push/device` 幂等落库。
- [ ] `POST /api/v1/push/unbind` 置 `is_active=false`，切账号无串号。
- [ ] 推送网关按 `machineId → ownerUserId → alias` 寻址，不串号。
- [ ] 真机：登录后云端按 userId 推送可达；登出后不再达。
- [ ] 雕刻完成(complete) / 失败(failed) 两端都推；G-code 就绪/开始/确认/进度**都不推**。
- [ ] `safety`(急停) 即使关开关也推。
- [ ] 机器离线满 2min 才推、上线稳 30s 才推；24h 过期不补。
- [ ] PC 发起雕刻：`POST /api/v1/tasks`(source=pc) 后，完成出现在 App 历史 + 收到完成推送；物理确认/下载完成**无推送**。
- [ ] App 发起雕刻：点"确认雕刻"后 App 弹 `awaitingConfirm` 横幅（非推送）；完成收到推送。
- [ ] 单账号多设备(手机+平板)都收；已读云端同步。
- [ ] 厂商离线通道（上架商店）后，杀进程仍能收离线推送。

---

## 6. 前置依赖与非范围

- **个推企业实名认证未完成** → App `android/app/build.gradle.kts` 三行仍为 `TODO_GETUI_*`，后端不受阻（后端用 REST + 主 App 独立凭据 `2BrsBCR7hU9a1COnJw8P87`）。拿真实 AppID/Key/Secret 后替换即可。
- **厂商离线通道**需上架应用商店（小米/OPPO/vivo/华为 + 海外 FCM），否则杀进程后收不到（自分发 APK 无法规避）。
- **不在范围**：断刀检测 / YOLO 火焰视觉（纯研究）；维护提醒（方案未定，以后做；数据 `jobs.durationSec` 已具备，阈值待定）。

---

## 7. 术语表 & 参考文档

| 词 | 含义 |
|---|---|
| `deviceId` | 贯穿全系统的唯一设备码（屏幕=摄像头=阿里云绑定主键，同一字符串） |
| `accountId` / `userId` | 登录用户 ID，推送寻址主键（`alias`） |
| `cid` | 个推 ClientID，设备×安装唯一，重装变；**不当业务标识** |
| `alias` | 个推别名 = userId，云端按此下发到用户全部设备 |
| LWT | MQTT 遗嘱消息，断线时 broker 自动发 `{"state":"disconnected"}` |
| EMQX | 腾讯云 MQTT 5.0 Broker |
| 五闸门模型 | 阿里云加机器 → App 立即可用，零 MQTT/broker 改动 |

**参考契约（细节权威源）**：`docs/43`(屏幕/固件) · `docs/50`(雕刻历史) · `docs/52`(G-code) · `docs/53`(推送寻址) · `docs/B阶段-推送后端接口契约.md`(个推通道) · `PROTOCOL.md`(线协议，§10.7 notify / §2.3 状态帧)

> 本文档自包含，但字段级细节（状态帧枚举、notify 精确 schema、个推 REST 字段）以以上契约/协议文档为最终准。


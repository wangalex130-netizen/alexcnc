# 第一步（局域网 LAN）实施设计

> 范围：仅局域网。App 在局域网内**直连机器**完成控制与状态交互，并拉取**局域网 RTSP** 视频流。  
> 外网服务器交互（云端 MQTT / 云端 REST 材质 / G-code 云端推送）**全部推迟到第二步**，本步不触碰。  
> 本文由 Senior Developer 起草，作为 App 端（我）与嵌入式软件工程师**同步开工**的契约总纲，全程由我指导。

---

## 0. 为什么先 LAN（决策复盘）

- LAN 内 App↔机器是**直连**，无 NAT 穿透、无证书/鉴权、无云端可用性依赖，调试路径最短、抓包最容易。
- 视频流 RTSP 本就在 LAN（摄像头 `192.168.1.47`），天然适配第一步。
- 把最不确定的"外网"单独隔离到第二步，第一步只验证**你能 100% 掌控**的链路，风险最低。

---

## 1. 第一步目标（验收口径）

1. 手机与机器在**同一局域网**，App 能发现并连接机器（mDNS 自动发现 + 手动 IP 兜底）。
2. App 能向机器**下发控制命令**并收到**实时状态回传**：jog（点动）、home（回零）、setWorkZero（定工件原点）、start/pause/resume/stop（作业）、leveling（调平方案）、aux（辅助：灯光/激光/延时）。
3. 机器自检流水线（固件拥有）广播 `scIndex/scTotal`，App 实时渲染自检进度；随后进入加工进度 `prog/eta`。
4. 控制台页能播放**局域网 RTSP** 摄像头画面（加载中 / 出错 / 重连状态可见）。
5. 局域网内可跑通"选模型 → startJob → 机器执行"闭环（G-code 由 **PC 伴随服务**经局域网推给机器，App 不持有 G-code）。
6. 断线自动重连；UI 有"连接中 / 已连 / 掉线"状态点。

**不做（第二步）**：云端 MQTT Broker 中继、云端 REST 材质主表、G-code 云端直推、账号体系、远程访问。

---

## 2. 架构（第一步）

```
┌──────────────┐         TCP:8899 (JSON 帧)         ┌────────────────────┐
│  手机 App     │ ───────────────────────────────▶ │   ESP32 机器固件     │
│  (Flutter)   │ ◀─────────────────────────────── │  (AsyncTCP Server)  │
│              │     状态广播 ← 自检/进度/坐标       │   + 运动控制(Grbl)   │
│  - 控制台页   │                                    ├────────────────────┤
│  - 向导页     │                                    │  RTSP 摄像头         │
│  - 联调设置   │ ── RTSP (局域网) ──▶ 192.168.1.47:554/11
└──────┬───────┘                                    └────────────────────┘
       │ mDNS 发现 (alexcnc-xxxx.local)
       │
       │ HTTP (局域网, 可选)        ┌────────────────────────┐
       └─────────────────────────▶ │  PC 伴随服务 server.py   │
         模型库 / G-code 源          │  - /api/v1/materials     │
          startJob 时推 G-code      │  - /api/v1/tasks/active  │
          经 TCP:8899 给机器         │  - POST /api/v1/devices/{id}/jobs (推G-code)
                                    └────────────────────────┘
```

**关键变化（相比原方案）**：原方案把 MQTT 云端 Broker 当主链路、TCP:8899 当"运动增强"。  
第一步把 **TCP:8899 提升为唯一控制+状态通道**（ESP32 直接做 TCP Server，App 直连），MQTT 云链路保留代码但**默认关闭**，待第二步启用。这样嵌入式只需实现一套 TCP 帧，契约单一、最易对齐。

---

## 3. 控制面契约（TCP:8899，第一步唯一通道）

### 3.1 传输

- 机器侧开 **TCP Server，端口 8899**，绑定 `0.0.0.0`。
- App 侧作为 **TCP Client** 连接 `机器IP:8899`，保持长连接。
- 帧格式：**每行一个 JSON**，以 `\n` 分隔（与 Grbl 风格的逐行交互兼容，便于后续扩展原始 G-code 行）。
- 命令帧（App→机器）与状态帧（机器→App）**同一连接双向收发**。

### 3.2 命令帧（App → 机器）

| cmd           | 字段                                       | 说明                                    |                   |    |
| ------------- | ---------------------------------------- | ------------------------------------- | ----------------- | -- |
| `jog`         | `axis`(x                                 | y                                     | z), `dist`(mm,可负) | 点动 |
| `home`        | —                                        | 回机械零                                  |                   |    |
| `setWorkZero` | `x`,`y`,`z`                              | 设工件原点                                 |                   |    |
| `spindle`     | `rpm`(0=停)                               | 主轴                                    |                   |    |
| `aux`         | `key`(light|laser|timelapse), `on`(bool) | 辅助设备                                  |                   |    |
| `toolMap`     | `tools`:[{`index`,`installed`}]          | 刀仓映射（4 刀位）                            |                   |    |
| `leveling`    | `mode`, `cols`, `rows`                   | 调平方案（网格由云端/伴随服务按真实尺寸算，App 下发）         |                   |    |
| `gcode`       | `lines`:[`G0 X0 Y0 ...`, ...]            | 局域网 G-code 推送（第一步由 PC 伴随服务发，App 不直接发） |                   |    |
| `job`         | `action`:`start\|pause\|resume\|stop`    | 作业控制                                  |                   |    |

示例（jog）：`{"cmd":"jog","axis":"x","dist":5.0}\n`

### 3.3 状态帧（机器 → App）

每变动即发一行 JSON（字段容错，详见 `lib/models/machine_status.dart` 的 `fromJson`）：

```json
{
  "state": "idle|homing|busy|paused|alarm|disconnected",
  "pos":  {"x":0.0,"y":0.0,"z":0.0},
  "mpos": {"x":0.0,"y":0.0,"z":0.0},
  "rpm": 12000, "feed": 600,
  "progress": 0.42, "etaSec": 174,
  "scIndex": 3, "scTotal": 8,
  "aux": {"light":false,"laser":false,"timelapse":false},
  "tools": [{"index":1,"installed":true}, ...]
}
```

- **自检流水线由固件拥有**：`job start` 后 `scTotal=8`，固件自行推进 `scIndex 0→8`，完成后转入 `progress` 加工进度。App 只读 `scIndex/scTotal` 渲染，**不自己计时**。
- 别名兼容：固件可发 `mp`(主轴) / `prog`(进度) / `eta`(秒) 任一风格，App 已容错。

### 3.4 连接/重连

- App 连接失败或连接断开后，**每 5s 重试**直到连上。
- `disconnect()` 主动关闭时**不再重连**（防抖标志 `_closing`）。
- UI 通过 `connectionState` 流显示 `connecting/connected/disconnected`。

---

## 4. 视频（局域网 RTSP）

- 摄像头地址（固定侧面机位，无十字准星/加工范围叠加）：  
  `rtsp://admin:abc123456@192.168.1.47:554/11`
- App 控制台页用 `flutter_vlc_player` 播放；需 `loading / error / 重连` 三态。
- 实时雕刻页的 **2D 刀路预览** 是独立组件（按 G-code 模拟进度），与 RTSP 摄像头无关。

---

## 5. 发现（mDNS + 手动 IP）

- 机器联网后广播 mDNS：`alexcnc-<sn>.local`（Service：`_alexcnc._tcp.local`，port 8899）。
- App `device_discovery.dart` 自动发现并缓存；发现失败时用"联调设置"页**手动填 IP**（第一步主要走这条，最稳）。
- 配对码（Token）：第一步内部调试可暂不经配对码鉴权；真机交付前再启用（机身屏显示 6 位码，App 输入核对）。

---

## 6. G-code 来源（第一步）

- 不变式：**App 不持有 G-code**。
- 第一步用 **PC 伴随服务 `server.py`** 充当模型库 + G-code 源：
  - `GET /api/v1/tasks/active` 返回当前模型（含 `widthMm/heightMm` 真实尺寸，用于算调平网格）。
  - `POST /api/v1/devices/{id}/jobs`：伴随服务把内置/切片好的 G-code 经**局域网 TCP:8899** 以 `gcode` 帧推给机器；随后 App 发 `job start` 执行。
- 这样第一步即可在局域网跑通"选模型 → startJob → 机器加工"，且 G-code 始终不经 App。

---

## 7. 三方分工（同步开工）

| 角色                        | 第一步交付物                                                                                                   | 状态          |
| ------------------------- | -------------------------------------------------------------------------------------------------------- | ----------- |
| **App 端（我 / Senior Dev）** | `RealHardwareService` LAN-TCP 主链路 + 连接态/重连；联调设置页；控制台 RTSP 三态；2D 刀路预览；mDNS/手动 IP                          | 进行中         |
| **嵌入式软件工程师**              | ESP32 **AsyncTCP Server:8899**，按 §3 帧格式实现命令解析 + 状态广播（含自检 scIndex/scTotal）+ 调平接收 + G-code 缓冲执行；RTSP 摄像头接线 | 待启动（按本文档契约） |
| **PC 伴随服务（我，Python）**     | `server.py` 局域网模型库 + `startJob` 时经 TCP 推 G-code；`fake_firmware.py --tcp` 作为**无真机联调**的机器模拟 + 固件契约参考实现     | 进行中         |



> 嵌入式工程师以 `docs/PROTOCOL.md` 的 **Step1 段落** + 本设计 §3 为单一事实来源；`fake_firmware.py --tcp` 是可运行的参考实现，照着改即可。

---

## 8. 里程碑（第一步内部排期）

- **M1 联调闭环（无真机）**：`fake_firmware --tcp` + `server.py` + App 联调设置填 PC IP → App 能 jog/startJob/看 RTSP。✅ 本步达成即可内部演示。
- **M2 真机接管**：嵌入式按契约烧录 ESP32，App 直连真机器（关掉 fake_firmware），验证 jog/自检/加工/RTSP。
- **M3 打磨**：连接态 UI 小绿灯、RTSP 错误重连、调平网格真机验证、2D 刀路预览对齐。

---

## 9. 风险与对策

| 风险                       | 对策                                       |
| ------------------------ | ---------------------------------------- |
| ESP32 TCP Server 并发/缓冲不足 | 第一步单客户端串行帧，App 保持单连接；固件用 AsyncTCP 非阻塞    |
| 局域网 IP 变动导致断连            | App 5s 重连 + mDNS 重新发现；联调设置可手动改 IP        |
| RTSP 在部分手机硬解兼容性          | `flutter_vlc_player` 软解兜底；错误态可重试         |
| "App 不持有 G-code" 在第一步被误破 | G-code 只由 `server.py` 经 TCP 推，App 代码层不缓存 |

---

## 10. 第二步预告（仅说明，不实现）

第二步在外网打通：机器侧增加 **MQTT Client** 连**云端 Broker**（默认 `broker.emqx.io`，量产后换自有域名），命令/状态改走 MQTT 主题 `cnc/<id>/cmd`、`cnc/<id>/status`；G-code 由**云端直推 MCU**；材质参数走**云端 REST 主表**。App 端 `RealHardwareService` 的 `step2Cloud` 开关届时置 true 即可切换，无需重写帧逻辑（MQTT 与 TCP 帧格式一致，仅传输层不同）。

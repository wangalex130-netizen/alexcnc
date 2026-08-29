# 摄像头按需推流（camera-on-demand）— 量产流契约

> 状态：App 端已落地（见 §2），云端 token 签发 / broker 放行 为**待配合项**（§4）；**中继（relay.py）由 AI 自建自维护，其 ACL / 引用计数等增强不属外部待办，改动由 AI 直接做**。
> 关联：固件 `Claw/esp32s3-cam/main/cam_mqtt.c`、`app_wifi.c`；App `lib/services/hardware_service_real.dart`、`lib/features/preview/fullscreen_preview_page.dart`。

## 1. 背景与决策

- 此前 demo 摄像头 `cnc-demo-01` 长期处于「常推」状态：通电即向北京中继 `39.106.144.53:8080` 推 MJPEG。
- 决策（2026-08-27 与产品对齐）：**量产摄像头必须按需推流，禁止 24/7 常推**。
  - 寿命：OV2640 传感器 + Wi-Fi TX 全天满负荷 → 结温高、CMOS/芯片加速老化。
  - 带宽：中继按「客户数 × 观看时长」计费，比常推省 10–50×。
  - 隐私：B2C 客户不接受「关机了摄像头还往服务器上传」。
- MQTT 启停非唯一手段（中继反向通道 / 后端触发亦可），但固件已支持且解耦干净，保留。
- **架构决策（2026-08-29 钉死）：流控指令由摄像头固件自己加 MQTT client 直连 broker 接收，relay 不订阅任何 MQTT topic、不承担指令桥接。**
  - 摄像头固件 `cam_mqtt.c`：client id `cam-<device>`，订阅 `cnc/<device>/cmd`，收到 `stream_start/stream_stop` 调 `wan_relay_set_on_runtime()` 开关推流（已烧录 `cnc-demo-01` 验证）。
  - relay（北京阿里云 39.106.144.53:8080，`relay.py`）：纯 MJPEG 转发，零改动、零 MQTT 依赖。
  - 结论：「流控指令谁来接」= **固件侧加一个 MQTT client（已完成）**，relay 侧工作量 = 0；后续改控制语义只动固件 + App，不动 relay。

## 2. 链路与命令（已落地）

```
App(点播放) ──MQTT─▶ cnc/<deviceId>/cmd  {"action":"stream_start"}
                                        │  (EMQX HK 43.154.192.242:8883, TLS)
                                        ▼
摄像头固件 cam_mqtt.c ──▶ wan_relay_set_on_runtime(1) 开始推流
                                        ▼
摄像头 ──HTTP POST─▶ 中继 /publish/<device>?token=<token>
                                        ▼
App(HTTP 拉) ◀── MJPEG ── 中继 /stream/<device>?token=<token>
App(退预览) ──MQTT─▶ cnc/<deviceId>/cmd  {"action":"stream_stop"} ─▶ 固件停推
```

- 摄像头订阅主题：`cnc/<deviceId>/cmd`。
  - **2026-08-28 终局方案**：机器控制命令也改走同一主题（原 `gw/<id>/cmd` 已废弃），
    两者**不再分流**，靠 payload 区分：机器帧 `{"cmd":...}`、摄像头帧 `{"action":...}`、
    心跳 `{"cmd":"hello"}`。机器码与摄像头码统一后，两端都会收到彼此的帧，
    **摄像头固件必须忽略 payload 中非 `stream_start`/`stream_stop` 的帧**。
- 客户端 ID：`cam-<deviceId>`，broker 密码 `demo123`（联调期，上线换正式）。
- 命令：`{"action":"stream_start"}` / `{"action":"stream_stop"}`（firmware 子串匹配，容错）。
- 额外命令（固件已支持，待 App 暴露 UI）：`set_quality`(4–40)、`set_framesize`(qvga/qqvga…)。

### App 端改动（本次提交）
- `HardwareService.sendCameraStream(String action,{String? deviceId})`：抽象接口新增；Mock 空实现。
- `RealHardwareService.sendCameraStream`：MQTT 已连时向 `cnc/<deviceId>/cmd` 发布；**不依赖 `cloudEnabled` 局域网闸门**（摄像头为纯外网设备）。
- `FullscreenPreviewPage`（改 `ConsumerStatefulWidget`）：
  - `initState` 发 `stream_start`；并监听 `connectionState`，MQTT 晚连上时补发。
  - `dispose` 发 `stream_stop`（退出即停推）。
  - 右上状态药丸：`启动中…` →（首帧到达）`已连接` /（12s 无帧或断开）`无信号`，由 `MjpegStreamPlayer.onPlaying/onError` 驱动。

## 3. 当前（demo）行为 vs 量产目标

| 项 | demo 现状 | 量产目标 |
|---|---|---|
| 拉流地址 | 硬编码 `AppConfig.cameraRelayBaseUrl` + `cnc-demo-01` | 登录后由后端下发（见 §4）|
| 中继 token | 写死 `lunyee-cnc-relay-7k2p` | 后端按账号签发，不落客户端 |
| 摄像头启停 | App 发 MQTT（已接） | 同左 + 多观众引用计数（中继侧）|
| 未登录 | 可看 demo | 禁止拉任何流（或仅标「演示」）|

## 4. 待配合项（非 App 侧）

1. **阿里云（037123.xyz）**
   - 登录后下发的机器信息中，附带该设备的**中继 token（按账号签发、可过期）**，App 不再用硬编码默认值。
   - 下发「是否有权拉流该设备」标记（账号→设备绑定已存在，复用即可）。
2. **中继（39.106.144.53:8080）— 归属：AI 自建自维护（relay.py），非外部工程师待办**
   - relay 由 AI 直接搭建并维护，下列增强由 AI 直接落地，不依赖外部配合。
   - 按 `账号 → 设备` 做 ACL：未绑定/未登录拒绝 `/stream/<device>` 与 `/publish/<device>`。
   - 多观众引用计数：最后一个观众退预览才真正停推（避免一人退出掐掉他人画面）。
3. **EMQX broker（HK）**
   - 放行 App 客户端（`android-<deviceId>`）对 `cnc/<deviceId>/cmd` 的 **PUBLISH**。
   - ✅ **2026-08-28 已完成**：ACL 改为按 `username + cnc/#` 通配授权，
     `gw/#` 与 `wan_whitelist` 已废弃，App 可直接发布 `cnc/<deviceId>/cmd`。
4. **固件（可选增强）**
   - 摄像头在 `stream_start`/`stream_stop` 时发布自身 `online/streaming` 状态到 `cnc/<deviceId>/status`，App 直接订阅真实状态（当前 App 用「首帧到达/超时」反推，已可用）。

## 5. 验证口径（供各端）

- 联调：App 开 real 模式（`USE_REAL_BACKEND=true`）→ 打开预览 → 中继应出现 `cnc-demo-01` 推流；退出 → 推流停止。
- 回退风险：若 broker 未放行 `cnc/<id>/cmd`，App 命令被 ACL 丢弃，摄像头不启推 → 预览 12s 报「无信号」。先确认 ACL 再加此命令。
- 多端同步：本改动涉及 App + 阿里云 + 中继 + broker 四处，任一处变动需同步知会，避免「命令发了摄像头收不到 / token 不对拉不到流」。

## 6. App 侧核对与回复（2026-08-29）

App 侧已逐条核对本文档，结论如下。

### 6.1 已确认一致、**App 无需改动**

| 项 | 核对结果 |
|---|---|
| §1 架构决策：流控由**摄像头固件加 MQTT client** 接收，relay 不订阅任何 MQTT topic | ✅ 采纳。App 侧本就向 `cnc/<deviceId>/cmd` 发 `{"action":"stream_start"/"stream_stop"}`（QoS1），与固件约定一致，无需改动 |
| §2 relay = 北京 39.106.144.53:8080，**纯 MJPEG 转发** | ✅ 与 App 一致。App 拉流端点就是 `{relay}/stream/<device>?token=`，播放侧为 MJPEG（`MjpegStreamPlayer`），**不是 HLS**；App `AppConfig.cameraRelayBaseUrl` 默认值也是北京，无需改 |
| §2 摄像头必须忽略 payload 中非 `stream_start`/`stream_stop` 的帧（因终局方案下机器命令、心跳共用同一主题） | ✅ 已确认。提醒：`{"cmd":"hello"}` 心跳**每 10s 一次**，摄像头务必忽略 |
| §4.3 broker 放行 App 对 `cnc/<deviceId>/cmd` 的 PUBLISH | 见 6.2 风险② |

### 6.2 ⚠️ 两处风险，请摄像头 / MQTT 侧确认

**风险①（高）：§4.4 建议摄像头把 online/streaming 发到 `cnc/<deviceId>/status`，会破坏机器状态并解锁 Jog**

`cnc/<deviceId>/status` 是**机器状态专用主题**，App 对每一帧都按 `MachineStatus` 解析。
而 `MachineStatus.fromJson` 对不认识的字段一律回落为：

| 字段 | 回落值 | 后果 |
|---|---|---|
| `state` | `idle`（待机） | **加工中 / 报警 会被刷成「待机」** |
| `pos` / `mpos` | `(0,0,0)` | DRO 坐标归零 |
| `progress` | `0` | 加工进度条归零 |
| `awaitingConfirm` | `false` | **机旁确认横幅被抹掉，防呆失效** |

更严重的是：App 的 Jog 安全闸门是 `canControl = idle && (已选机器)`，
**一旦摄像头发帧把状态刷成 idle，加工中的 Jog 会被错误解锁** —— 这是实打实的安全漏洞。

**对策（二选一，推荐①）**：
1. **摄像头状态改发专用主题 `cnc/<deviceId>/cam`**，不占用 `status`；
2. 若一定要用 `status`，则帧内**必须**带 `state`/`pos` 等机器字段（不现实，摄像头不知道机器状态）。

> App 侧已加**兜底防护**：`RealHardwareService._isCameraStatusFrame()` 会丢弃
> 「只带 `streaming`/`cam`/`camera`/`online` 且不含 `state`/`pos`/`mpos`/`mp`」的帧。
> 但这是保险丝，不是方案 —— 仍请改到 `cnc/<deviceId>/cam`。

**风险②（高）：§4.3 声称「ACL 已改为 `username + cnc/#` 通配」，但仓库里仍是枚举式**

核对 `cnc-control-server/deploy/acl.conf` 第 5–7 行与 `deploy/users.json`：
`app-demo` **只**允许 `cnc-demo-01/02/03` 三台（publish 与 subscribe 均枚举）。

也就是说：**App 控制任何 sn 不在 `cnc-demo-01/02/03` 内的机器，MQTT 发布/订阅会被 ACL 静默拒绝**
（连接与认证照常成功，但命令发不出、状态收不到 —— 与 §5「回退风险」描述的现象完全一致）。

请确认：
- HK 线上的 EMQX 是否已手动改成通配？若是，请把改动**提交回仓库**，否则下次重新部署会丢失；
- 若还没改，建议 App 与屏幕端同构，改为通配：`publish/subscribe cnc/+/cmd`、`cnc/+/status`、`cnc/+/notify`…（屏幕端 `screen-cnc-demo-*` 已是通配 `cnc/+/...`）。

### 6.3 App 侧待办（依赖外部）

- **§4.1 阿里云**：App 目前的中继 token 仍是**硬编码**默认值 `lunyee-cnc-relay-7k2p`。
  等后端在登录后的机器信息里下发「按账号签发、可过期」的 token，与「是否有权拉流」标记后，
  App 会改为读取下发值。
- **§2 额外命令 `set_quality`(4–40) / `set_framesize`(qvga/qqvga…)**：固件已支持，
  但是否在 App 暴露 UI 属**产品决策**，暂未做，等待拍板。

### 6.4 App 侧已完成（供对照）

- MQTT 载荷解码改为 UTF-8 + `allowMalformed` 容错（中文不再乱码，脏包不会打断订阅）。
- 未选择机器时锁定运动命令（真实后端模式），避免打到默认联调设备。
- 机器列表在线/不在线展示（依赖后端 `online` 字段，实时性待云端确认）。

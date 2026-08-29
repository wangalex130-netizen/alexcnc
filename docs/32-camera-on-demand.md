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

### 6.5 App 侧复核摄像头团队的核实回复（2026-08-29 深夜）

摄像头团队已逐行核对固件源码，确认 §6.2 两条风险**都成立**，并给出 4 项修复（App 零改动）。
App 侧复核结论：**方案全部同意**，另补充执行顺序与 3 个技术点。

#### ① 建议把「止血」与「根治」拆开 —— 执行顺序调整

风险①的严重性经核实**高于 §6.2 的描述**：固件 `cam_mqtt.c` 不只是开关预览时发
`{"streaming":true/false}`，**每次 MQTT 连上/重连都会额外发一次 `{"online":true}`**
（无 `state`/`pos`）。即摄像头每次网络抖动重连，都可能把机器状态刷成 `idle`。
当前全靠 App 的 `_isCameraStatusFrame()` 兜底。

因此建议**把下列第 2 项（ACL 收紧）单独提前，先于烧录执行**：

| 顺序 | 动作 | 理由 |
|---|---|---|
| **① 立刻** | ACL 去掉 `cam-*` 对 `cnc/+/status` 的发布权，改 `cnc/+/cam` | 纯减法授权，restart 后**立即止血**；旧固件在线也发不进 status。不必等烧录 |
| ② 随后 | 固件主题改 `cnc/<device>/cam` + 重新烧录 `cnc-demo-01` | 根治，可按排期推进 |
| ③ 可延后 | `app-demo` 枚举 → 通配 | 只影响「控制非 demo 机器」，当前联调用 `cnc-demo-01` 不阻塞 |

按原顺序执行，风险窗口会一直开到烧录完成；拆开可先堵口。

#### ② 三个技术补充点

1. **请确认摄像头发布时 `retain=0`。**
   若带 retain，App 每次（重新）订阅都会收到这帧摄像头状态，触发频率比「重连时」更高。
2. **心跳忽略逻辑可用，但留个小尾巴。**
   固件用 `strstr` 子串匹配 `stream_start`/`stream_stop`/`set_quality`/`set_framesize`，
   理论上若某机器帧的 `msg` 字段里恰好含这些关键字会被误触发。概率极低、不阻塞，
   建议后续改为精确字段匹配。
3. **给未来留个坑位：`cnc/<device>/cam` 仍会被 App 兜底丢弃。**
   该主题不属于 telemetry/broadcast/system/job/sys，会走 `_parseAndEmit` 兜底分支，
   并被 `_isCameraStatusFrame()` 按 payload 丢弃（**无害，当前不需要处理**）。
   ⚠️ **将来若 App 要显示摄像头在线状态，必须在该拦截之前加一条显式 topic 路由**，否则会被吃掉。

#### ③ 对三个拍板项的建议（App 视角）

1. **风险① 立刻改 + 烧录** —— 同意。安全漏洞，与 App 代码零冲突；按 ① 拆分的顺序执行。
2. **风险② 建议拆两半** —— 「去掉 cam 对 status 的发布权」立刻做（止血，纯减法）；
   「`app-demo` 改通配」可等 App 稳定后再动。后者才是「动 broker 影响所有端」的部分。
3. **`set_quality` / `set_framesize` 暴露 UI —— 建议暂不做。**
   画质与分辨率是工程参数，与「B2C 客户不应看到技术碎片」的产品原则冲突。
   若确有带宽或卡顿问题，建议做**自适应降质**（按网络状况自动调整），而不是给用户开关。

#### ④ 量产边界（App 侧确认）

同意摄像头团队的提醒：**`app-demo` 通配只是 demo 期便利**，
量产必须切「绑定驱动」（按账号下发设备列表 + EMQX authz 接 037123 绑定）。
**App 侧不会把通配写进终态设计。**

#### ⑤ App 侧状态

对上述 4 项修复，**App 无需任何代码改动**。
兜底防护 `_isCameraStatusFrame()` 已随 commit `c5f2e1c4` 发布，覆盖 `online` / `streaming` 字段。

### 6.4 App 侧已完成（供对照）

- MQTT 载荷解码改为 UTF-8 + `allowMalformed` 容错（中文不再乱码，脏包不会打断订阅）。
- 未选择机器时锁定运动命令（真实后端模式），避免打到默认联调设备。
- 机器列表在线/不在线展示（依赖后端 `online` 字段，实时性待云端确认）。

### 6.6 App 侧对「执行完毕报告」的复核（2026-08-30）

摄像头/MQTT 侧已按 §6.5 执行完毕。App 侧逐条复核结论：**无阻塞、无冲突，可继续**。

#### ① `deny_action: disconnect → ignore` —— App 无依赖，但故障表现变了（请各端知悉）

**确认：App 不依赖「被拒即断连」，无需任何改动。** App 的链路状态只取自 MQTT 连接回调，
没有任何逻辑以「发布被拒」为触发条件。

**但要记录一个行为变化**：失败模式从**「看得见的掉线」变成「看不见的静默丢弃」**。

叠加「`app-demo` 仍为枚举（按 §6.5 建议延后改通配）」这一现状，意味着在改通配之前：

> App 控制 `cnc-demo-01/02/03` **以外**的机器时 ——
> 界面显示「云端 MQTT · 已连接」、按钮照常响应，**但命令石沉大海，且没有任何报错**。

**联调排障提示**：遇到「命令无效但连接正常」，第一步请查 EMQX 的 **ACL deny 日志**，
而不是去查应用或固件。因此建议保留并开放 ACL deny 日志的查询入口。

**附带影响**：App 的暂停 / 继续是**乐观 UI**（点击立即翻转本地按钮状态）。
静默丢弃时会出现「App 显示『已暂停』、机器实际还在跑」的错位。
（此前 deny=disconnect 时 App 会掉线，用户能察觉。）暂不额外加固，待改通配后此场景自然消失。

#### ② 验证：App 收不到 `cnc/<device>/cam` 帧 —— 双保险到位

已核对 App 的 MQTT 订阅清单，**全部为显式逐一订阅，无任何通配**
（`status` / `notify` / `telemetry` / `broadcast` / `system` / `job` / `sys`）。

因此摄像头改发 `cnc/<device>/cam` 后：
- App **根本不会订阅、也不会收到**这些帧；
- App 侧的 `_isCameraStatusFrame()` 兜底遂成为**纯冗余保险**（安全带 + 安全气囊），
  正常运行时不会触发。

即「ACL 拦截 + App 兜底」两层防护均已就位，摄像头烧录前 App 联调**不受阻塞** ——
同意摄像头侧的这一判断。

#### ③ 对摄像头侧三点补充的确认

| 项 | App 侧确认 |
|---|---|
| `retain=0` 已确认 | ✅ 无持久帧反复触发，风险已排除 |
| `strstr` → 新增 `json_get_action()` 按 `action` 字段精确匹配（无 `action` 字段的帧一律不启停） | ✅ 比我们的建议更彻底，误触发风险已根治 |
| cam payload 格式：`{"streaming":true/false}`（开关预览）、`{"online":true}`（每次连上/重连），均在 `cnc/<device>/cam` | ✅ 已记录。将来若 App 要展示摄像头在线状态，会**在兜底拦截之前加显式 topic 路由** |

#### ④ `cnc-relay` 残留客户端

不影响 App，由摄像头侧清理即可。提示：若 relay 侧确有 MQTT 代码，与 §1「relay 零 MQTT 依赖」
的架构决策矛盾，建议清理时一并确认 relay 是否真的不需要任何 MQTT 能力。

#### ⑤ 排期确认

- 固件待烧录（需插设备）：**烧录前 App 联调不受阻塞**，已确认（被拒帧在 broker 侧即被丢弃，App 收不到）。
- `app-demo` 通配：按建议延后，等 App 稳定后再动。
- `set_quality` / `set_framesize`：按建议不做 UI，认可「自适应降质」方向。

**App 侧无需任何代码改动。**

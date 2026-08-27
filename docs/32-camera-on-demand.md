# 摄像头按需推流（camera-on-demand）— 量产流契约

> 状态：App 端已落地（见 §2），云端 token 签发 / 中继 ACL / broker 放行 为**待配合项**（§4）。
> 关联：固件 `Claw/esp32s3-cam/main/cam_mqtt.c`、`app_wifi.c`；App `lib/services/hardware_service_real.dart`、`lib/features/preview/fullscreen_preview_page.dart`。

## 1. 背景与决策

- 此前 demo 摄像头 `cnc-demo-01` 长期处于「常推」状态：通电即向北京中继 `39.106.144.53:8080` 推 MJPEG。
- 决策（2026-08-27 与产品对齐）：**量产摄像头必须按需推流，禁止 24/7 常推**。
  - 寿命：OV2640 传感器 + Wi-Fi TX 全天满负荷 → 结温高、CMOS/芯片加速老化。
  - 带宽：中继按「客户数 × 观看时长」计费，比常推省 10–50×。
  - 隐私：B2C 客户不接受「关机了摄像头还往服务器上传」。
- MQTT 启停非唯一手段（中继反向通道 / 后端触发亦可），但固件已支持且解耦干净，保留。

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

- 摄像头订阅主题：`cnc/<deviceId>/cmd`（**非**机器控制 `gw/<id>/cmd`，两者分流）。
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
2. **中继（39.106.144.53:8080）**
   - 按 `账号 → 设备` 做 ACL：未绑定/未登录拒绝 `/stream/<device>` 与 `/publish/<device>`。
   - 多观众引用计数：最后一个观众退预览才真正停推（避免一人退出掐掉他人画面）。
3. **EMQX broker（HK）**
   - 放行 App 客户端（`app-<userId>`）对 `cnc/<deviceId>/cmd` 的 **PUBLISH**（当前 ACL 仅放行 `gw/<id>/cmd`、`cnc/<id>/{job,sys,app,notify,status}`，需补 `cmd`）。
4. **固件（可选增强）**
   - 摄像头在 `stream_start`/`stream_stop` 时发布自身 `online/streaming` 状态到 `cnc/<deviceId>/status`，App 直接订阅真实状态（当前 App 用「首帧到达/超时」反推，已可用）。

## 5. 验证口径（供各端）

- 联调：App 开 real 模式（`USE_REAL_BACKEND=true`）→ 打开预览 → 中继应出现 `cnc-demo-01` 推流；退出 → 推流停止。
- 回退风险：若 broker 未放行 `cnc/<id>/cmd`，App 命令被 ACL 丢弃，摄像头不启推 → 预览 12s 报「无信号」。先确认 ACL 再加此命令。
- 多端同步：本改动涉及 App + 阿里云 + 中继 + broker 四处，任一处变动需同步知会，避免「命令发了摄像头收不到 / token 不对拉不到流」。

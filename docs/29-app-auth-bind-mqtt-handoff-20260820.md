# 29 · 新配网模式落地：App 改造（A1–A4）+ MQTT 接入工作清单

> 日期：2026-08-20 ｜ 作者：App 任务 ｜ 范围：alexcnc 仓库 `main`
> 背景：王总确认新配网模式——**配网在屏幕端完成，App 不做配网、不加蓝牙**。
> 本单由《APP 端改造任务单_A1-A4.md》转交执行，改动已推 `main`。

## 一、新配网模式（客户视角）

```
机器开机
  └─ 屏幕(ESP32)搜索 WiFi → 客户输入家庭 WiFi 密码 → 屏幕入网
        └─ 双 WiFi：屏幕自身连家庭网；控制板经屏幕联入同一网络（一次连接，两端上网）
  └─ MQTT 收到「机器注册进网」信息（机器唯一码已入网）
客户在电脑端 / App 端注册用户账号
  └─ 扫机器唯一码（机身二维码 / 铭牌）→ 客户号 ↔ 机器唯一码 绑定
        └─ 形成固定「机器 ID 账户」（一客户可绑多机）
MQTT 转发视频流服务器连上这台机器的摄像头 → 客户可远程看
```

**结论：App 端不再需要配网功能，也不需要蓝牙。** App 只做：注册账号 → 扫码绑定 → 我的机器列表 → 远程拉流/控制。

## 二、App 侧本次改动（A1–A4，已推 main）

| 编号 | 模块 | 改动 | 状态 |
|---|---|---|---|
| A1 | 账号 | 新增 `lib/services/auth_service.dart`、`lib/state/auth_provider.dart`、`lib/features/auth/{login,register}_page.dart`；`config.dart` 新增 `backendBaseUrl`（默认 `http://43.154.192.242:8081`，`--dart-define=BACKEND_BASE_URL` 可覆盖）；`providers.dart` 的 `appUserId` 改从 auth 读取（未登录 `demo` 兜底） | ✅ 已推 |
| A2 | 扫码绑定 | `pubspec.yaml` 加 `mobile_scanner: ^5.1.1`；新增 `lib/features/machines/bind_page.dart`（扫码 `CNC-` 机器码 → `POST /api/bind`，兜底手动输入，409/404 中文提示） | ✅ 已推 |
| A3 | 我的机器 + 拉流解耦 | 新增 `lib/services/machines_service.dart`、`lib/features/machines/machines_page.dart`；`console_page.dart` / `fullscreen_preview_page.dart` / `timelapse_client.dart` 拉流地址从「写死 AppConfig」改为「绑定机器返回的 relay_url/cam_device」，未绑定时回退 runtime_config | ✅ 已推 |
| A4 | 我的页 | `profile_page.dart`：**删除「网络配对与连接」蓝牙配网抽屉**，改为「我的机器 / 注册账号 / 退出登录」；顶部显示真实登录账号 | ✅ 已推 |

### 后端 API 契约（App 按此调用；云端同步实现）

| 接口 | 请求 | 成功 | 失败 |
|---|---|---|---|
| `POST /api/register` | `{"username","password"}` | `{userId, token}` | 409 用户名已存在 / 400 |
| `POST /api/login` | `{"username","password"}` | `{userId, token}` | 401 用户名或密码错误 |
| `POST /api/bind` | Bearer；`{"machineSn":"CNC-..."}` | `{machine:{sn,cam_device,relay_url,online}}` | 401 / 404 机器码不存在 / 409 已绑定 |
| `GET /api/my/machines` | Bearer | `{machines:[...]}`（可空） | 401 |
| `GET /api/auth/stream` | relay 调 | `{allow:true}` | 403 无权限 |

## 三、需要 MQTT 车道（隔壁）配合的工作清单

### 3.1 机器注册进网信息（屏幕端 → MQTT → 云端）

新模式下机器入网后，屏幕应通过 MQTT 上报一次注册信息，让云端/账号服务知道「这台机器唯一码已在线」。建议：

```
topic:   cnc/<deviceId>/sys      （V1.1 已有 sys 帧，复用即可）
payload: 现有 sys 帧基础上确保包含 {id/model/fw/ip/bootAt}
         其中 id = 机器唯一码（与扫码绑定的 CNC- 码同源）
```

- 需要屏幕端确认：**机器唯一码（CNC-XXX）与 MQTT deviceId 是否同一串？** App 扫码得到的是 `CNC-...`，`/api/bind` 用它绑定；如果 MQTT topic 用的是 `cnc-xxx`（小写短横线），云端需做一次映射（`CNC-...` ↔ `cnc-...` ↔ 摄像头 `cam_device`）。
- 这部分请屏幕端/固件任务确认后，在 `docs/03` 补一段「机器入网注册」说明。

### 3.2 账号绑定关系（云端/账号服务，非 MQTT 本身）

- `/api/bind` 由账号服务（秦工后台）实现，维护 `accountId ↔ machineSn`。
- MQTT 侧只需要：**App 登录后 clientId 用 `app-<userId>-<唯一后缀>`**（已实现），broker ACL 按用户名 `app-demo`（联调）/ `app-<userId>`（生产）鉴权放行，与 clientId 无关，**无需改 ACL**。

### 3.3 视频流 relay 连摄像头

- App 拉流地址 = `{relay_url}/stream/{cam_device}?token={relay_token}`，其中 `relay_url`/`cam_device` 由 `/api/bind`、`/api/my/machines` 返回（不再写死）。
- 联调占位：`/api/bind` 接受 `CNC-CAM01` → 映射 `cnc-cam-01` → `http://43.154.192.242:8080/stream/cnc-cam-01`。
- **需要确认**：relay（8080）与账号后端（8081）是否同机部署、`/api/auth/stream` 校验是否已接通（relay 拉流前校验 userId 是否绑定该 device）。

### 3.4 需要隔壁确认/同步的端口与接口清单

| 项 | 值 | 状态 |
|---|---|---|
| 账号/绑定后端 | `http://43.154.192.242:8081`（新端口） | 待云端就绪 |
| 视频 relay | `http://43.154.192.242:8080`（现有） | 已有 |
| MQTT broker | `43.154.192.242:8883`（TLS） | 已有 |
| 内容面 API | `https://037123.xyz` | 已有（材料/任务/模型库） |
| 机器码映射 | `CNC-XXX` ↔ `cnc-xxx` ↔ `cam_device` | 待固件/屏幕确认 |

## 四、验收标准

1. 新账号注册 → 自动登录；退出后能重新登录。
2. 未登录点「我的机器」→ 引导登录；登录后空态正确。
3. 扫码（或手输）绑定 `CNC-` 码 → 我的机器出现该机 → 点开能看到实时画面。
4. 未绑定该机器的其他账号看不到流（云端 403，App 显示「无权限」）。
5. 延时摄影、雕刻 5 步流程、局域网直连预览不受影响（回归）。

## 五、红线（未动）

- `native_vlc_player`、`mjpeg_stream_player.dart` 播放器本体。
- 延时摄影业务流程、雕刻 5 步流程、模型库。
- 图标规范：线性图标（24×24、2px、currentColor），无 emoji。
- 未做配网、未加蓝牙。

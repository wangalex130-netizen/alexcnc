# alexcnc App 端 · 屏幕/PC/MQTT 变更对齐说明（2026-08-18）

> 来源：微信群聊截图 + 附件《设备绑定与刀仓配置接口文档_请求示例.docx》+《屏幕--控制板协议.xls》  
> 目的：明确 App 端（本车道）必须补的工作，以及需要回传 MQTT 车道确认/补充的事项，保持三端信息一致。

---

## 一、本次变更速览

| 来源 | 关键信息 | 影响范围 |
|---|---|---|
| 附件 1（阿里云内容面 API） | 设备绑定/解绑/列表、四刀仓配置查询与更新接口已部署到 `https://037123.xyz/api/` | App「我的设备」页、向导 Step3「刀仓映射」持久化 |
| 附件 2（屏幕-控制板协议） | 屏幕 ESP32-S3 与控制板之间用 CAN + GRBL `$` 指令通信；包含刀具库/自检/仓门/语音反馈 | 固件层本地协议，App 通过 MQTT 状态帧间接消费 |
| 群聊 | PC 端生成刀路→上传文件→通过 MQTT `cnc/broadcast/msg` 广播 URL，供屏幕下载 G-code | App 必须正确解析 `gcode_url` 型广播，不能当普通通知弹窗 |
| MQTT 车道（隔壁已落地） | `deploy/acl.conf` 已给 `pc-demo` 加 `cnc/broadcast/msg` 发布权限；`docs/03` 已补 `gcode_url`、`selfcheck.inspect`、`lifecycle` 主题契约 | App 端消费这些契约 |

---

## 二、MQTT 车道已落地（隔壁完成）

按隔壁同步，以下已写入 `docs/03` 帧契约 / `deploy/acl.conf`：

1. **`cnc/broadcast/msg` 增加 `gcode_url` 类型**：PC 下发 `{type:'gcode_url', url, file, size, checksum?, jobId?}`。
2. **`selfcheck` 增加 `inspect` 阶段**：对应屏幕 `$INSPECT_*` 行程探测，notify 类型 `inspect` 已预留。
3. **ACL 已放行 lifecycle 四类主题**：`wizard/selfcheck/interact/push`，App/PC/屏幕权限已对齐。
4. **`deploy/acl.conf` 已线上 reload**：PC 实测发 `cnc/broadcast/msg` 不再被踢。

> App 端只需按新契约解析，**不需要**再去找 MQTT 车道补发权限或改主题。

---

## 三、App 端（本车道）必须做的工作

### 3.1 高优：广播 `gcode_url` 解析，防止弹空通知

**现状**：`lib/models/broadcast_message.dart` 只认 `{level,title,body,target}` 通知型广播，`fromMsg` 会把 `gcode_url` 的 payload 解成 title='系统通知'、body=''，进而在 UI 弹一条空白横幅。

**必须改**：
- `BroadcastMessage` 增加 `type` / `url` / `fileName` / `size` / `checksum` / `jobId` 字段。
- `fromMsg` 先判 `j['type']`：
  - `gcode_url` → 构造业务对象，不触发通知横幅；
  - 无 `type` 或 `level` 型 → 保持现有通知横幅逻辑。
- `hardware_service_real.dart` `_handleBroadcast` 把 `gcode_url` 事件改发到 `notifyStream`（type=`gcode_url`，message=`PC 已生成刀路：xxx，机器将自动下载`），让当前页面能 toast 提示；同时保留未来接入「下载进度条」的扩展点。
- UI 对 `type=='gcode_url'` 的 `NotifyEvent` 不弹红色告警，用中性文案提示即可。

**影响页面**：全局广播监听（控制台、向导、监控页）。

### 3.2 中优：接入阿里云「设备绑定」接口

**现状**：`RealCloudService` 没有设备绑定/解绑/列表方法；`PROTOCOL.md §2.6` 只描述了流程，未调用真实接口。

**必须加**：
- 在 `lib/services/cloud_service.dart` / `cloud_service_real.dart` 增加：
  - `bindDevice(String deviceCode)` → `POST /api/user/device/bind?code={deviceCode}`
  - `unbindDevice(String deviceCode)` → `POST /api/user/device/unbind?code={deviceCode}`
  - `listDevices()` → `GET /api/user/device/list`
- 登录态 token：当前 `_headers` 里 TODO 写着 `Authorization: Bearer <token>`，需要闫工/秦工确认 token 获取方式（假设已登录，从 `NetworkAuth` 或登录 provider 取）。
- UI「我的设备」页/控制台机器切换需消费这些接口；单机连接模式下，切换设备先解绑旧再绑定新（或简单只允许一台）。

### 3.3 中优：接入阿里云「四刀仓配置」接口

**现状**：`ToolMagazineProvider` 是硬编码内存态（默认 T1 平底刀、T2 V刀、T3/T4 空），没有持久化，也没有和云端/屏幕共用同一套 `deviceCode + slot1~slot4` 语义。向导 Step3 的刀仓映射只存在本地，杀 App 即丢。

**必须加**：
- `CloudService` 增加：
  - `getBitConfig(String deviceCode)` → `GET /api/device/bit-config/info?deviceCode={deviceCode}`
  - `saveBitConfig(String deviceCode, Map<int,String?> slots)` → `POST /api/device/bit-config/insertOrUpdate`，Body `{deviceCode, slot1, slot2, slot3, slot4}`（slot 值是刀头 ID，null 表示空位）。
- 闫工后续会单独给「刀具列表接口」；拿到后建立 `ToolDef.id` ↔ 刀头 ID 映射。
- `ToolMagazineProvider` 启动时拉取云端配置初始化；用户改刀仓后调用 `saveBitConfig` 同步。
- 向导 Step3「确认映射并同步到机器」流程里：先写云端 bit-config，再发 `toolMap` 命令给机器（保持现有机器同步逻辑）。

### 3.4 低优/预留：selfcheck inspect 阶段展示

**现状**：`NotifyEvent` 已支持 `inspect` 类型（V1.1 扩展）；`MachineStatus.scIndex/scTotal` 已驱动全局 `activeJobProvider` 渲染自检进度。

**待确认**：
- 屏幕端是否会同时通过 `cnc/<deviceId>/notify` 发 `type=inspect` 事件？如果是，App 只需把 `inspect` 当普通事件提示，不用额外 UI。
- 若固件把 `$INSPECT_*` 的详细错误码/阶段码放进 `notify.data`，UI 需要解析 `data.stage` / `data.code` 做更细提示。等产品/固件确认后再做。

**结论**：先保证 `inspect` 类型不崩溃、不弹红框即可；详细阶段展示等固件真机数据。

### 3.5 低优/预留：jobId 贯穿

**现状**：`ActiveJob` 已持有 `task.id`；但 `startJob()` 下发的命令和 `gcode_url` 广播都缺少 `jobId` 透传。

**建议**：
- `gcode_url` payload 里加 `jobId`（PC 端/云端写，App 端解析后用于监控页匹配）。
- 后续若云端 `pushTaskToMachine` 改为带 `jobId` 的任务维度，App 同步改。
- 当前不必阻塞，先把 `gcode_url` 基本链路跑通。

---

## 四、需要回传/同步给 MQTT 车道的事项

以下不是隔壁已做的工作，而是 App 端消费时发现的契约/数据需求，需要 MQTT 车道（或闫工 PC 端）确认或补充：

| # | 事项 | 需要隔壁做什么 |
|---|---|---|
| 1 | **`gcode_url` payload 精确字段** | 确认 PC 端实际会发哪些字段：`url`（必填）、`file` 或 `name`（文件名）、`size`（字节）、`checksum`（算法？MD5/SHA256？）、`jobId`。建议文档化到 `docs/03 §6.2` 并给示例 JSON。 |
| 2 | **jobId 生成与透传** | 确认 `jobId` 由 PC 端、云端还是机器生成；App 需要从 `gcode_url` 里读到，并关联到本次监控页。若暂时没有 `jobId`，先透传 `taskId` 或文件名作为弱关联。 |
| 3 | **设备绑定 token 机制** | 阿里云接口需要 `Authorization: Bearer {token}`，该 token 与 MQTT 登录账号（`app-demo`）是否为同一套登录体系？需要隔壁/秦工确认 App 登录后如何拿 token，以及 token 是否也用于 MQTT 鉴权。 |
| 4 | **刀头列表接口** | 附件 1 说「刀头列表接口闫工后续会单独给屏幕」。App 也需要同一套接口来选择刀具/映射刀仓。请闫工把接口定义同步给 App 车道，避免屏幕和 App 用两套刀具数据。 |
| 5 | **`selfcheck.inspect` 事件格式** | 确认屏幕自检阶段除了 `scIndex/scTotal` 状态帧，是否还会发 `notify type=inspect`；如果会发，给出 payload 示例（`data` 里含 stage/code/msg）。 |
| 6 | **语音/仓门状态上云** | 屏幕 `$KNIFE_DOOR_*` / `$SOUND_*` 反馈最终要进 `status.door` / `status.tools` 或 `sys`。确认这些是否通过 `cnc/<deviceId>/status` 主题上报；若不是，需要新增主题或扩展字段。 |

---

## 五、各角色下一步

| 角色 | 下一步 |
|---|---|
| **App（本车道 / 秦工）** | ① 改 `BroadcastMessage` + `_handleBroadcast` 支持 `gcode_url`；② 在 `CloudService` 接设备绑定/刀仓配置接口；③ 向导 Step3 接入云端 bit-config；④ 处理登录态 token。 |
| **MQTT 控制面（隔壁）** | 已闭环契约/ACL；待 App 端确认 §6.2 `gcode_url` 字段示例、§11 `inspect` notify 示例；后续若加 `wizard/selfcheck/interact/push` 生命周期主题需 ACL 再同步。 |
| **PC 端（闫工）** | 给出 `cnc/broadcast/msg` 实际 payload 示例；确认 `jobId` 生成方；提供刀头列表接口给 App。 |
| **屏幕/固件（崔工/耿工）** | 按 `docs/03 §6.2` 实现 URL 下载落 SD；按 §11 上报 `inspect` 阶段；刀仓/仓门/语音状态按 `docs/03` 进 `status`/`sys`。 |
| **用户（王）** | 确认 App 登录态 token 来源；确认「我的设备」页是否允许多台绑定；确认向导 Step3 刀仓配置是否必须云端持久化（建议必须，否则杀 App 丢配置）。 |

---

## 六、风险与阻塞点

1. **广播解析不兼容会立即出 bug**：PC 端一发 `gcode_url`，当前 App 会弹空白横幅。建议本车道最先修 3.1。
2. **刀仓配置未持久化**：当前刀仓映射纯内存，用户重新进向导会回到默认 T1/T2，导致 PC 下发的 G-code 与机器实际刀具不符 → 加工事故。建议本车道第二优先级修 3.3。
3. **token 未接入**：阿里云接口目前无 token，所有请求会被 401。需秦工/闫工先对齐登录态。
4. **jobId 未对齐**：监控页无法把 `gcode_url` 事件与当前任务关联，只能做全局提示；后续再做精确关联。

---

## 七、相关文件

- `lib/models/broadcast_message.dart` → 3.1
- `lib/services/hardware_service_real.dart` → 3.1
- `lib/services/cloud_service.dart` / `cloud_service_real.dart` → 3.2、3.3
- `lib/state/providers.dart` (`ToolMagazine`) → 3.3
- `lib/features/wizard/wizard_page.dart` → 3.3
- `docs/PROTOCOL.md` §2.6 / §3.1 / §6.2 / §11 → 契约依据
- 隔壁产出：`docs/03-frame-contract.md`（MQTT 车道维护）、`deploy/acl.conf`、`docs/25-app-team-handoff.md`

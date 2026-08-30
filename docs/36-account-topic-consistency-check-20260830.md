# MQTT Topic / 账号清单一致性核对（2026-08-30）

来源：PC 工程师《MQTT-Topic及账号清单.xlsx》+ 企业微信截图（Jason：设备码 `cnc-demo-03`、摄像头 ClientId `cam-cnc-demo-03`）  
对照事实源：`contract/topics.json`、`deploy/users.json`、`deploy/acl.conf`、App 代码（`alexcnc_issue3`）。

---

## 一、总体结论

**你的核心理解是正确的**：

> 阿里云保存的是「客户账号 → 绑定机器列表」；机器 ID 就是 MQTT 里的 `deviceId`；摄像头作为机器的附属外设，也使用同一个 `deviceId`（测试机为 `cnc-demo-03`）。

App 端三条链路已经严格按这个模型实现：

| 链路 | 代码依据 | 使用的设备码 |
|---|---|---|
| MQTT 命令下发 | `hardware_service_real.dart` 中 `mqttCmdTopic = 'cnc/$deviceId/cmd'` | `currentMachine.sn` |
| 摄像头流控指令 | `fullscreen_preview_page.dart` 中 `_cameraDeviceId = machine.sn` | `machine.sn` |
| 中继拉流 | `machines_service.dart` 中 `streamUrl()` 使用 `sn` 作为设备码 | `machine.sn` |

**但是**：账号/ClientId 的命名规范在几份文档和代码之间存在 6 处不一致或待确认项，需要 PC/MQTT/固件/摄像头四方对齐。下面逐项列出。

---

## 二、Topic 清单核对

| Topic（xlsx） | 契约（topics.json） | App 订阅/发布 | 状态 |
|---|---|---|---|
| `cnc/设备码/status` | ✅ 一致 | App 订阅 ✅ | 一致 |
| `cnc/设备码/notify` | ✅ 一致 | App 订阅 ✅ | 一致 |
| `cnc/设备码/telemetry` | ✅ 一致 | App 订阅 ✅ | 一致 |
| `cnc/设备码/log` | ✅ 一致 | App 未订阅（仅日志面） | 一致 |
| `cnc/设备码/job` | ✅ 一致 | App 订阅 ✅ | 一致 |
| `cnc/设备码/sys` | ✅ 一致 | App 订阅 ✅ | 一致 |
| `cnc/设备码/wizard` | ✅ 一致 | App 未订阅（屏幕端用） | 一致 |
| `cnc/设备码/selfcheck` | ✅ 一致 | App 未订阅（屏幕端用） | 一致 |
| `cnc/设备码/interact` | ✅ 一致 | App 未订阅 | 一致 |
| `cnc/设备码/push` | ✅ 一致 | App 未订阅 | 一致 |
| `cnc/设备码/cmd` | ✅ 一致 | App 发布 ✅ | 一致 |
| `cnc/设备码/tool_catalog` | ✅ 一致 | App 未订阅 | 一致 |
| `cnc/broadcast/#` | ✅ 一致 | App 订阅 ✅ | 一致 |
| `sys/register` | ✅ 一致 | App 未订阅 | 一致 |
| `cnc/设备码/cam` | ❌ 契约未列 | App **不订阅**（已做兜底隔离） | 需补进契约/xlsx |
| `cnc/设备码/app` | ❌ xlsx 未列、契约未列 | App **发布 LWT/online** | 需补进契约/xlsx/ACL |

### 发现 1：摄像头状态主题 `cnc/<deviceId>/cam` 缺失

- **现状**：摄像头已由 `cnc/<deviceId>/status` 改发 `cnc/<deviceId>/cam`（安全止血，避免把摄像头 `{"online":true}` 误解析成机器 idle）。
- **问题**：PC 工程师的 Topic 清单和 `contract/topics.json` 都还没有这条。
- **影响**：MQTT 服务器配置、文档、自动化对账脚本会漏掉这条主题。
- **动作**：补进 `contract/topics.json` 和 xlsx，并在 `deploy/acl.conf` 中保留 `cam-*` 对 `cnc/+/cam` 的发布权。

### 发现 2：App 在线状态主题 `cnc/<deviceId>/app` 缺失

- **现状**：App 在 `hardware_service_real.dart` 里用 `cnc/<deviceId>/app` 做 LWT（断线 retain 发布 `{"online":false}`）和上线 retain 发布 `{"online":true}`。
- **问题**：Topic 清单、契约都没列；`deploy/acl.conf` 虽然给 `app-demo` 放行了 `cnc/cnc-demo-0X/app` 的发布权，但文档层面没同步。
- **影响**：其他端如果也订阅/发布 `cnc/<deviceId>/app` 会不知道这条主题存在。
- **动作**：补进 `contract/topics.json`、`deploy/acl.conf`、xlsx，并说明仅 App 使用。

---

## 三、账号 / ClientId 核对

### 3.1 当前四方对照

| 端 | PC 工程师 xlsx | 企业微信截图 | 契约 topics.json | App/部署代码 | 状态 |
|---|---|---|---|---|---|
| 屏幕 | 业务账号 `3020-2.0`<br>ClientId `screen-设备码` | — | `username: screen-<deviceId>`<br>`clientId: screen-<deviceId>` | `deploy/users.json` 用 `screen-cnc-demo-0X`<br>ACL 用 `screen-cnc-demo-0X` + 通配 | ⚠️ 屏幕「业务账号」语义不清，需确认 |
| 驱动 | 待定<br>ClientId `driver-设备码` | — | 无 `driver` 身份；PC 端为 `pc-<userId>` / `pc-` | 无对应实现 | ❌ `driver-` 前缀与契约 `pc-` 冲突 |
| 摄像头 | 待定<br>ClientId `cam-设备码` | username `cam-cnc-demo-01`<br>ClientId `cam-cnc-demo-03` | `username: cam-<deviceId>`<br>`clientId: cam-<deviceId>` | App 期望摄像头设备码 = `machine.sn` = `cnc-demo-03` | ⚠️ username 与 clientId 设备码不一致 |
| 阿里云 | 待定<br>ClientId `bridge-aliyun-api` | — | `username: svc-bridge-aliyun-api`<br>`clientId: bridge-aliyun-api` | 未在 `deploy/users.json` 中列出 | ⚠️ username 待对齐；凭据待入库 |
| 安卓 App | 待定<br>ClientId `app-设备码` | — | `username: app-user-<userId>`<br>`clientId: android-<deviceId>` | App 代码：`android-<deviceId>`<br>`deploy/users.json`: `app-demo` | ❌ xlsx 的 `app-` 前缀与契约/代码的 `android-` 冲突 |

### 3.2 逐项说明

#### ① App ClientId 前缀：`app-` vs `android-`（必须确认）

- **PC 工程师 xlsx**：`app-设备码`
- **契约最终版（2026-08-28）**：`android-<deviceId>`
- **App 当前代码**：`_mqttClientId = 'android-$deviceId'`（`hardware_service_real.dart:101`）
- **建议**：以契约和代码为准，xlsx 修正为 `android-设备码`。
- **原因**：
  - `app-` 与 `app-demo` 用户名容易混淆；
  - 契约已明确不再按 userId 派生 ClientId，改为设备维度；
  - 代码、文档、MQTT ACL 都已按 `android-` 落地。

#### ② 屏幕「业务账号」`3020-2.0` 含义不清

- **PC 工程师 xlsx**：业务账号填 `3020-2.0`（看起来像机型/批次），ClientId 格式 `screen-设备码`。
- **契约**：username = `screen-<deviceId>`，与 ClientId 同构。
- **部署**：`deploy/users.json` 中屏幕账号是 `screen-cnc-demo-01/02/03`，ACL 用这些账号 + `cnc/+/...` 通配。
- **需要确认**：
  - `3020-2.0` 是 MQTT username，还是机型备注？
  - 屏幕端 MQTT username 到底用 `screen-<deviceId>`（与契约一致），还是共享业务账号（如 `3020-2.0`）？
- **影响**：如果量产切换绑定驱动 / HTTP authz，username 的解析方式会完全不同。

#### ③ 驱动 / PC 端身份：`driver-` vs `pc-`

- **PC 工程师 xlsx**：`driver-设备码`
- **契约**：PC 端 `pc-<userId>` / `pc-` 前缀
- **建议**：
  - 如果「驱动」指电脑端 ArtiMaker，应统一为 `pc-<userId>`；
  - 如果「驱动」指机器主控板（407），而主控板目前由屏幕 ESP32 通过 UART 直控、不独立连 MQTT，则应在 xlsx 中注明「不独立联网」，避免新增一个与实现不符的 identity。

#### ④ 摄像头 username / clientId 设备码不一致

- **Jason 截图**：username `cam-cnc-demo-01`，ClientId `cam-cnc-demo-03`。
- **契约**：两者都应使用同一设备码，即 `cam-<deviceId>`。
- **测试账号绑定**：`Lunyee@517788.xyz` 绑定机器 `cnc-demo-03`，因此摄像头应使用 `cam-cnc-demo-03`。
- **建议**：username 一并改为 `cam-cnc-demo-03`，与 ClientId、机器码同构。
- **风险**：若保留 `cam-cnc-demo-01`，量产 authz 按 username 解析设备码时会错误授权给 `cnc-demo-01`，且线上排查会看到「cam-demo-01 在服务 demo-03」，极易误导。

#### ⑤ 阿里云桥接账号 username

- **PC 工程师 xlsx**：业务账号「待定」，ClientId `bridge-aliyun-api`。
- **契约**：username `svc-bridge-aliyun-api`，ClientId `bridge-aliyun-api`。
- **部署**：`deploy/users.json` 中没有 `svc-bridge-aliyun-api` 或 `bridge-aliyun-api` 账号。
- **建议**：按契约 username = `svc-bridge-aliyun-api`，并补进 `deploy/users.json` / ACL。

#### ⑥ App username：`app-demo` vs `app-user-<userId>`

- **部署现状**：`app-demo`（静态 demo 账号）。
- **契约**：`app-user-<userId>`。
- **问题**：契约写的 `app-user-<userId>` 意味着每注册一个用户就要在 EMQX 建一个账号，量产不可运维。
- **建议**：修订契约为「静态账号 + authz 绑定驱动授权」（与 MQTT 三端互通方案 v4.2 一致）。
- **demo 期**：继续用 `app-demo`，但需在 xlsx 中标注为 demo 临时账号。

---

## 四、部署凭据核对（`deploy/users.json`）

| 账号 | xlsx/截图 | 是否在 `deploy/users.json` | 备注 |
|---|---|---|---|
| `app-demo` | App 待定 | ✅ 存在 | demo 期静态账号 |
| `pc-demo` | PC/driver 待定 | ✅ 存在 | 仅 demo-01 |
| `screen-cnc-demo-01/02/03` | 屏幕 3020-2.0 | ✅ 存在 | 与 xlsx 业务账号不一致 |
| `cam-cnc-demo-01` | 截图 username | ❌ 不存在 | 线上手工创建，未入库 |
| `cam-cnc-demo-03` | 建议修正后 | ❌ 不存在 | 切 demo-03 后需新增 |
| `svc-bridge-aliyun-api` | 阿里云待定 | ❌ 不存在 | 云网关账号，需入库 |
| `admin` | — | ✅ 存在 | 管理兜底 |

### 关键风险

1. **cam 账号未入库**：`deploy/scripts/emqx-init.py` 按 `users.json` 批量建号。`cam-cnc-demo-01` 目前是线上手工创建的，重新部署会丢失 → 摄像头认证失败 → 按需推流失效。
2. **切换 `cnc-demo-03` 后**：必须新增 `cam-cnc-demo-03`（推荐同时废弃 `cam-cnc-demo-01`）。
3. **桥接账号未入库**：阿里云后端若已用 `svc-bridge-aliyun-api` 连 MQTT，重新部署会认证失败。

---

## 五、ACL 现状与风险

| 项 | 现状 | 与契约是否一致 | 建议 |
|---|---|---|---|
| 屏幕 `screen-cnc-demo-*` | `cnc/+/...` 通配 | ✅ 与契约 `identities_final.acl_model` 一致 | demo 期可用，量产收紧 |
| App `app-demo` | 枚举 `cnc-demo-01/02/03` | ❌ 契约要求通配 | demo 期可用，但设备码一变就静默丢包；需排期改通配 |
| 摄像头 `cam-*` | 发布 `cnc/+/cam/notify/telemetry`，订阅 `cnc/+/cmd`、广播 | ⚠️ 契约未定义 cam 主题 | 已止血，需补契约 |
| `cnc/<id>/app` | App 可发布 | ⚠️ 文档未列 | 保留并文档化 |

### 特别注意：`deny_action = ignore` 后的静默失败

摄像头侧已把 `deny_action` 从 `disconnect` 改为 `ignore`；2026-08-30 线上实测确认
`deny_action=ignore` / `no_match=deny`。

> ⚠️ **仓库 compose 写的是 `disconnect`，与线上分叉**。
> 必须把**仓库对齐成 `ignore`**，**绝不能反过来把线上改成 `disconnect`** ——
> 那会让所有被拒的设备直接掉线，而不是"点了没反应"。

叠加 App 当时仍是枚举 ACL，导致：

> App 选择**任意白名单外的机器**（`cnc-demo-04` 只是举例，换成任何新增设备码都一样）时，
> 界面显示「MQTT 已连接」，命令按钮也响应，但命令被 Broker 静默丢弃，**没有任何报错**。
> 更严重的是**订阅同样被拒** → 收不到状态帧 → 状态永远不是 `idle` → **Jog 被锁死**。

**✅ 2026-08-30 13:35 已修复**：`app-demo` 已改通配 `cnc/+/...` 并部署上线，
任意新增设备码的订阅与发布均放行（验收：`cnc/zzz-new-999/status` → ALLOW）。
**本段描述的故障在 demo 期已消除。**

**机制仍然存在**（将来切量产 authz 时可能重现），排障与自检测手段：

| 手段 | 说明 |
|---|---|
| MQTT 轨侧查证 | 日志追踪 API（**每页仅 1000 字节，用 `position` 翻页**），关键字 `tag: AUTHZ` / `cannot_publish_to_topic_due_to_not_authorized` |
| **App 侧自检测（推荐）** | `mqtt_client` 的 **`onSubscribeFail`** 回调在 SUBACK 返回 `0x80` 时触发 → 可提示"无权订阅该机器状态"。详见 `docs/37` §九 |
| ❌ 不可行 | 发布被拒的 `PUBACK ReasonCode=135` 需 **MQTT 5**，而 `mqtt_client 10.5.0` 不支持 → 不建议为此换包 |

---

## 六、需要各端确认 / 同步的事项

### 6.1 同步给 PC 工程师（阿里云 / MQTT 服务器）

1. **修正 xlsx**：App ClientId 格式由 `app-设备码` 改为 `android-设备码`。
2. **修正 xlsx**：屏幕「业务账号」`3020-2.0` 请明确是 MQTT username 还是机型备注；MQTT username 建议与契约一致为 `screen-<deviceId>`。
3. **修正 xlsx**：驱动/PC 端身份，若指电脑端 ArtiMaker 请用 `pc-<userId>`；若主控板不独立联网请标注「不独立联网」。
4. **修正 xlsx**：阿里云桥接账号 username 填 `svc-bridge-aliyun-api`（ClientId 保持 `bridge-aliyun-api`）。
5. **补 Topic**：在清单中增加 `cnc/<deviceId>/cam`（摄像头状态）和 `cnc/<deviceId>/app`（App 在线/LWT）。
6. **补凭据**：把 `cam-cnc-demo-03` 和 `svc-bridge-aliyun-api` 写进 `deploy/users.json`，由 `emqx-init.py` 自动创建；同时清理旧的 `cam-cnc-demo-01`。
7. **确认 App ACL 通配改期**：当前 `app-demo` 枚举会阻塞白名单外机器，需给出改通配或改 authz 的时间点。
8. **开放 ACL deny 日志**：`deny_action=ignore` 后只能靠 Broker 日志定位静默丢包，请提供查询方式。

### 6.2 同步给 MQTT 服务器 / Broker 运维

1. `deploy/users.json` 补 `cam-cnc-demo-03` 和 `svc-bridge-aliyun-api`。
2. `contract/topics.json` 补 `cnc/<deviceId>/cam` 和 `cnc/<deviceId>/app`。
3. 清理线上旧的 `cam-cnc-demo-01` 客户端，避免与 `cam-cnc-demo-03` 混淆。
4. 开启/开放 ACL deny 审计日志。
5. 评估 `app-demo` 改通配或切 authz 绑定驱动的排期。

### 6.3 同步给摄像头团队

1. **确认切换后统一使用 `cnc-demo-03`**：
   - 订阅 `cnc/cnc-demo-03/cmd`
   - 发布 `cnc/cnc-demo-03/cam`
   - 推流 `POST {relay}/publish/cnc-demo-03?token=...`
2. **确认 username 改为 `cam-cnc-demo-03`**（与 ClientId、设备码同构）。
3. 确认旧 `cam-cnc-demo-01` 身份废弃。
4. 固件继续忽略非 `action` 字段帧（机器命令 `{"cmd":"hello"}` 等）。

### 6.4 同步给屏幕 / 固件团队

1. 屏幕 MQTT username / ClientId 保持 `screen-<deviceId>`（与契约一致）。
2. 若 PC 工程师要求共享业务账号（如 `3020-2.0`），需单独开会对齐，因为这会推翻当前契约和 ACL。
3. 确认心跳 `{"cmd":"hello"}` 由 App 经 `cnc/<deviceId>/cmd` 每 10s 下发，用于重置 15s Feed Hold。

### 6.5 App 端无需改动，但需知会

- App ClientId 已经是 `android-<deviceId>`，代码与契约一致。
- App 已不订阅 `cnc/<deviceId>/cam`，摄像头改主题后 App 不受影响。
- App LWT 主题 `cnc/<deviceId>/app` 已在使用，其他端如需感知 App 在线可订阅该主题。

---

## 七、可直接转发的短消息（给 PC/阿里云工程师）

> @Jason 我们已按《MQTT-Topic及账号清单.xlsx》和你的截图做了全量核对。
>
> **一致**：Topic 列表、设备码 = 机器码 = 摄像头码、`cnc/<deviceId>/...` 命名空间、`cnc/broadcast/#`、`sys/register` 均对齐。
>
> **需要修正/确认 4 处**：
> 1. App ClientId 请改为 `android-<deviceId>`（非 `app-`），代码与契约已按此落地。
> 2. 摄像头 username 请与 ClientId 同构，统一为 `cam-cnc-demo-03`（当前截图 username 是 01、clientId 是 03）。
> 3. 请补两个 Topic：`cnc/<deviceId>/cam`（摄像头状态）和 `cnc/<deviceId>/app`（App LWT/在线）。
> 4. 屏幕「业务账号」`3020-2.0` 请明确含义；MQTT username 建议与契约一致为 `screen-<deviceId>`。
>
> **需要入库 2 个账号**：`cam-cnc-demo-03`、`svc-bridge-aliyun-api` 写进 `deploy/users.json`，避免重新部署后认证失败。
>
> **建议**：旧 `cam-cnc-demo-01` 线上身份清理，避免混淆。

---

## 八、可直接转发的短消息（给 MQTT 服务器运维）

> 请处理：
> 1. `deploy/users.json` 增加 `cam-cnc-demo-03` 和 `svc-bridge-aliyun-api`。
> 2. `contract/topics.json` 增加 `cnc/<deviceId>/cam`、`cnc/<deviceId>/app`。
> 3. 清理线上 `cam-cnc-demo-01` 旧客户端。
> 4. 开启/开放 ACL deny 日志查询入口。
> 5. 给出 `app-demo` 改通配或切 authz 绑定驱动的时间点。

---

## 九、可直接转发的短消息（给摄像头团队）

> 摄像头切 `cnc-demo-03` 后请统一：
> - MQTT username = `cam-cnc-demo-03`
> - MQTT ClientId = `cam-cnc-demo-03`
> - 订阅 `cnc/cnc-demo-03/cmd`
> - 发布摄像头状态到 `cnc/cnc-demo-03/cam`
> - 推流设备码用 `cnc-demo-03`
> - 继续忽略非 `action` 字段的 MQTT 帧。
>
> App 端不订阅 `cnc/<deviceId>/cam`，你改主题后 App 无需改动。

---

## 十、下一步建议

1. **先让 PC 工程师确认/修正 xlsx**：重点 4 处（App 前缀、摄像头 username、屏幕业务账号含义、补 2 个 Topic）。
2. **MQTT 运维同步补凭据 + 补契约 + 开日志**。
3. **摄像头团队按 `cnc-demo-03` 全量统一后刷机**。
4. **App 端保持当前实现，不改动**；等设备码/账号统一后重新出包联调。

---

# 补充（2026-08-30 深夜）：摄像头端 relay 根治后的二次核对与三方基线

## 十一、摄像头端最新回复的消化

### 11.1 事实

摄像头团队已收尾，核心结论：

| 项 | 内容 |
|---|---|
| 现象 | 北京的 `cnc-relay` 客户端**每 3 秒强推一次 `stream_start`** |
| 根因 | relay 有一条「有观众但收不到新帧就补发 `stream_start`」的自愈逻辑；在**按需推流**架构下，这条逻辑变成死循环 |
| 修复 | 两台 `relay.py` 增加 `RELAY_MQTT_ENABLE` 开关，**默认关闭**（备份留存，置 1 可回滚），服务已重启 |
| 结果 | EMQX 上 `cnc-relay` 客户端归零；流控 **100% 由 App 独占**；`/stream` 拉流不受影响 |
| App 影响 | **零改动** |

### 11.2 这个发现的真正分量：过去的联调结论需要重测

这是本次最需要警惕的一点：

> **在 relay 自愈逻辑关闭之前，只要有人在拉流（或有观众记录），relay 就会每 3s 自动把摄像头"唤醒"。**
> 也就是说，此前任何「摄像头有画面 / 按需生效了」的观察，都**无法证明 App 的 `stream_start` 真的生效**——
> 可能是 relay 在背后托底。

**因此：所有涉及摄像头启停的结论，都必须在 relay MQTT 关闭后重测一遍。** 建议的最小验证集：

| # | 场景 | 预期 |
|---|---|---|
| 1 | App 完全不打开预览，静止 5 分钟 | 中继上该设备**无帧**，`/publish` 无请求 |
| 2 | App 打开预览 | 3–8 秒内出首帧（12s 内不报"无信号"） |
| 3 | App 退出预览 | 中继 10 秒内**停帧** |
| 4 | App 杀进程（不点退出）模拟异常 | 观察是否会持续推流（见 11.3 残留风险） |

### 11.3 残留风险：现在没有任何"兜底停推"了

自愈逻辑虽然有害，但它客观上也提供了"卡住时自动恢复"的能力。现在被关掉后：

- App 只在 `dispose()` 里发一次 `stream_stop`；
- 若 App 被系统杀进程、断网后 MQTT 断开、或用户直接切后台被回收 → **`stream_stop` 永远发不出去**；
- 结果：摄像头持续推流，回到我们要消灭的「24/7 常推」。

**建议的量产方案（App 续租 + 摄像头看门狗），既解决残留风险，又不重蹈死循环**：

```
App 在看流期间：每 30s 发一次 {"action":"stream_start"}   ← 幂等「续租」
摄像头固件：   90s 未收到任何 stream_start  → 自动停推
```

关键差别（这是死循环不复发的根本）：

| | relay 自愈（已废） | App 续租（建议） |
|---|---|---|
| 谁发起 | **中继**（中间节点） | **App**（唯一指令源） |
| 触发条件 | 有观众 + 无新帧 | 计时器，无条件 |
| 风险 | 与应用层状态打架 → 死循环 | 无反馈环，天然收敛 |

> 实现提示：续租可以让 `fullscreen_preview_page.dart` 在已连接状态下加一个 30s 周期定时器，
> 与现有 `_connSub` 补发逻辑合并即可（MQTT 晚连时补发 = 第一次续租）。

### 11.4 需要同步给 PC / 阿里云工程师的**强约束**（重要）

`docs/32` §1 里曾写过一句：
> 「MQTT 启停非唯一手段（中继反向通道 / 后端触发亦可）」

在 relay 根治之后，**这句话必须作废并反转**：

> 🔴 **后端（阿里云）与中继绝不能代发 `stream_start`。**
> 任何"中间节点看到没画面就帮忙发一条启动指令"的逻辑，都会重演今天的死循环。
> 流控指令的发起方**只能是 App**，且必须幂等。

请 PC 工程师在设计后端触发/自动化流程时明确排除这一路径。

---

## 十二、切换 `cnc-demo-03` 的真实定位：不是命名洁癖，是"真实联调"的开关

重新核对后的关键发现——**这是当前联调的第一优先级项**，原因如下：

| 模式 | App 使用的设备码 | 摄像头当前设备码 | 结果 |
|---|---|---|---|
| 演示模式（未登录/未选机器） | `cnc-demo-01`（`AppConfig.cameraRelayDevice` 兜底） | `cnc-demo-01` ✅ | 能看 |
| **真实模式 + 登录 `Lunyee@517788.xyz`** | **`cnc-demo-03`**（= `machine.sn`） | `cnc-demo-01` ❌ | **拉空 + 流控失效** |

具体到代码，登录后会**同时**断掉两条链路：

1. **拉流**：`Machine.streamUrl()` → `/stream/cnc-demo-03?token=...`，而摄像头推的是 `cnc-demo-01` → **一直无画面**；
2. **流控**：App 发 `cnc/cnc-demo-03/cmd`，摄像头订阅的是 `cnc/cnc-demo-01/cmd` → **`stream_start` 收不到**。

> 即：**只要不切 `cnc-demo-03`，登录后的真实链路就永远测不通**，而演示模式看着却是好的——
> 这是最容易误判成"App 有 bug"的坑。

**所以给摄像头团队的工单应当明确为**：不是"顺手统一命名"，而是
「把摄像头从演示态切到真实联调态」的必要步骤：

```
设备码 / MQTT username / MQTT clientId / 推流 device  → 全部统一为 cnc-demo-03
订阅   cnc/cnc-demo-03/cmd
发布   cnc/cnc-demo-03/cam
推流   POST {relay}/publish/cnc-demo-03?token=...
```

### ⚠️ 用户名必须是 `cam-cnc-demo-03`，不能沿用 `cam-cnc-demo-01`（2026-08-30 用户提出，已论证）

PC 工程师此前给出的参数是「用户名 `cam-cnc-demo-01` / ClientId `cam-cnc-demo-03` / 设备码 `cnc-demo-03`」，
**用户名这一项不符合规则**，必须改为 `cam-cnc-demo-03`。四条依据：

| # | 依据 | 内容 |
|---|---|---|
| 1 | **契约**（`contract/topics.json`） | `identities.camera`：username `cam-<deviceId>`；`identities_final.camera`：username 与 clientId **同为 `cam-<deviceId>`**，备注「与 `screen-<deviceId>` 使用同一设备码」 |
| 2 | **历史结论** | `docs/35` §5、`docs/36` §3.2④ 已两次建议改为 `cam-cnc-demo-03`，非新意见 |
| 3 | **broker 侧已按 03 落地**（已核实） | `deploy/users.json` 中账号为 `cam-cnc-demo-03`；`authz-rules-import.json` 中也是 `cam-cnc-demo-03` 的 6 条规则（83 条中） |
| 4 | **量产风险** | v4.2 方案 §5.1 要求「设备 Client ID 直接等于设备码」以便用动态 ACL `cnc/${clientid}/cmd`；username/clientId 与设备码脱钩，将来切绑定驱动会**授权错设备** |

**若继续用 `cam-cnc-demo-01` 会怎样**：

- 它**不在仓库里**，`emqx-init.py` 不会创建 → 现在能用纯属线上手工建的"不可复现"状态；
  服务器重建 / 迁移 / 重装 EMQX 后该账号消失 → 摄像头认证失败 → 按需推流整体失效；
- 它**不在导入规则里** → 授权只能靠文件源正则 `^cam-[a-z0-9-]+$` 兜底，属于"意外放行"而非"按规则授权"；
- 线上会出现「一个 `cam-cnc-demo-01` 的客户端在服务 `cnc-demo-03` 这台机器」的错配，排查时直接误导。

> **一句话**：设备码是 03，那么 username 和 clientId 就都必须是 03。
> 三者同构是契约要求，也是将来自动化授权能做对的前提。

**⚠️ 执行顺序不能反**：`cam-cnc-demo-03` 这个账号要等**部署第 4 步（`emqx-init.py` 建号）执行完才存在**。
因此必须先部署建号，再让摄像头切 03；若摄像头先切过去，会因账号不存在而连不上 MQTT。

```
① PC 工程师修正参数（username → cam-cnc-demo-03）
        ↓
② 有服务器权限者执行部署（docs/47：更新 acl.conf → 重启 → 建号 → 导入规则）
        ↓
③ 摄像头团队按 cnc-demo-03 全量刷机
        ↓
④ 联调验证
```

---

## 十三、三方（App / 摄像头 / MQTT）已冻结基线

> 用途：三方都按这 9 条对齐。**任何与下表冲突的外部文档（含 PC 工程师 xlsx）以本表为准**，
> 或走变更流程修订本表。

| # | 项 | 基线 | 状态 |
|---|---|---|---|
| 1 | 设备码语义 | 机器码 = 屏幕唯一码 = 摄像头码 = MQTT `deviceId`；联调值 `cnc-demo-03`，演示兜底 `cnc-demo-01` | ✅ 三方一致 |
| 2 | Topic 命名空间 | `cnc/<deviceId>/{cmd,status,notify,telemetry,log,job,sys,wizard,selfcheck,interact,push,tool_catalog,cam,app}` + `cnc/broadcast/#` + `sys/register` | ⚠️ `cam`/`app` 待进契约 |
| 3 | 单 cmd 主题多语义 | 机器 `{"cmd":...}` / 摄像头 `{"action":...}` / 心跳 `{"cmd":"hello"}`（10s）；摄像头**精确匹配 `action` 字段**，忽略其余 | ✅ 固件已 `json_get_action()` |
| 4 | 流控归属 | **App 独占**；relay 零 MQTT；摄像头固件自持 MQTT client 接收 | ✅ 已根治 |
| 5 | 身份命名 | App `android-<deviceId>`；屏幕 `screen-<deviceId>`；摄像头 `cam-<deviceId>`（username 与 clientId 同构）；云网关 clientId `bridge-aliyun-api` / username `svc-bridge-aliyun-api` | ⚠️ 摄像头 username 待改 03 |
| 6 | 命令路径 | 全部外网 MQTT 直发 `cnc/<deviceId>/cmd`；`gw/#` 与 `wan_whitelist` 已废弃 | ✅ |
| 7 | 编码 | 全链路 UTF-8 | ✅ |
| 8 | 心跳 / Feed Hold | App 每 10s `{"cmd":"hello"}`，固件 15s Feed Hold | ✅ |
| 9 | ACL | `cam-*` 发布 `cnc/+/cam|notify|telemetry`、订阅 `cnc/+/cmd`+广播；`deny_action=ignore`；App `app-demo` 当前枚举（待改通配/绑定驱动） | ⚠️ 待改通配 |

---

## 十四、PC 工程师（PC 软件 / 阿里云后台）待办清单

> 判断：App / 摄像头 / MQTT 三条 AI 任务轨已经跑到"可执行"的程度，
> PC 工程师侧偏慢。**建议不要一次性丢十几个开放问题给他们**，
> 而是按下面的 A/B/C 分级发出，A 类是阻塞项。

### A 类：阻塞真实联调（请优先）

| # | 事项 | 为什么阻塞 |
|---|---|---|
| A1 | 确认测试账号 `Lunyee@517788.xyz` 绑定的是 `cnc-demo-03`，且 `/api/machine/list` 返回的 `code` 字段就是 `cnc-demo-03` | App 用 `code` 当 `sn`，字段不对则整条链路用错设备码 |
| A2 | **（已作废）**原写「后台绑定表登记摄像头设备码」—— **不需要**，见下方说明 | 摄像头 ID 由机器 ID 派生，后台不单独维护 |

> **A2 作废说明（2026-08-30 用户指正，已核实）**：
> 按「统一机器码」决策，**摄像头 ID ≡ 机器 ID**，是**派生关系而非独立实体**。
> 因此阿里云后台的绑定表**只需要「客户账号 ↔ 机器 ID」，不需要为摄像头单列一条**。
> App 侧也是这么实现的（`machines_service.dart`、`fullscreen_preview_page.dart` 均以 `machine.sn` 为准，
> `camDevice` 只在 `sn` 为空时兜底）。我原先的表述会让 PC 工程师误以为要额外建一张摄像头绑定关系，**是误导**。
>
> **唯一仍需要"摄像头独立条目"的地方是 EMQX 的 MQTT 账号**（`cam-<deviceId>`）——
> 那是 **broker 认证基础设施**，不是业务绑定表，由 MQTT 轨负责（已写入 `users.json`，待部署）；
> 量产后由设备自注册自动完成，**后台始终不需要管**。
>
> **顺带建议（可选）**：后台 `/api/machine/list` 里的 `cam_device` / `cameraId` 字段
> 建议**不再返回**或**恒等于 `code`**。它现在是冗余字段，若将来被人填成别的值
> （如历史遗留的 `CNC-CAM01`），会造成"机器 ID 与摄像头 ID 不一致"的假象，排查时误导。
| A3 | 登录后机器信息下发「按账号签发、可过期」的**中继 token** + 「是否有权拉流」标记 | App 现在硬编码 `lunyee-cnc-relay-7k2p`，量产不可用 |
| A4 | 确认 `/api/device/bit-config/*` 中 `slot1~4` 的整数 = 系统刀具 id（1/2/3/5/8），以及更新后是否真的下发 MQTT | Step3 刀位已走真实数据，靠这个接口 |

### B 类：一致性修正（不阻塞，但会埋雷，建议本周内）

| # | 事项 | 应改为 |
|---|---|---|
| B1 | xlsx 中 App ClientId 前缀 | `app-设备码` → **`android-<deviceId>`** |
| B2 | 摄像头 username | `cam-cnc-demo-01` → **`cam-cnc-demo-03`**（与 clientId、设备码同构） |
| B3 | 屏幕「业务账号」`3020-2.0` | ✅ **已查实（2026-08-30 线上 acl.conf）**：是**真实 MQTT username**，生产机器直连账号（以机型命名，历史遗留）。**现在不要改**（改了会打断那台机器）；量产统一时再迁到 `screen-<deviceId>` |
| B4 | 驱动 / PC 端身份 | `driver-设备码` → **`pc-<userId>`**；若指主控板，请标注「不独立联网」 |
| B5 | 阿里云桥接 username | 「待定」→ **`svc-bridge-aliyun-api`**（clientId 保持 `bridge-aliyun-api`） |
| B6 | Topic 清单补两条 | 增加 `cnc/<deviceId>/cam`（摄像头状态）与 `cnc/<deviceId>/app`（App 在线/LWT） |
| B7 | 旧认知作废 | `docs/32` §1「中继反向通道 / 后端触发亦可」应删除；**后端与中继禁止代发 `stream_start`** |

### C 类：运维 / 仓库（可交给 MQTT 服务器轨，PC 工程师代转亦可）

| # | 事项 |
|---|---|
| C1 | `deploy/users.json` 补 `cam-cnc-demo-03`、`svc-bridge-aliyun-api`（否则重新部署后认证失败） |
| C2 | 清理线上旧的 `cam-cnc-demo-01` 客户端；移除 `users.json` 中残留的 `cnc-relay` 凭据（relay 客户端已归零） |
| C3 | **线上 `acl.conf` 拉回仓库对齐**（摄像头团队也提了同一条，防将来覆盖丢规则） |
| C4 | 开放 EMQX ACL deny 日志查询入口（`deny_action=ignore` 后静默丢包只能靠日志定位） |
| C5 | 给出 `app-demo` 枚举 → 通配（或切 authz 绑定驱动）的排期 |

### D 类：量产方向（需共同拍板，不急）

| # | 事项 |
|---|---|
| D1 | App username 策略：修订契约里的 `app-user-<userId>`，改为「静态账号 + authz 绑定驱动」（否则每注册一个客户就要建一个 EMQX 账号，不可运维） |
| D2 | 量产设备自注册（provisioning）方案：确认屏幕与摄像头是否**共用同一个 `deviceId` 走一次激活**，还是各自激活 |

---

## 十五、给 PC / 阿里云工程师的可转发消息（更新版）

> @Jason 三件事同步给你：
>
> **① 摄像头侧的根治已完成，但它揭示了一条强约束**
> relay 之前有一条"有观众但没新帧就补发 `stream_start`"的自愈逻辑，导致它每 3 秒强推一次启动指令，
> 在按需推流下变成死循环。已通过 `RELAY_MQTT_ENABLE=0` 关闭，EMQX 上 `cnc-relay` 客户端归零。
> **因此请明确：后端与中继都不能代发 `stream_start`，流控发起方只能是 App。**
> 另外，之前"摄像头有画面"的观察可能都是 relay 在托底，相关结论需要在新状态下重测。
>
> **② 摄像头切 `cnc-demo-03` 不是命名统一，是真实联调的开关**
> 演示模式用的是 `cnc-demo-01`；但登录后 App 会用机器 sn，你的测试账号绑的是 `cnc-demo-03`。
> 不切的话，登录后会同时断掉「拉流」（`/stream/cnc-demo-03` 拉空）和「流控」（`cnc/cnc-demo-03/cmd` 摄像头收不到）。
> 请一并确认：摄像头连 MQTT 用的 **username 也是 `cam-cnc-demo-03`**（不要 `cam-cnc-demo-01`）。
> ⚠️ 注意归属：这个 username 是 **MQTT（EMQX）的账号**，**不是阿里云后台的字段**。
> 阿里云后台里理论上只有「客户账号 ↔ 机器 ID（`cnc-demo-03`）」，**不需要、也不应该出现摄像头账号字段**。
>
> **③ 需要你确认/修正的清单（A 类阻塞，B 类本周内）**
> A1 测试账号绑定 `cnc-demo-03` 且 `/api/machine/list` 的 `code` 字段正确；
> A2 **（已作废，不用做）**——后台绑定表只有「客户账号 ↔ 机器 ID」；摄像头 ID 由机器 ID 派生，不单独登记。
> A3 登录后下发按账号签发的中继 token + 有权拉流标记（App 现在硬编码）；
> A4 刀仓 `bit-config` 的 `slot1~4` = 系统刀具 id（1/2/3/5/8），及更新后是否下发 MQTT。
> B1 App ClientId 前缀改 `android-<deviceId>`（不是 `app-`）；
> B2 你参数表里「摄像头用户名」那一栏请同步为 `cam-cnc-demo-03` —— 这一栏的来源在 **MQTT 账号表**（MQTT 侧已按 03 建好），**不在阿里云后台**；请你把它当"抄过来的值"更新，不要自行定义；
> B3 **（已有答案，无需再确认）**`3020-2.0` 已在线上 `acl.conf` 中找到 —— 它是**真实的 MQTT username**（一台生产机器直连用，以机型命名，历史遗留）。已原样保留、未动它。将来量产统一命名时再迁到 `screen-<deviceId>`，**现在不要改，改了会打断那台机器**；
> B4 驱动/PC 身份用 `pc-<userId>`（不是 `driver-`）；
> B5 阿里云桥接 username 填 `svc-bridge-aliyun-api`；
> B6 Topic 清单补 `cnc/<deviceId>/cam` 和 `cnc/<deviceId>/app`。
>
> 另：`deploy/users.json` 需要补 `cam-cnc-demo-03` 与 `svc-bridge-aliyun-api`，
> 并请把线上 `acl.conf` 拉回仓库对齐、开放 ACL deny 日志查询。

---

## 十六、下一步（更新后的优先级）

1. **安排摄像头切 `cnc-demo-03`**（username/clientId/订阅/发布/推流五处统一）—— 这是真实联调的前置。
2. **PC 工程师回 A1–A4**（阻塞真实联调的 4 项）。
3. **relay 关闭后重跑 11.2 的 4 个验证场景**，确认按需推流是真生效。
4. **补 stream_start 续租机制**（App 30s 续租 + 摄像头 90s 看门狗），消灭"App 被杀后常推"的残留风险。
5. B/C 类按周推进；D 类量产方向另行开会对齐。
6. App 端除「续租」外**无需其他改动**。

---

## 十七、通用能力模型：新增一台机器要过的 5 道门（2026-08-30 追加）

> **这是全文最重要的结论。** 讨论"能不能加机器"时不要锚定 `cnc-demo-04` 之类的具体编号——
> 那只是举例。**要的是机制：任意新增设备码都应无需任何 MQTT / App 侧改动即可工作。**

客户在阿里云后台被绑定一台新机器后，从"后台有数据"到"App 能控能看"，要过 5 道门：

| # | 环节 | 是否自动 | 归属 | 当前状态 |
|---|---|---|---|---|
| 1 | 后台写入绑定关系（账号 ↔ 设备码） | ✅ 自动 | 阿里云 | ✅ 已有 |
| 2 | App 机器列表出现 + 选中后驱动全部 topic / 拉流 / 刀仓 / 延时摄影 | ✅ **自动，App 零改动** | App | ✅ 已实现（`machine.sn` 单点驱动） |
| 3 | broker ACL 放行该设备码 | ⚠️ demo 期已自动 | MQTT | ✅ **已打通（2026-08-30 13:35 部署）**：`app-demo` 改通配 `cnc/+/...`，验收 `cnc/zzz-new-999/status` → ALLOW |
| 4 | 该机器摄像头的 MQTT 账号存在 | ❌ **人工** | MQTT | ⚠️ 部分缓解：`cam-cnc-demo-03` 已入 `users.json` 并建号；**新机器仍需手工建一个 `cam-<设备码>` 账号** |
| 5 | 摄像头固件设备码烧录为该机器码 | ❌ **人工** | 摄像头 | ⚠️ 进行中：摄像头端正在切 `cnc-demo-03` |

**结论（2026-08-30 更新）**：

- 前 **3** 道门已通 —— **任意新增设备码现在「加得进列表，也能控」**（命令/状态/遥测全通）。
- 剩下 4、5 道只影响**摄像头能力**：新机器加进来后，机器控制立即可用，
  但**摄像头要人工建账号 + 烧录设备码**才有画面。
- 第 3 道曾是最凶险的卡点：它不只让命令发不出去，还因为**订阅被拒**导致状态进不来 → Jog 锁死，
  且 `deny_action=ignore` 下界面毫无异常提示。**现已解除。**

**达成路径**：

| 阶段 | 做法 | 效果 |
|---|---|---|
| **demo 期（现在）** | 第 3 道改**通配** `cnc/+/...`；第 4 道手工补账号并入库；第 5 道逐台烧录 | 任意设备码可用，但每加一台仍需人工建账号 |
| **量产** | 第 3 道改 **authz 绑定驱动**（EMQX 接 037123 绑定关系）；第 4/5 道由**设备自注册（provisioning）**自动完成 | 加机器 = 纯后台操作，全链路零人工 |

> 对应工单见 `docs/37-mqtt-track-action-list-20260830.md` 的 P0-1（通配）与 P2-2（绑定驱动 + 自注册）。

---

## 十八、三层字段归属（2026-08-30 用户指正，已核定）

> **这一节用来防止再犯同类错误。** 讨论任何"设备码/账号/ID"时，先看清它属于哪一层。

| 层 | 谁拥有 | 里面有什么 | 举例 |
|---|---|---|---|
| **① 业务层（阿里云后台）** | PC / 阿里云工程师 | 只有 **客户账号 ↔ 机器 ID** 一张绑定表 | `Lunyee@517788.xyz` → `cnc-demo-03` |
| **② 通信层（EMQX / MQTT）** | MQTT 服务器轨 | **MQTT 账号（username/clientId）+ 密码 + ACL 规则** | `cam-cnc-demo-03` / `demo123` |
| **③ 设备层（固件）** | 摄像头轨 / 固件轨 | 烧进设备里的设备码、连 MQTT 用的凭据 | 设备码 `cnc-demo-03`，用 ② 的账号去连 |

**两条铁律**：

1. **摄像头 ID、屏幕 ID 都是机器 ID 的派生值，不是独立实体。**
   业务层（阿里云）**只登记机器 ID 一个**，不为摄像头/屏幕单开列。
   → 所以 `docs/36` §十四 A2「后台绑定表登记摄像头设备码」**作废**（§十五的转发消息已同步改）。
2. **"username/clientId" 这种带前缀的账号名，只存在于 ② 通信层。**
   它**不是阿里云后台的字段**，也不该出现在阿里云的接口/绑定表里。
   → 所以我此前"让 PC 工程师把用户名改成 `cam-cnc-demo-03`"这句**指向错了**：
     - ❌ 不是说给 PC 工程师去"定义"这个账号（他会误以为阿里云后台要加字段）；
     - ✅ 正确说法是：PC 工程师参数表里的「摄像头用户名」一栏，**值要从 MQTT 账号表抄过来**（MQTT 侧已按 03 建好），不要自行定义；
     - ✅ 真正需要动手改的是**摄像头端烧录参数**（设备码 03 + username `cam-cnc-demo-03` + clientId `cam-cnc-demo-03`）。

**执行顺序不可颠倒**：

```
① MQTT 侧建号 cam-cnc-demo-03（deploy/users.json 已就绪，待部署上线）
        ↓
② PC 工程师把参数表里的「用户名」一栏同步为 cam-cnc-demo-03（只是改文档/对接值）
        ↓
③ 摄像头端烧录：设备码 cnc-demo-03 + username/clientId = cam-cnc-demo-03
        ↓
④ 三方联调验证
```

> 第 ① 步没上线上服务器之前，第 ③ 步烧了也连不上。

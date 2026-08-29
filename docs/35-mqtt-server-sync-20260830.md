# MQTT 服务器 / Broker 任务轨 — 待同步与确认清单（2026-08-30）

来源：App 端与摄像头端近期排查中识别出的、归属 **EMQX broker / 契约（`contract/topics.json`）/ 部署仓库（`cnc-control-server`）** 的事项。
App 侧与摄像头侧已闭环的部分列在文末「已闭环」，供对照，无需再动。

---

## 一、待办（未完，需 MQTT 轨处理）

### 1. `app-demo` ACL 枚举 → 通配（已与摄像头侧商定**延后**，勿丢失）

- 现状：`deploy/acl.conf:5-6` 与 `deploy/users.json` 中，`app-demo` **只**放行 `cnc-demo-01/02/03`。
- 影响：App 的 `deviceId` 是用户动态选择的机器 sn，**控制白名单外的机器时命令被静默丢弃**
  （`deny_action` 已改 `ignore`，不再断线，因此**没有任何可见报错**）。
- 状态：已商定等 App 稳定后再改，但**请纳入 backlog，不要在交接中丢失**。

> **强力佐证——这不算新需求，是仓库与自家契约不一致**：
> `contract/topics.json` 的 `identities_final.acl_model` 原文即
> 「按 username 维度 + topic 通配（`cnc/+/cmd` 等），不依赖 `${clientid}` 动态模板」。
> 也就是说**契约本身就规定通配**，`deploy/acl.conf` 的枚举是与契约不符的实现偏差。
> 屏幕端 `screen-cnc-demo-*` 已是通配 `cnc/+/...`，只有 App 是枚举。

### 2. 🔴 摄像头（cam）认证凭据**未入库**，存在丢失风险

- `deploy/users.json` 中**没有任何 `cam-*` 账号**（已核实）。
- 而 `deploy/scripts/emqx-init.py` 正是**按 `users.json` 批量创建账号**的
  （`PUT/POST /api/v5/authentication/{id}/users`）。
- 摄像头固件当前**确实在连 MQTT**（会发 `{"online":true}`，已实烧验证）→
  说明线上的 `cam-cnc-demo-01` 账号是**手工创建**的，**没有落到仓库**。

**风险**：重新部署 / 重建容器时，cam 账号不会被自动创建 →
摄像头认证失败、连不上 MQTT → **收不到 `stream_start` / `stream_stop` → 按需推流整体失效**
（画面会一直「无信号」，且因 `deny_action=ignore` 而无任何告警）。

**建议**：把 `cam-<deviceId>`（当前 `cam-cnc-demo-01`，口令 `demo123`）写进 `users.json`，
由 `emqx-init.py` 自动创建；量产接入时改为绑定驱动签发。

### 3. 请开放 EMQX 的 ACL deny 日志 / 审计

- 背景：摄像头侧已将 `deny_action` 由 `disconnect` 改为 `ignore`（避免旧固件摄像头被反复踢下线）。
  副作用是**被拒绝的发布不再有任何可见症状**。
- 因此「命令无效但连接正常」这类问题，只能靠 broker 侧日志定位。
- **请求**：开启并开放 ACL deny 日志（或审计日志）的查询入口，并告知各端查询方式。

---

## 二、契约不一致（需修订）

### 4. App 的 username 存在**三方不一致**

| 来源 | App username | 与契约一致？ |
|---|---|---|
| `contract/topics.json` → `identities.app.username` | `app-user-<userId>` | — |
| `contract/topics.json` → `identities_final.android_app.username` | `app-user-<userId>` | — |
| App 代码 `AppConfig.mqttUser` | `app-demo` | ❌ 不一致 |
| `deploy/acl.conf` / `deploy/users.json` | `app-demo` | ❌ 不一致 |

- clientId 是一致的：契约 `android-<deviceId>`，App 代码 `'android-$deviceId'` ✅
（历史上的 `app-app-demo` 双前缀问题已修复）。
- **只有 username 不一致**，demo 期无感（两边都是 `app-demo`），但量产会踩。

**建议：修订契约，去掉 `app-user-<userId>`，改为「静态账号 + authz 绑定驱动授权」。**
理由：把 userId 编进 username 意味着**每注册一个客户都要在 EMQX 里建一个账号**，
运维上不可行；而量产方案本就要走「绑定驱动」（authz 接 037123 绑定），账号应保持静态。

### 5. 契约缺 `cnc/<deviceId>/cam` 主题条目

摄像头状态上报已由 `cnc/<deviceId>/status` 改为 `cnc/<deviceId>/cam`
（ACL 层也已同步，`cam-*` 的 publish 已改为 `cnc/+/cam`）。
建议在 `topics.json` 补上该主题并注明：**摄像头状态上报用，App 当前不订阅**
（App 为显式逐一订阅，无通配，因此收不到也不会收）。

### 6. 建议清理 relay 的遗留 MQTT 身份

HK 线上有 2 个 `cnc-relay` 客户端在线（订阅数 0、无收发），与 §「relay 零 MQTT 依赖」
的架构决策不符。当前 ACL 未授予其权限，无害。
建议确认 relay 是否真的不需要任何 MQTT 能力；若不需要，从 `users.json` / ACL 移除其凭据，
避免遗留凭证长期挂着。

---

## 三、已闭环（知会即可，无需再动）

| 项 | 状态 |
|---|---|
| `cam-*` 的 publish 由 `cnc/+/status` 改为 `cnc/+/cam`（权限层根除旧固件污染 status） | ✅ 已执行并验证，5 客户端重连 |
| `deny_action`：`disconnect` → `ignore` | ✅ 已执行（避免摄像头被反复踢下线） |
| 摄像头流控指令归属：由**摄像头固件自带 MQTT client** 接收，relay 零 MQTT 依赖 | ✅ 架构已钉死，固件已改待烧录 |
| 摄像头 payload 精确匹配（新增 `json_get_action()`，`strstr` 子串误触发已根治） | ✅ 固件侧完成 |
| 摄像头心跳 `{"cmd":"hello"}`（10s）被正确忽略 | ✅ 固件侧完成 |
| App clientId `android-<deviceId>` | ✅ 与契约一致 |
| MQTT 载荷编码统一 UTF-8（App 侧已改 `utf8.decode` + 容错） | ✅ 已写入 `docs/PROTOCOL.md` §1 第 4 条 |

---

## 四、量产方向（需共同确认）

- **通配只是 demo 期便利**，量产必须切**绑定驱动**：账号下发设备列表 + EMQX authz 接 037123 绑定。
  **App 侧不会把通配写进终态设计**，请 MQTT 轨同步按此方向设计 authz。
- 固件侧 `{"cmd":"hello"}` 心跳（App 每 10s 发一次，用于重置固件 15s Feed Hold 计时器）
  需持续可用，请确认 ACL 在任何阶段都不会拦掉 App 对 `cnc/<deviceId>/cmd` 的发布。

---

## 五、联调设备码切换到 `cnc-demo-03` 的核对（2026-08-30，PC/阿里云工程师提出）

PC 侧为联调提出摄像头改用下列参数（测试账号 `Lunyee@517788.xyz` 已绑定机器 `cnc-demo-03`）：

| 项 | 提议值 |
|---|---|
| username | `cam-cnc-demo-01`（仅测试阶段） |
| clientId | `cam-cnc-demo-03` |
| 设备码 | `cnc-demo-03` |

### ✅ 设备码 `cnc-demo-03` 完全正确，与 App 侧链路严格对齐

已核对 App 侧三条链路**全部以「机器码 = sn」作为摄像头设备码**：

| App 链路 | 代码依据 | 使用设备码 |
|---|---|---|
| 流控指令（stream_start/stop） | `fullscreen_preview_page.dart` `_cameraDeviceId` = `machine.sn`，发到 `cnc/<sn>/cmd` | `cnc-demo-03` |
| 拉流 | `Machine.streamUrl()` → `${relay}/stream/$sn?token=` | `cnc-demo-03` |
| 状态主题（将来） | `cnc/<deviceId>/cam` | `cnc-demo-03` |

因此摄像头端**必须**三处统一为 `cnc-demo-03`：
- 订阅 `cnc/cnc-demo-03/cmd`
- 发布 `cnc/cnc-demo-03/cam`
- 推流 `POST {relay}/publish/cnc-demo-03?token=`

> 另：这正是「**统一机器码**」方案的落地 —— 摄像头与屏幕共用同一 `deviceId`。
> 共用后摄像头会同时收到机器命令帧，但固件已有 `json_get_action()` 精确匹配兜底
> （只认 `action` 字段），`{"cmd":"jog"}` / `{"cmd":"hello"}` 均被忽略，无冲突。

### ⚠️ 建议改一处：username 与 clientId 应同构，都用 `cnc-demo-03`

契约要求二者**同构且等于设备码**：
- `contract/topics.json` → `identities.camera`：`username: "cam-<deviceId>"`、
  `clientIdPrefix: "cam-"`，备注「**与 screen-<deviceId> 使用同一设备码**」
- `identities_final.camera`：`username: "cam-<deviceId>"`，`clientId: "cam-<deviceId>"`

提议值里 username 用 `cnc-demo-01`、clientId 用 `cnc-demo-03`，**两者指向不同设备**。

**demo 期能跑吗？能**（ACL 是 `{username, {re, "^cam-[a-z0-9-]+$"}}` 前缀正则 + `cnc/+/` 通配主题，
不校验设备码）。但有两个后患：

1. **量产切绑定驱动时会授权错设备**：authz 若按 username 解析设备码，会把这台摄像头
   授权给 `cnc-demo-01`，而它实际服务 `cnc-demo-03`。
2. **留下错误范式**：username 与设备码脱钩后，后续接入的人会照抄，排查时极易误导
   （线上会看到一个 `cam-cnc-demo-01` 的客户端在服务 demo-03）。

**建议：username 一并改为 `cam-cnc-demo-03`**（clientId 同步）。改动成本几乎为零。

### 🔴 关联：凭据必须落库（承接第一节第 2 条）

切换后，broker 需要存在的账号是 **`cam-cnc-demo-03`**（若沿用提议则为 `cam-cnc-demo-01`）。
请**写进 `deploy/users.json`** 由 `emqx-init.py` 自动创建 ——
**不要只在 HK 线上手工建**，否则重新部署即丢失，摄像头认证失败 → 收不到 `stream_start` →
按需推流整体失效（且 `deny_action=ignore` 下无任何告警）。

### ✅ 一个好消息：`cnc-demo-03` 正好在 `app-demo` 的白名单内

`app-demo` 枚举 ACL 放行 `cnc-demo-01/02/03` —— 选 `cnc-demo-03` **不会被静默丢弃**。
（若选 `cnc-demo-04` 就会被拒。这也再次印证第一节第 1 条「改通配」的必要性：
设备码一变就断，是不可持续的。）

### 需 PC / MQTT / 摄像头三方确认的小项

1. username 是否同意改为 `cam-cnc-demo-03`（与 clientId、设备码同构）？
2. `users.json` 由谁补凭据并推仓库？
3. 旧的 `cam-cnc-demo-01` 线上身份是否清理，避免与新配置混淆？
4. 后端（037123）绑定表中，摄像头设备码是否也已登记为 `cnc-demo-03`、
   并确保与机器 `cnc-demo-03` 归属同一测试账号？

---

## 六、需要 MQTT 轨回复的问题（汇总）

1. `app-demo` 通配改期到什么时候？能否先给个时间点，便于 App 排联调？
2. `cam-cnc-demo-01` 凭据准备何时写进 `users.json`（由 `emqx-init.py` 自动创建）？
3. ACL deny 日志能否开放查询？查询方式是什么？
4. 契约里的 `app-user-<userId>` 是否同意改为「静态账号 + authz 绑定驱动」？若同意，谁来改契约？
5. `cnc/<deviceId>/cam` 是否补进 `topics.json`？
6. relay 的 MQTT 身份是否清理？

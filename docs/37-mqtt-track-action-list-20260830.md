# MQTT 服务器 / EMQX Broker 任务轨 — 待办工单（2026-08-30 合并版）

> 合并了 2026-08-29 夜间识别项（`docs/35`）与 2026-08-30 摄像头 relay 根治后的新增项（`docs/36`）。
> **本文按优先级给出「现状 → 改成什么（含可直接粘贴的配置）→ 验收方法」**，MQTT 轨可按文执行，无需再回问。
> 已闭环项列在文末，请勿重复劳动。

---

## 零、为什么要现在动（一句话）

当前 **App 只能控制 `cnc-demo-01/02/03` 三台**，且**摄像头账号不在仓库里**。
这直接阻断了「后台给客户加一台新机器 → App 自动可用」这条主链路，
也意味着**重新部署 EMQX 会静默弄坏摄像头按需推流**。

> **本工单的目标不是让某台具体机器（如 `cnc-demo-04`）可用 —— 那只是举例。**
> 目标是建立**通用能力**：`阿里云后台新增任意一台机器 → App 立即可用 → MQTT/broker 侧零改动`。
> 因此下文所有验收都应以「任意新增设备码」为准，而不是挑一台白名单内的机器测试。
> demo 期用「通配」达成，量产用「authz 绑定驱动 + 设备自注册」达成（见 P2-2）。
>
> **背景模型**：新增一台机器要过 5 道门，前 2 道（后台绑定、App 显示并驱动全部 topic）
> 已全自动，**卡在第 3 道（ACL）与第 4 道（cam 账号）**，详见
> `docs/36-account-topic-consistency-check-20260830.md` §十七。

---

## 一、P0 — 阻塞真实联调（请优先）

### P0-1 🔴 `app-demo` 的 ACL 从「枚举」改为「通配」

**现状**（`deploy/acl.conf:5-6` 与 `deploy/users.json`）：

```
publish   : cnc/cnc-demo-01|02|03/{cmd,app,wizard,interact,push} + gw/*/cmd
subscribe : cnc/cnc-demo-01|02|03/{status,notify,telemetry,log,job,sys,wizard,selfcheck,interact,push} + broadcast + gw/+/ack
```

**问题**：App 的 `deviceId` 是用户在机器列表里动态选的 `machine.sn`。白名单外的机器：

- 发布被拒 → 命令石沉大海（`deny_action=ignore`，**无任何报错**）；
- **订阅也被拒** → 收不到状态帧 → 状态永远不是 `idle` → **Jog 被锁死**。

> 界面会显示「MQTT 已连接」，点了没反应也不报错 —— 这是最难排查的一类故障。

**这不是新需求，是仓库与自家契约不一致**：
`contract/topics.json` → `identities_final.acl_model` 原文即
「按 username 维度 + topic 通配（`cnc/+/cmd` 等），不依赖 `${clientid}` 动态模板」。
屏幕端 `screen-cnc-demo-*` 早已是通配 `cnc/+/...`，**只有 App 还是枚举**。

**改为**（`deploy/acl.conf`，替换 app-demo 那两行；`gw/*` 已废弃，一并清掉）：

```erlang
%%% App 用户 (app-demo) — 通配：任意设备码均可控（demo 期）
{allow, {username, "app-demo"}, publish, ["cnc/+/cmd", "cnc/+/app", "cnc/+/wizard", "cnc/+/interact", "cnc/+/push"]}.
{allow, {username, "app-demo"}, subscribe, ["cnc/+/status", "cnc/+/notify", "cnc/+/telemetry", "cnc/+/log", "cnc/+/job", "cnc/+/sys", "cnc/+/wizard", "cnc/+/selfcheck", "cnc/+/interact", "cnc/+/push", "cnc/broadcast/#"]}.
```

`deploy/users.json` 需同步（供 `emqx-init.py` 重建）：

```json
{"permission":"allow","principal":"username","username":"app-demo","topics":["cnc/+/cmd","cnc/+/app","cnc/+/wizard","cnc/+/interact","cnc/+/push"],"action":"publish"},
{"permission":"allow","principal":"username","username":"app-demo","topics":["cnc/+/status","cnc/+/notify","cnc/+/telemetry","cnc/+/log","cnc/+/job","cnc/+/sys","cnc/+/wizard","cnc/+/selfcheck","cnc/+/interact","cnc/+/push","cnc/broadcast/#"],"action":"subscribe"}
```

> ⚠️ **若 HK 线上的 EMQX 已手工改成通配**：请把线上配置**拉回仓库**，
> 否则下次重新部署会用仓库里的枚举版覆盖回去，问题复发且更难定位。

**硬约束**：`cnc/+/cmd` 的 publish 在**任何阶段**都不得拦截 ——
App 每 10s 往这里发 `{"cmd":"hello"}`，用于重置固件的 15s Feed Hold 定时器，
被拦会导致加工中误暂停。

**验收**：

> **验收取「任意设备码」，不要挑白名单内的机器**（下文 `cnc-demo-04` 仅为举例，
> 换成任何一台新增机器都应同样通过 —— 这才是本条要达成的能力）。

1. `mosquitto_sub -h 43.154.192.242 -p 8883 -u app-demo -P demo123 -t 'cnc/<任意新增设备码>/status' -d` → SUBACK 成功（**不是 0x80**）；
2. `mosquitto_pub ... -t 'cnc/<任意新增设备码>/cmd' -m '{"cmd":"hello"}'` → ACL deny 日志**无记录**；
3. App 选中这台（任意新增的）机器 → 状态能进来、Jog 解锁、命令有响应。

**通用性判据（本条真正要的结果）**：
> 今后在阿里云后台给任意账号新增任意一台机器，
> **MQTT / broker 侧改动量 = 0**，App 侧改动量 = 0。
> 若做不到，说明仍是枚举/人工模式，本条未完成。

**⚠️ 改 ACL 必须同时改两个源（2026-08-30 MQTT 轨实测，见 §七）**

线上是**内置数据库（users.json rules）优先 + 文件源（acl.conf）回退**，实际权限取**并集**。
因此：只改其中一个**不算改完**；且**线上删掉 ≠ 生效** —— 若内置数据库里仍残留旧规则
（如 `gw/+/ack`、可能的 `cnc-relay`），文件源删了也没用，必须在 Dashboard 同步导入新 rules。

---

### P0-2 🔴 摄像头凭据 `cam-cnc-demo-03` 必须入库

**现状**：`deploy/users.json` 中**没有任何 `cam-*` 账号**；
而 `deploy/scripts/emqx-init.py` 正是按 `users.json` 批量建号的。
线上现在的 cam 账号是**手工创建**的，**没落仓库**。

**风险**：重新部署 / 重建容器 → cam 账号不会被创建 → 摄像头认证失败 →
**收不到 `stream_start`/`stream_stop` → 按需推流整体失效**，
且因 `deny_action=ignore` 而**没有任何告警**（画面就是一直"无信号"）。

**背景**：联调设备码已从 `cnc-demo-01` 切到 **`cnc-demo-03`**
（测试账号 `Lunyee@517788.xyz` 绑定的是 `cnc-demo-03`）。

**改为**：

```json
"users": {
  "...": "...",
  "cam-cnc-demo-03": "demo123"
}
```

ACL 侧**已就绪**，无需改动（`deploy/acl.conf:33-34` 已用正则覆盖全部 cam）：

```erlang
{allow, {username, {re, "^cam-[a-z0-9-]+$"}}, publish,   ["cnc/+/cam", "cnc/+/notify", "cnc/+/telemetry"]}.
{allow, {username, {re, "^cam-[a-z0-9-]+$"}}, subscribe, ["cnc/+/cmd", "cnc/+/tool_catalog", "cnc/broadcast/#"]}.
```

> 若线上走的是 `users.json` 里的 rules（而非文件 ACL），则需同步补 cam 的 rules 条目。
> 请确认线上授权源到底是哪一个，并把答案告知各端。

**验收**：EMQX Dashboard / CLI 能看到 `cam-cnc-demo-03` 在线；
重新跑一次 `emqx-init.py` 后该账号依然存在。

---

### P0-3 🟠 云网关账号 `svc-bridge-aliyun-api` 入库 + 授权

**现状**：`deploy/users.json` **没有这个账号**。阿里云后台若已用它在连 MQTT，
重新部署会直接认证失败。

**改为**：

```json
"users": { "...": "...", "svc-bridge-aliyun-api": "<独立高熵密码，勿与设备账号同密>" }
```

```erlang
%%% 阿里云后台：只发布，不订阅（订阅由末尾 {deny, all} 兜底拒绝）
{allow, {username, "svc-bridge-aliyun-api"}, publish, ["cnc/+/cmd", "cnc/+/tool_catalog"]}.
```

**验收**：该账号 publish `cnc/<任意>/cmd` 成功；subscribe 任意主题被拒。

---

## 二、P1 — 一致性与防丢失（本周内）

### P1-1 线上 `acl.conf` 拉回仓库对齐

摄像头轨已独立提出同一条。**线上与仓库若已分叉**，下次部署会用旧文件覆盖线上规则，
导致已修好的 cam 权限、`deny_action` 等全部回退。请以**线上为准**拉回，并 diff 后提交。

### P1-2 `contract/topics.json` 补两条主题

```json
"cam": "cnc/{deviceId}/cam",
"app": "cnc/{deviceId}/app"
```

并在 `qos` / `retain` 中补齐：

| 主题 | 用途 | QoS | Retain |
|---|---|---|---|
| `cnc/<deviceId>/cam` | 摄像头状态上报（`{"streaming":bool}` / `{"online":true}`）。**App 当前不订阅** | 1 | **false**（摄像头已确认为 0，避免重连时反复触发） |
| `cnc/<deviceId>/app` | App 在线状态（LWT `{"online":false}` + 上线 `{"online":true}`，仅 App 使用） | 1 | **true**（App 侧 publish 带 retain） |

### P1-3 清理 `cnc-relay` 的遗留身份

摄像头轨已根治：relay 内「有观众但收不到新帧就补发 `stream_start`」的自愈逻辑
在按需推流下变成死循环（每 3s 强推一次）。已在两台 `relay.py` 加 `RELAY_MQTT_ENABLE=0`，
服务重启，**EMQX 上 `cnc-relay` 客户端已归零**。

**仍需做**：从 `users.json` / ACL 中**移除 `cnc-relay` 的凭据** —— 客户端虽已归零，
凭证还在库里，将来可能被误启用，**绝对不要再给它任何 MQTT 权限**。

### P1-4 清理线上旧的 `cam-cnc-demo-01` 客户端

切 `cnc-demo-03` 后该身份废弃。线上若仍在线，会与 `cam-cnc-demo-03` 混淆，
排查时极易误导（看到一个 demo-01 的客户端在服务 demo-03）。

---

## 三、P2 — 可观测性与量产方向

### P2-1 开放 ACL deny 审计日志

`deny_action` 由 `disconnect` 改为 `ignore` 后，**被拒绝的发布不再有任何可见症状**。
「命令无效但连接正常」这类问题只能靠 broker 侧日志定位。
**请开启 ACL deny 日志并告知各端查询方式**（这是后续所有静默故障的唯一抓手）。

### P2-2 量产方向：从「通配」走向「绑定驱动 + 设备自注册」

- **通配只是 demo 期便利**，App 侧不会把它写进终态设计。
- 量产必须切 **authz 绑定驱动**：账号服务下发设备列表，EMQX authz 接 037123 绑定关系。
- 配套需要 **设备自注册（provisioning）**：设备用出厂密钥换正式 MQTT 账号 + 权限，
  自动写入 broker（`2026-08-24-mqtt-device-provisioning-design.md` 已有方案）。
- **需共同拍板**：屏幕与摄像头是否**共用同一个 `deviceId` 走一次激活**？
  当前决策是「机器码 = 屏幕唯一码 = 摄像头码」，倾向共用一次激活，请确认可行性。

### P2-3 一个待修订的契约条目

`contract/topics.json` → `identities.app.username = "app-user-<userId>"`
意味着**每注册一个客户就要在 EMQX 建一个账号**，运维上不可行。
**建议修订为「静态账号 + authz 绑定驱动授权」**（与 MQTT 三端互通方案 v4.2 一致）。
App 侧 clientId 已是 `android-<deviceId>`，与本条无关，无需改动。

---

## 四、已闭环（请勿重复劳动）

| 项 | 状态 |
|---|---|
| `cam-*` 的 publish 由 `cnc/+/status` 改为 `cnc/+/cam`（根除旧固件污染 status） | ✅ 已执行并验证 |
| `deny_action`：`disconnect` → `ignore` | ✅ 已执行 |
| relay 每 3s 强推 `stream_start` 的死循环（`RELAY_MQTT_ENABLE=0`） | ✅ 已根治，客户端归零 |
| 流控指令归属：摄像头固件自带 MQTT client 接收，relay 零 MQTT 依赖 | ✅ 架构已钉死 |
| 摄像头 payload 精确匹配（`json_get_action()`，`strstr` 子串误触发已根治） | ✅ 固件侧完成 |
| App clientId `android-<deviceId>` | ✅ 与契约一致（App 侧，broker 无需改动） |
| MQTT 载荷编码统一 UTF-8 | ✅ 已写入 `docs/PROTOCOL.md` §1 第 4 条 |
| `gw/#` 网关转发与 `wan_whitelist` 废弃 | ✅ App / 云网关均直发 `cnc/<deviceId>/cmd` |

---

## 五、一条强约束（请各端共同遵守）

> **任何"中间节点看到没画面就帮忙发一条启动指令"的逻辑都会重演 relay 死循环。**
> 流控指令的发起方**只能是 App**，且必须幂等。

**适用范围（2026-08-30 澄清：原措辞有歧义，曾导致 MQTT 轨误判，此处收窄）**

| 账号类型 | 能否 publish `cnc/+/cmd` | 理由 |
|---|---|---|
| **自动自愈 / 中继型节点**（如已废弃的 `cnc-relay`） | ❌ **绝对禁止** | 它没有"人"的决策，会形成「无画面 → 补发 → 又无画面」的反馈环，这正是已根治的死循环根因 |
| **云网关 `svc-bridge-aliyun-api`** | ✅ **允许** | 设计上合法的云端命令通道（v4.2 方案 §10「后台定向发布」）；不给它 cmd 发布权，该账号形同虚设 |
| 云网关的**使用边界** | ⚠️ 限定 | 仅限**响应用户显式操作**（用户点了才发）；**严禁**实现任何"自动检测 + 自动补发 `stream_start`"的逻辑 |

> 一句话判据：**能自动触发的，不给权限；由人触发的，可以给。**

---

## 六、可直接转发的消息

> @MQTT 服务器 这边把待办合并成了一份工单，按 P0/P1/P2 排好，每条都给了可直接粘贴的配置和验收方法：
> `docs/37-mqtt-track-action-list-20260830.md`（仓库 wangalex130-netizen/alexcnc，main）
>
> **P0（阻塞联调，请优先）**
> 1. `app-demo` ACL 枚举 → 通配 `cnc/+/...`（契约 `identities_final.acl_model` 本来就要求通配，屏幕端早已是通配，只有 App 是枚举）。
>    不改的话：App 控制 demo-01/02/03 以外的机器时，发布和订阅都被静默拒绝，状态进不来导致 Jog 锁死，界面还显示"已连接"。
>    ⚠️ 若线上已手工改成通配，请把线上拉回仓库，否则下次部署会被仓库里的枚举版覆盖。
> 2. `cam-cnc-demo-03` 写进 `deploy/users.json`（现在是线上手工建的，重新部署会丢 → 摄像头认证失败 → 按需推流整体失效且无告警）。ACL 侧已用 `^cam-[a-z0-9-]+$` 正则覆盖，不用改。
> 3. `svc-bridge-aliyun-api` 入库 + 授权 publish `cnc/+/cmd`、`cnc/+/tool_catalog`，订阅全部拒绝。
>
> **P1（本周内）**
> 4. 线上 `acl.conf` 拉回仓库对齐（摄像头那边也提了同一条）。
> 5. `contract/topics.json` 补 `cnc/<deviceId>/cam`（QoS1 / retain=false）和 `cnc/<deviceId>/app`（QoS1 / retain=true）。
> 6. 移除 `cnc-relay` 的遗留凭据，且**不要再给它任何 MQTT 权限**。
> 7. 清理线上旧的 `cam-cnc-demo-01` 客户端。
>
> **P2（可观测性 / 量产）**
> 8. 开放 ACL deny 审计日志并告知查询方式（`deny_action=ignore` 之后这是唯一抓手）。
> 9. 量产方向：authz 绑定驱动 + 设备自注册；请确认屏幕与摄像头是否共用同一个 `deviceId` 走一次激活。
>
> 另：契约里 `app-user-<userId>` 建议改为「静态账号 + authz 绑定驱动」，否则每注册一个客户就要建一个 EMQX 账号。

---

## 七、回执：MQTT 轨的核定结论与落地状态（2026-08-30 收到）

MQTT 轨已回执，完整记录见 `cnc-control-server/docs/46-mqtt-acl-two-source-findings-and-apply-20260830.md`。
核心结论三条：

| # | 结论 | 影响 |
|---|---|---|
| 1 | **线上是两个授权源并集**：内置数据库（users.json rules）优先，未匹配回退文件源（acl.conf） | 改 ACL 必须**两个源都改**；且线上删除不等于生效，需 Dashboard 同步导入 |
| 2 | **线上没被改成通配**，任意新增设备码订阅返回 `0x80` | P0-1 不是"怕被覆盖"，是**现在就坏** —— 印证了本工单的判断 |
| 3 | 发现**根因级陷阱**：`emqx-init.py` 会用 users.json 反向覆盖生成 acl.conf，而 users.json 写不了正则 → 会丢失 cam 正则、cnc-server，以及 08-29 摄像头安全修复 | 已改为 `--write-acl` 显式开启才执行。**这是"重新部署会静默弄坏"的真正根因** |

**仓库侧已全部改完**（app-demo/pc-demo/screen 通配、cam-cnc-demo-03、svc-bridge-aliyun-api、
清除 `gw/`、补 cam/app 主题、contract_check 退出码 0）。

**⛔ 但仓库改动不会自动生效** —— MQTT 轨**没有服务器权限**（Dashboard 18083 仅绑 127.0.0.1，无 SSH 密钥）。
必须由有服务器权限者（PC / 阿里云工程师）上机执行部署，详见 `docs/46` 第四节。

> **最小修复**：只做「上传新 acl.conf + `docker compose restart emqx`」即可修好 P0-1（新增机器不可用）。
> **建号与 Dashboard 导入**可排期后续做。
> **部署后必须复验两条**：任意新增设备码 → ALLOW；`gw/+/ack` → DENY（后者用于证明线上 DB 已同步到新版）。
>
> 一条硬约束：`cnc/+/cmd` 的 publish 任何阶段都不能拦（App 每 10s 的心跳 `{"cmd":"hello"}` 走这里，用于重置固件 15s Feed Hold）。

---

## 八、给 MQTT 任务的「线上变更指令」（可直接转发，2026-08-30）

> 适用对象：**有腾讯云服务器权限的人**（MQTT 任务或代执行的运维）。
> 完整作业指导书已由 MQTT 轨写就：**`cnc-control-server/docs/47-mqtt-deploy-runbook-20260830.md`**。
> 本节是给它的一页纸指令 —— 照做即可，不需要再回问为什么。

### 8.1 先回一句「能不能上机」（决定后面怎么配合）

| # | 请回答 | 若答「否」的后果 |
|---|---|---|
| 1 | 能否 SSH 登录 `43.154.192.242`（用户 `ubuntu`）？ | 不能就只能出操作清单，请别人代执行 |
| 2 | 有没有 EMQX Dashboard（`18083`）的**管理员**账号密码？ | 不能建号、不能导入内置数据库规则（第 4/5 步做不了） |
| 3 | 仓库在服务器上的**部署目录**是哪个？`<部署目录>/deploy/` 下应有 `docker-compose.cloud.yml` | 无法定位 acl.conf 挂载路径 |

> 注：Dashboard 18083 **只绑 127.0.0.1**，必须走 SSH 隧道：
> `ssh -L 18083:127.0.0.1:18083 ubuntu@43.154.192.242` → 本机开 `http://127.0.0.1:18083`

### 8.2 按 `docs/47` 顺序执行（共 9 步，别跳）

| 步 | 做什么 | 关键命令 / 动作 | 验收 |
|---|---|---|---|
| 1 | SSH 隧道 | `ssh -L 18083:127.0.0.1:18083 ubuntu@43.154.192.242` | 浏览器能开 Dashboard |
| 2 | **备份** | `cp acl.conf acl.conf.bak.$(date +%Y%m%d-%H%M)`；`cp users.json users.json.bak....`；Dashboard 各授权源**导出规则** | 备份文件存在；**并记录线上实际有几个授权源** |
| 3 | 更新文件源 | 上传新 `deploy/acl.conf` → `docker compose -f docker-compose.cloud.yml restart emqx` | `ps` 显示 emqx healthy。**此步单独就能修好"新增机器不可用"** |
| 4 | 建号 | `export SVC_BRIDGE_MQTT_PASSWORD="$(openssl rand -base64 24)"` 后跑 `emqx-init.py` | 输出 `7 成功, 0 失败, 0 跳过` |
| 5 | 同步内置数据库 | `gen_authz_import.py` 生成 → Dashboard 导入 | **先全删再导入**（14 条 users.json 规则 → 83 条） |
| 6 | 清理 `cnc-relay` | 认证删用户 + 授权删规则 + `grep cnc-relay acl.conf` 无输出 | 两处 grep **都无输出** |
| 7 | 踢旧客户端 | Dashboard → 连接 → 搜 `cam-cnc-demo-01` → 踢除 | Dashboard 里看不到该客户端 |
| 8 | **两条验收** | 见 8.4 | ① ALLOW ② DENY，**缺一不可** |
| 9 | 回滚预案（不做，仅备查） | `cp acl.conf.bak.<时间戳> acl.conf` + restart | — |

### 8.3 三个最容易踩的坑（踩了就白干）

| # | 坑 | 后果 | 规避 |
|---|---|---|---|
| 1 | `emqx-init.py` 加了 `--write-acl` | 用 users.json **反向覆盖** acl.conf → 丢失 cam 正则、`cnc-server`、08-29 摄像头安全修复 `cnc/+/status`→`cnc/+/cam` | **绝对不加这个参数** |
| 2 | Dashboard 导入前**没先清空旧规则** | 旧枚举规则 + 废弃 `gw/` 残留 → 第 8 步第 ② 条验收失败，且"看起来能用"实则靠并集蒙对 | **先全选删除，再导入** |
| 3 | 只改 `acl.conf`，不改内置数据库 | 两个授权源取并集，线上仍是旧版 → 效果不可预期 | **两个源都要改** |
| 4 | （附）云网关密码写进文件/仓库/聊天 | 凭据泄露（`alexcnc` 是**公开仓库**） | 只走 `SVC_BRIDGE_MQTT_PASSWORD` 环境变量 |

### 8.4 验收（两条，缺一不可）

```bash
# ① 任意新增设备码 -> 必须 ALLOW（证明通配已生效）
python verify/acl_probe.py -u app-demo -P demo123 -t "cnc/zzz-new-999/status" --expect-allow

# ② 已废弃的 gw 路径 -> 必须 DENY (0x80)（证明内置数据库确实同步到新版）
python verify/acl_probe.py -u app-demo -P demo123 -t "gw/+/ack"
```

| 检查 | 期望 | 不符说明 |
|---|---|---|
| ① `cnc/zzz-new-999/status` | **ALLOW** | 第 3 步没生效：容器没重启 / 挂载被 `:ro` 覆盖 |
| ② `gw/+/ack` | **DENY (0x80)** | 第 5 步没生效：内置数据库还是旧版，或没先清空旧的 |

> 第 ② 条是唯一能证明"线上数据库确实同步到新版"的判据，别省。

### 8.5 完成后请回报这五项

1. 第 8 步两条验收的**实际输出**（ALLOW / DENY，截图或文字）；
2. 线上**实际有几个授权源**、分别是什么类型（内置数据库源是否存在）；
3. `cnc-relay` 是否已从**认证 + 授权两处**彻底删除；
4. ACL deny 审计日志是否开启、查询方式是什么（后续静默故障的唯一抓手）；
5. **`cam-cnc-demo-03` 账号是否可连通、凭据是什么**（仓库里是 `demo123`，如有变更请告知）—— 摄像头端烧录要用。

### 8.6 顺序依赖（不能颠倒）

```
MQTT 部署上线（第 3/4/5 步）
      ↓
我这边跑两条验收 + App 联调
      ↓
摄像头端烧录：设备码 cnc-demo-03 + username/clientId = cam-cnc-demo-03
      ↓
三方联调
```

> 第 1 步没上线上服务器之前，摄像头烧 03 也连不上 —— **部署是目前唯一的硬卡点**。

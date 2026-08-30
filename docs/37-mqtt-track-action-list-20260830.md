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
> 后端（阿里云）与中继**不得代发 `stream_start`** —— 请勿给这类账号任何 `cnc/+/cmd` 的 publish 权限。

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
>
> 一条硬约束：`cnc/+/cmd` 的 publish 任何阶段都不能拦（App 每 10s 的心跳 `{"cmd":"hello"}` 走这里，用于重置固件 15s Feed Hold）。

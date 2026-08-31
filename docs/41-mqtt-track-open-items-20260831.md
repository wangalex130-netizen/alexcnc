# MQTT 服务器 / EMQX 待办工单（2026-08-31 重新核对版）

> **本文替代 `docs/37` 的待办部分**，只列**今天（08-31）重新读文件核对过的、仍未完成**的事项。
> 每条都给了：① 现状证据（文件:行）② 改成什么（可直接粘贴）③ 验收方法。
> `docs/37` 中已完成的部分见本文「四、已闭环」，请勿重复劳动。

---

## 零、本次核对方法与结论

| 核对对象 | 结果 |
|---|---|
| `cnc-control-server/deploy/acl.conf` | **已通读**，`app-demo` 订阅白名单（第 23 行）**确实没有 `cnc/+/cam`** → M-5 未做 |
| `deploy/docker-compose.cloud.yml:43` | 仍是 `EMQX_AUTHORIZATION__DENY_ACTION: disconnect` → M-3 未做 |
| `deploy/docker-compose.emqx.yml:40` | 同上，仍是 `disconnect` → M-3 未做 |
| `deploy/` 目录文件清单 | **没有 `docker-compose.yml`**，只有 `cloud` / `emqx` / `mosquitto` 三个变体 |
| App 代码 `hardware_service_real.dart:294` | 已确认 `client.subscribe(mqttCamStatusTopic, ...)`，主题即 `cnc/<deviceId>/cam` → **App 确实已依赖 M-5** |
| App 代码 `hardware_service_real.dart:269-272` | App 用 LWT 发 `cnc/<deviceId>/app`（retain），但**没有任何端订阅它** → 见 M-11 |

> ⚠️ **本次核对发现一个会让 M-3 白做的问题 → 新增 M-6，且它必须排在 M-3 之前。**
> 原因见下。

---

## 一、第一梯队（现在就能做，改动小、收益明确）

### M-5 🔴 `acl.conf` 给 `app-demo` 的订阅白名单补 `cnc/+/cam`

**现状证据**（`deploy/acl.conf:23`，原文照抄）：

```erlang
{allow, {username, "app-demo"}, subscribe, ["cnc/+/status", "cnc/+/notify", "cnc/+/telemetry", "cnc/+/log", "cnc/+/job", "cnc/+/sys", "cnc/+/wizard", "cnc/+/selfcheck", "cnc/+/interact", "cnc/+/push", "cnc/broadcast/#"]}.
```

**问题**：App 侧已随 commit `129ac1af` 上线订阅 `cnc/<deviceId>/cam`
（`lib/services/hardware_service_real.dart:294`），但白名单里没有这个主题。
由于 `no_match=deny` + `deny_action=ignore`，该订阅会**静默失败**（SUBACK 0x80，App 无任何报错）。

**影响**：App 收不到摄像头的 `{"streaming":true}` / `{"online":true}` 回执，
只能退回「干等第一帧」的旧行为 —— 也就是客户反馈的「点播放后要等一二十秒才出画面」。
**不影响机器控制、不影响画面本身，不是阻塞项**，但 A-3 的效果出不来。

**改为**（只加一项 `"cnc/+/cam"`，其余不动）：

```erlang
{allow, {username, "app-demo"}, subscribe, ["cnc/+/status", "cnc/+/notify", "cnc/+/telemetry", "cnc/+/log", "cnc/+/job", "cnc/+/sys", "cnc/+/wizard", "cnc/+/selfcheck", "cnc/+/interact", "cnc/+/push", "cnc/+/cam", "cnc/broadcast/#"]}.
```

**验收**：

```bash
python verify/acl_probe.py -u app-demo -P demo123 -t "cnc/<任意设备码>/cam" --expect-allow
```

期望 **ALLOW**。改完需 `docker compose -f docker-compose.yml restart emqx`（注意服务器上的文件名，见 M-6）。

---

### M-1 清理已废弃的 `cam-cnc-demo-01` 在线客户端

**背景**：摄像头端已完成设备码切换（`cnc-demo-01` → `cnc-demo-03`）并重新烧录。
`docs/48` 部署时唯一在线的摄像头正是 `cam-cnc-demo-01`，当时为不断流**故意没踢**。

**现在请做**：

1. 在 Dashboard 连接列表里确认 `cam-cnc-demo-01` 是否还在线；
2. **若仍在线 → 踢除**（摄像头已切 03，不会再回来）；
3. 同时确认 `cam-cnc-demo-03` 已经在线并正常订阅 `cnc/+/cmd`。

**关于账号本身**：建议**保留 `cam-cnc-demo-01` 的账号不删**，作为回退手段；
本次只清理**在线客户端**即可。

**验收**：Dashboard 连接列表里只剩 `cam-cnc-demo-03`，无 `cam-cnc-demo-01`。

---

### M-6 🆕 把服务器上实际运行的 `docker-compose.yml` 拉回仓库

**这是本次核对新发现的问题，且它是 M-3 的前置条件。**

**事实**：

| 项 | 说明 | 出处 |
|---|---|---|
| 服务器上 EMQX 是用哪个 compose 起的 | **`docker-compose.yml`** | `docs/48` §一：「服务器上 `docker-compose` 文件名是 `docker-compose.yml`（不是仓库里的 `docker-compose.cloud.yml`）」 |
| 仓库 `deploy/` 里有哪些 compose | `docker-compose.cloud.yml`、`docker-compose.emqx.yml`、`docker-compose.mosquitto.yml` | 目录实测 |
| 仓库里**有没有** `docker-compose.yml` | **没有** | 目录实测（`deploy/` 与仓库根目录均无） |

**推论（关键）**：
> 仓库里**不存在**服务器实际运行的那个 compose 文件。
> 因此 **M-3 只改仓库里的 `cloud`/`emqx` 两个文件，对线上完全没有影响** —— 白改。

**请做（三选一，推荐①）**：

1. **把服务器上的 `docker-compose.yml` 拉回仓库**（推荐），并把仓库里三个变体统一收敛到它；
2. 若服务器上那个文件其实就是某个仓库变体的改名副本，请**明确告知对应关系**，我们据此更新文档；
3. 若线上属于「手工起的服务、无 compose」，请说明环境变量从哪来，我们改成对应的运维文档。

**验收**：仓库里存在一个 compose 文件，其内容与服务器 `/home/ubuntu/cnc-control/docker-compose.yml` **逐字一致**。

> **顺序依赖：必须先做 M-6，再做 M-3。**

---

## 二、第二梯队（需上机 / 需交付凭据）

### M-3 仓库 compose 的 `DENY_ACTION` 对齐线上为 `ignore`

**现状证据**：

```
deploy/docker-compose.cloud.yml:43   EMQX_AUTHORIZATION__DENY_ACTION: disconnect
deploy/docker-compose.emqx.yml:40    EMQX_AUTHORIZATION__DENY_ACTION: disconnect
```

**线上实际是 `ignore`**（`docs/48` §六第 4 条）。

**方向是单向的**：
> 必须是**仓库改成 `ignore` 迁就线上**。
> **绝不能**反过来把线上改成 `disconnect` —— 那会让所有被 ACL 拒绝的设备**直接掉线**，
> 从「点了没反应」恶化为「频繁断连」。

**改为**（两个文件都要改；若 M-6 拉回了新文件，以新文件为准）：

```yaml
EMQX_AUTHORIZATION__DENY_ACTION: ignore
```

**验收**：`grep -rn DENY_ACTION deploy/` 全部输出 `ignore`，无 `disconnect`。

---

### M-4 把 `svc-bridge-aliyun-api` 的密码通过安全渠道交付

**背景**：2026-08-30 部署时已建号成功，密码现场随机生成、只经环境变量传入、未写入任何文件。

**为什么现在要**：线上云网关 `bridge-aliyun-api` 与 `gw-1787738111` **目前仍以 `username=admin`（全权限）连接**。
长期用 admin 跑网关是实打实的安全风险，切换过去需要阿里云侧拿到密码改配置。

**请做**：把密码**单独**发给项目 owner 或阿里云负责人 ——
**不要**发群、不要写进仓库（`alexcnc` 是公开仓库）、不要贴在聊天记录里。

**联动**：M-4 完成后，阿里云侧才能做 P-4（网关从 admin 切到 `svc-bridge-aliyun-api`）。

---

### M-8 每次部署后把线上 `acl.conf` 拉回仓库 diff

**背景**：`docs/48` 已证实「线上 acl.conf 长期未与仓库同步」是此前一系列误判的根因。
目前部署是**单向**的（仓库 → 线上），线上若有手工改动会在下次部署时被静默覆盖。

**请做**：本次改完 M-5 上线后，把线上 `acl.conf` 拉回仓库 diff 一次，确认与仓库一致再提交。

---

## 三、第三梯队（设计确认 / 量产前必须定）

### M-7 🆕 量产时每台的 `screen-<deviceId>` / `cam-<deviceId>` MQTT 账号怎么自动创建

**这是量产前必须回答的设计问题，不要求现在实现。**

**事实链**：

1. 摄像头量产方案已定为 **方案 C**：通用固件 + 配网时由屏幕经 UART 下发设备码（见 `docs/39` §七/§八）
   → 固件侧变成通用件，**第 5 道门（固件烧码）可以自动化了**。
2. 但 `acl.conf` 里的正则 `^cam-[a-z0-9-]+$` 只解决**授权**，解决不了**认证** ——
   EMQX 仍然需要存在一个 `cam-<deviceId>` 的账号（用户名+密码）才能连上来。
3. 换言之：**每出厂一台机器，仍然要有人在 EMQX 上手工建两个账号**（screen + cam）。
   这在批量销售下走不通 —— 第 4 道门还是人工的，方案 C 的收益被吃掉一半。

**需要 MQTT 侧回答**：

| # | 问题 |
|---|---|
| 1 | EMQX 能否开启 **HTTP 认证 / HTTP 授权**，让 037123 后端按绑定关系实时判定？（推荐方向） |
| 2 | 若走设备自注册（provisioning）：设备用出厂密钥换取正式 MQTT 账号并自动写入 broker，是否可行？ |
| 3 | 屏幕与摄像头是否**共用同一个 `deviceId` 走一次激活**？当前决策是「机器码 = 屏幕码 = 摄像头码」，倾向共用一次激活 |
| 4 | 若短期不做，量产前的过渡方案是什么（批量导入账号表？） |

> 相关设计稿：`2026-08-24-mqtt-device-provisioning-design.md`。

---

### M-9 ACL deny 日志留痕（可观测性，低优先）

**现状**：`docs/48` §五已给出可行方案 —— 文件日志未启用，用 **trace API** 临时抓
（`POST /api/v5/trace` → 复现 → `GET /api/v5/trace/<name>/log`，**每页仅 1000 字节，用 `position` 翻页**）。

**可选增强**：排障窗口临时开启文件日志 handler + 调低级别，便于回溯历史 deny 记录。
日常不建议常开（2C4G 机器，全局 debug 噪声与磁盘开销大）。

**优先级**：低。trace API 已够用，本条只是留个口子。

---

## 四、已闭环（请勿重复劳动）

| 项 | 完成时间 / 出处 |
|---|---|
| `app-demo` ACL 枚举 → 通配 `cnc/+/...`，`gw/` 已清除 | 2026-08-30 13:35 上线，`docs/48` §四验收 `cnc/zzz-new-999/status` → ALLOW |
| 「内置数据库 + 文件两源取并集」→ **已证伪**，线上**只有文件源** | `docs/48` §二（EMQX API 实锤） |
| `cam-*` publish 从 `cnc/+/status` 改 `cnc/+/cam` | 2026-08-29 安全修复，`acl.conf:54-55` |
| `cnc-relay` 凭据删除（HTTP 204）+ relay 死循环根治 | 2026-08-30，`docs/48` §三 |
| 建号 8 个（含 `cam-cnc-demo-03`、`svc-bridge-aliyun-api`） | 2026-08-30，`docs/48` §三 |
| `deny_action` 线上已为 `ignore` | 线上现状，**本次只改仓库**（M-3） |
| `3020-2.0` 生产机器码账号 | 已原样保留并加注释，`acl.conf:43-44`；量产统一命名时再迁 |
| P2-1「ACL deny 怎么查」 | 已有 trace API 方案，`docs/48` §五 |

---

## 五、两条待确认（不是待办，请勿顺手就改）

### M-10 `pc-demo` 是否也需要 `cnc/+/cam` 订阅权限？

`acl.conf:27` 的 `pc-demo` 订阅白名单同样**不含** `cnc/+/cam`。
PC 端目前是否要展示摄像头画面？**要就补，不要就保持现状** —— 请给一句明确答复。

### M-11 ⚠️ `cnc/<deviceId>/app` 目前**无人订阅**，这是对的，请保持

**事实**：

- App 用 LWT 往 `cnc/<deviceId>/app` 发 `{"online":false}`（retain），上线发 `{"online":true}`（retain）
  —— `hardware_service_real.dart:269-272`；
- 但 `screen-*` 的订阅白名单（`acl.conf:36-38`）是
  `["cnc/broadcast/#", "cnc/+/cmd", "cnc/+/tool_catalog"]`，**不含 `cnc/+/app`**；
- `pc-demo`（`acl.conf:27`）同样不含；
- `app-demo` 自己的订阅白名单（`acl.conf:23`）也不含。

→ **该主题目前没有任何订阅方。**

**这与 P0-5 直接相关，请先不要给屏幕加这个权限**：

- P0-5（owner 明确）：**App 断链绝不能影响雕刻**，雕刻由屏幕主控闭环。
- 若现在给屏幕开 `cnc/+/app` 的订阅，等于把「App 在线与否」这个信号递到了运动控制侧，
  将来极易被误用成停机依据 —— 那正是要规避的。
- **处置**：等 P0-5 在固件侧定稿后再决定。若最终确认「App 在线状态只用于 UI 展示 / 推送」，
  则**永久不给屏幕订阅权**。

> 一句话：**M-11 是「明确不做」，不是「待办」。**

---

## 六、执行顺序（依赖关系，不能颠倒）

```
M-6（拉回服务器真实 compose）
   ↓ 前置：不先做这一步，M-3 改错文件
M-3（DENY_ACTION → ignore）
   ↓
M-5（acl.conf 补 cnc/+/cam）  ← 与 M-1 可并行
M-1（踢 cam-cnc-demo-01 客户端）
   ↓
M-8（部署后线上 acl.conf 拉回仓库 diff）
   ↓
M-4（交付 svc-bridge 密码）→ 阿里云侧 P-4（网关从 admin 切走）
```

**可并行、互不依赖**：M-10 / M-11（只需一句答复）、M-7（设计讨论）、M-9（低优先）。

---

## 七、可直接转发的消息

> @MQTT 服务器 重新核对了仓库当前状态，待办更新如下（每条都有文件行号证据）：
>
> **先做（改动小、收益明确）**
> 1. **M-5**：`acl.conf:23` 给 `app-demo` 的 subscribe 加一项 `"cnc/+/cam"`。App 已随 `129ac1af` 订阅了这个主题，不给权限会被静默拒绝（收不到摄像头回执 → 客户反馈的「点播放要等一二十秒」就是它）。只加一个字符串，重启 EMQX 即可。
> 2. **M-1**：摄像头已切 `cnc-demo-03` 并重刷，请踢掉还在线的 `cam-cnc-demo-01` 客户端，并确认 `cam-cnc-demo-03` 已在线。**账号建议保留不删**（回退用），只清客户端。
> 3. **M-6（新发现）**：服务器上跑的 compose 是 **`docker-compose.yml`**，但仓库里根本没有这个文件（`deploy/` 只有 cloud / emqx / mosquitto 三个变体）。**所以只改仓库里的 compose 对线上无效** —— 请先把服务器上真实的 compose 拉回仓库（或告诉我们它对应仓库哪个文件），这步是下面 M-3 的前置。
>
> **再做（需上机）**
> 4. **M-3**：`DENY_ACTION` 从 `disconnect` 改成 `ignore`，**方向是仓库迁就线上，绝不能反过来把线上改成 disconnect**（那会让被拒设备直接掉线）。`docker-compose.cloud.yml:43` 和 `docker-compose.emqx.yml:40` 都要改；若 M-6 拉回了新文件，以新文件为准。
> 5. **M-4**：`svc-bridge-aliyun-api` 的密码请**单独安全渠道**给到 owner / 阿里云负责人。目前云网关仍是 **admin 全权限**在跑，是安全风险。
> 6. **M-8**：改完上线后，把线上 `acl.conf` 拉回仓库 diff 一次（上次「线上仓库不同步」就是一系列误判的根因）。
>
> **待确认（一句话答复即可）**
> 7. **M-10**：`pc-demo` 要不要也加 `cnc/+/cam` 订阅（PC 端看不看摄像头画面）？
> 8. **M-11**：`cnc/<deviceId>/app` 目前**无人订阅，这是对的，请先不要给屏幕加订阅权**。原因：owner 定了「App 断链绝不能影响雕刻」（P0-5），给屏幕开这个权限会把 App 在线信号递到运动控制侧，容易被误用成停机依据。等固件侧定稿再说。
>
> **量产前必须定的设计问题（不急，但要给方向）**
> 9. **M-7**：摄像头量产已定「通用固件 + 配网下发设备码」，第 5 道门能自动化了；但**每台机器仍要人工在 EMQX 建 `screen-<id>` / `cam-<id>` 两个账号**，第 4 道门还是人工的。请回答：能否走 HTTP 认证/授权接 037123 绑定关系？或设备自注册？屏幕与摄像头能否共用一次激活？
>
> 完整工单（含证据行号、可粘贴配置、验收命令）：`docs/41-mqtt-track-open-items-20260831.md`
> 仓库 wangalex130-netizen/alexcnc，main。

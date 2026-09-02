# 48 · 小屏 GRBL 流式传输接入文档 · App 侧对照校核 — 2026-09-02

> 来源：闫安(An.Yan) 2026-09-02 发出两份文档
> - 《网页与移动端通过小屏完成雕刻_开发接入文档.md》（V1，1543 行）
> - 《小屏幕独立GRBL流式传输功能修改说明_20260902.md》（663 行，给固件耿清凯）
>
> 本文 = **App 侧对照校核结果**：文档要求 vs App 现状，列出冲突、风险、新任务与待澄清项。
>
> - 本文经**两轮交叉核对**（App 侧独立分析 ↔ 各端对齐任务侧独立分析），
>   双盲结论互相印证的部分标 ✅；有分歧的部分保留双方意见与依据。
> - ⚠️ **方案一律用中性编号（D# / N#）指代，不使用 A/B/C 字母** ——
>   两套文档曾出现"A 的含义相反"的情况（详见 §五之三 R1）。
> - 📌 **状态更新至 2026-09-02 18:3x**，可直接作为多方确认会的基础材料。

---

## 零、状态总览（给工程师快速扫一眼）

### ✅ 已确定 / 已落地（无需再议）

| # | 事项 | 状态 |
|---|---|---|
| 1 | **state 安全加固**（未知值不再回落 idle） | ✅ **已实现并推送**，commit `37fe346` |
| 2 | `job_completed` 与 `job_done` **双名兼容** | ✅ **已实现并推送**，commit `37fe346` |
| 3 | 绑定错误文案「这台机器还没登记，请联系客服」 | ✅ owner 拍板，代码已是该文案（零改动） |
| 4 | 绑定接口 = `POST /api/machine/bind?machineId=&code=`（**Query Param**） | ✅ docx 原文 + 生产实测双向确认 |
| 5 | 绑定鉴权 = 与登录**同一 token** | ✅ 秦政 2026-09-02 确认 |
| 6 | 业务码 `10300104`（已绑定当前用户）**按成功处理** | ✅ 已实现 |
| 7 | 未知业务码 / 未知错误**宽容处理**（HTTP 200 即成功） | ✅ 秦政确认"未知错误宽容处理即可" |
| 8 | 绑定两步式 =「list → 找空档案 → 贴码」 | ✅ 与我实现一致（不是阻塞点） |
| 9 | 数据污染（id=381 被写成 CNC-TEST99） | ✅ 对齐端已用 `unbind` 回滚，我实测复核通过 |
| 10 | App 鉴权头补齐（11 个 http 调用全带 Bearer） | ✅ 已推送并出包 |

### ⏳ 待 owner 拍板（阻塞主体开发）

| 编号 | 决策 | App 侧建议 |
|---|---|---|
| **D1** | 物理按键 vs App 发 confirm（两套"两段式"如何统一） | 见 §冲突3——**注意：不要用 A/B 字母回答** |
| **D2** | G-code 铁律是否修订为"App 不生成、可转存" | 同意修订，但需明确 App **从哪个接口拿到 G-code 字节流** |
| **D3** | clientId 统一为 `mobile-<userId>-<uuid>` | 同意；提醒 presence 服务 `android-presence-<userId>` 需一并改 |
| **D4** | 短期 MQTT 凭证 | 必做，归第二阶段（App 现用长期固定账号 `app-demo`） |
| **D5** | 多客户端控制租约 | 必做，App 现允许多手机同连（已知会互踢） |
| **D6** | 生产域名（`037123.xyz` vs `artimaker.com`） | 问阎安 |
| **D7** | **App 心跳（`hello`）在新架构下保留 / 改造 / 移除** | 见 §五之二补充1——文档无心跳，App 每 10s 发一次 |
| **D8** | `confirm`/`start` 是否**禁用自动重发**（文档明令禁止盲目重复启动） | **建议禁用**，改状态对账 |

### 📋 待固件 / 后端答复

| # | 问题 | 问谁 |
|---|---|---|
| F1 | 小屏 status 的 `state` 正式发哪些值？`run` 是否在契约内（建议统一 `busy`） | 耿清凯 + 阎安 |
| F2 | 机器等待物理键的**超时**机制（若走 D1 按键方案） | 耿清凯 |
| F3 | 短期 MQTT 凭证 + 设备级 ACL 的落地时间 | MQTT 运维 |
| F4 | `/file/upload` 生产域名与 App 权限 | 阎安 |
| F5 | 活跃固件库确认为 `pingMu-3020`（非 `cnc-fw`） | 耿清凯 |

---

## 一、文档要求的移动端路径

```text
移动端已有 G-code
  -> 上传 G-code 到 OSS（POST /file/upload, multipart, type=3）
  -> 连接 MQTT 并订阅小屏状态
  -> publish prepare_job（带 files[]: url/sizeBytes/sha256）
  -> 小屏下载并校验到 SD -> cmd_ack(ok=true)
  -> publish confirm
  -> 小屏开始向 GRBL 流式传输 -> cmd_ack(ok=true)
  -> 移动端订阅进度和最终状态
  -> 雕刻完成
```

文档原文：
- 「本文假定移动端已经有一个完整、可执行的 G-code 文件」
- 「本文不讨论移动端如何生成 G-code」
- 移动端 clientId 必须唯一：`mobile-<userId>-<installationUUID>`
- 命令 `retain=false`（否则小屏重连后可能执行历史命令）
- 移动端禁止内置 Driver 或小屏的通用 MQTT 用户名和密码

Topic（`deviceId=cnc-demo-03`）：

| 方向 | Topic | QoS | retain |
|---|---|---:|---|
| Mobile→小屏 | `cnc/cnc-demo-03/cmd` | 1 | false |
| 小屏→Mobile | `cnc/cnc-demo-03/notify` | 1 | false |
| 小屏→Mobile | `cnc/cnc-demo-03/status` | 1 | **true** |

Topic 与 App 现有**一致**（`hardware_service_real.dart` 已是这三个），QoS/retain 也一致。✅

---

## 二、🔴 冲突与风险（按严重度）

### 风险 1（安全）：`state` 取值越界 → Jog 误解锁 — ✅ **已于 2026-09-02 修复（commit `37fe346`）**

| 项 | 值 |
|---|---|
| 文档 status 示例 | `"state": "run"` |
| App `MachineState` 枚举 | `disconnected / idle / homing / busy / paused / alarm`（`machine_status.dart:5-12`） |
| App 解析行为 | 不匹配任何枚举时 **静默保持 idle**（`machine_status.dart:139-146`） |
| App 闸门 | `canControl => state == idle`（Jog 可用） |

**后果**：小屏发 `state:"run"` → App 判定为 **idle** → **Jog 被解锁** → 加工中客户可点动轴 → **撞刀/伤人风险**。

这正是 `docs/43` 记录的「状态帧字段级契约陷阱 #2」，本次在新文档里再次踩中。

**必须二选一**：
- (a) 小屏改用 App 枚举内的值（建议 `busy`）；
- (b) App 扩充枚举并把未知值判为**安全侧**（非 idle），绝不能回落 idle。

> 我倾向 (a)+(b) 同时做：小屏发 `busy`，App 同时把未知 state 判为非 idle（纵深防御）。

### 冲突 2（架构）：App 的 G-code 从哪来

| 既有决策 | 文档前提 |
|---|---|
| 产品铁律：**App 绝不持有/转发 G-code**，只调 `startJob()` + 触发云端推送（`RealCloudService.pushTaskToMachine`）；G-code 由云端直推 MCU | 「假定移动端已经有一个完整、可执行的 G-code 文件」，要求 App **上传到 OSS** |

文档没要求 App **生成** G-code，但要求 App **持有并上传**——仍与铁律冲突。

**可能的解释（需确认）**：
- 模型库里的 G-code 由云端持有；App 若要从模型库发起雕刻，是「云端直推」还是「App 下载后再传 OSS」？
- 若是后者，等于 App 开始经手 G-code，铁律需正式修订。

### 冲突 3（语义）：两套"两段式"含义不同

| | App 已实现（owner 2026-08-31 拍板，`docs/46`） | 本文档 |
|---|---|---|
| 第 1 步 | App 发 `{"cmd":"job","action":"start"}` | App 发 `prepare_job`（下载 G-code） |
| 中间态 | 机器 `awaitingConfirm=true` | 机器 `awaitingConfirm=true`（文档 status 确有此字段 ✅） |
| **第 2 步** | **客户在机身上按物理键** | **App 发 `confirm` MQTT 命令** |

owner 原话（2026-08-31）：「App 不远程启动雕刻……真正的开始必须在机身上物理确认」。
文档把 confirm 定义为 App 主动下发的命令。

**这是必须由 owner 拍板的分歧**（= 决策 **D1**），三种走向：

> ⚠️ **以下旧的 A/B/C 编号已作废，请勿再用字母回答！**
> 原因：各端对齐任务侧的清单里"A"指的是**按键触发**，而本文件这里"A"指的是**按文档**，
> 两者**完全相反**。若只回一个字母会导致两边执行相反方案。
> **请改用下面的 N 编号**（N = Neutral 中性编号）。

- **N1（= 本文件原 A）完全按文档**：App 发 `confirm` 命令（**推翻 08-31 拍板**）
- **N2（= 本文件原 B）完全按拍板**：机器等物理键，App 不发 `confirm`
- **N3（= 本文件原 C）两者并存**：App 发 `confirm` = "授权/就绪"，物理键 = "最终执行"
  （文档已有 `awaitingConfirm` 字段，可承载）

> App 侧倾向：**N3** —— 既满足 owner"人在场才动刀"的安全诉求，
> 又与文档 `awaitingConfirm` + `confirm` 命令结构兼容。但这是建议，非结论。

---

## 三、🟠 需新增的能力（文档要求，App 目前没有）

| # | 能力 | App 现状 | 说明 |
|---|---|---|---|
| 1 | OSS 上传 | **完全没有** | `POST {base}/file/upload`，multipart：`file`(binary, octet-stream) + `type=3`；成功判据 `code==200 或 message=="success"`；URL 兼容 `data` / `data.url` / `data.fileUrl` / `data.path` / `data.ossUrl` |
| 2 | `prepare_job` 命令 | 无 | 需带 `jobId`/`manifestId`/`files[]`/`reqId`/`source:"mobile"`/`issuedAt`；V1 只允许 1 个 G-code、URL 必须 HTTPS、**MQTT 中禁止携带 G-code 行数组** |
| 3 | `confirm` 命令 | 无 | 只带 `jobId`/`reqId`/`source`/`issuedAt` |
| 4 | `reqId` ↔ `cmd_ack` 匹配 | 无 reqId 机制 | 必须匹配 `reqId` 且 `ok=true` 才能进入下一阶段 |
| 5 | `jobState` 字段 | **无** | `downloading/ready/starting/running/paused/completed` |
| 6 | `download` 下载进度 | **无** | 0-100 |
| 7 | `jobId` | **无** | 贯穿 prepare/confirm/status |
| 8 | `bootId` / `statusSeq` 去重 | **无** | 文档要求"移动端必须按 bootId/statusSeq 去重" |
| 9 | clientId 改名 | `android-<deviceId>`（`hardware_service_real.dart:129`） | 文档要求 `mobile-<userId>-<installationUUID>` |
| 10 | 启动前门禁 | 部分（只看 state/alarm） | 完整门禁：state==idle + grbl_online + jobState 不忙 + 本地文件非空 + URL 已获得 + 有权控制 deviceId；**若 retained status 显示另一个活动 jobId，只能监控不能覆盖** |

### 生产前置条件（文档 §6.2，需运维/后端配合）
1. 用户对 `deviceId` 的所有权校验
2. 移动端**短期 MQTT 凭证**（App 现在用的是长期固定账号）
3. **设备级 Topic ACL**
4. 正确的 TLS Broker 地址与证书链
5. 移动端使用 `/file/upload` 的权限与 Token
6. **多客户端控制租约**或等效控制权机制

→ 第 2、6 项 App 目前**完全没有**，是上线硬阻塞。

---

## 四、✅ 已一致的部分

| 项 | 状态 |
|---|---|
| Topic（`cnc/<id>/cmd` / `notify` / `status`） | ✅ 与 App 现有完全一致 |
| status 的 `retain=true`、cmd 的 `retain=false` | ✅ 一致（App 命令发布未设 retain） |
| `awaitingConfirm` 字段名（驼峰） | ✅ 一致，我 09-02 刚实现的两段式已用此字段 |
| `pos` / `mpos` / `progress` / `feed` / `grbl_online` | ✅ App 已解析 |
| 状态门禁"state==idle 才能开新作业" | ✅ 与 App 现有 `canControl` 一致 |

---

## 五、待澄清清单（需 owner / 闫安 / 固件答复）

| # | 问题 | 问谁 |
|---|---|---|
| 1 | 小屏 status 的 `state` 到底发哪些值？`run` 是否在正式契约内？建议统一到 `busy` | 固件（耿清凯）+ 闫安 |
| 2 | App 的 G-code 从哪来？是否修改"App 绝不持有 G-code"铁律？ | **owner** |
| 3 | confirm 是 App 发命令，还是机器等物理键？两套两段式如何统一？ | **owner** |
| 4 | clientId 用 `android-<deviceId>` / `app-<userId>` / `mobile-<userId>-<uuid>` 哪个？（三套并存） | owner + MQTT 端 |
| 5 | `/file/upload` 生产域名是 `artimaker.com` 还是 `037123.xyz`？App 的 `backendBaseUrl` 现在是 `037123.xyz` | 闫安 |
| 6 | App 是否要走"短期 MQTT 凭证"？现在用长期固定账号（`app-demo`） | 闫安 + MQTT 端 |
| 7 | "多客户端控制租约"是否要做？App 现在允许多台手机同连（已知会互踢） | owner |
| 8 | 文档 §5（网页端）与 App 无关，但刘昊霖的驱动联调是否会影响 App 契约？ | 闫安 |

---

## 五之二、与对齐端交叉核对后的补充（2026-09-02 18:1x）

对齐端独立分析提出 6 条"App 未覆盖"项，我逐条查证，**其中 4 条确实与 App 相关且我漏了**，已并入：

### 🟠 补充 1：心跳机制去留（真实冲突，我漏了）

| 项 | 事实 |
|---|---|
| 文档 | **全文无心跳 / hello 机制**，只在"停止"场景提 Feed Hold（`!` 字符，文档 line 1296 / 第二份 line 319） |
| App 现状 | **每 10s 发一次 `{"cmd":"hello"}`**（`hardware_service_real.dart:51` `_heartbeatInterval`，注释：机器主控 15s 无命令即 Feed Hold） |

**冲突**：新架构下雕刻由**小屏**接管（小屏→GRBL 流式传输），App 的 hello 发给谁？
小屏若不认识 `hello` 会怎样？—— 与待确认项 C-3（摄像头按 payload 过滤）是同一类问题。

**⇒ 必须加进决策清单**：新架构下 App 心跳是保留、改造还是移除？
（若保留，需小屏明确定义 `hello` 语义；若雕刻中小屏自己维持 Feed Hold，App 心跳雕刻期间应停发以免干扰。）

### 🟠 补充 2：通知事件命名不一致（真实冲突，我漏了）

| 来源 | 完成事件名 |
|---|---|
| 文档 | `job_completed`（line 150） |
| App 现有 | `job_done`（`notify_event.dart:6`） |

App 的 `NotifyEvent.type` 枚举：`job_done / alarm / error / confirm_required / gw_rejected / knife / inspect / sound / led / cmd_ack`
→ **`job_completed` 不匹配 `job_done`**，App 会走 default 分支（只显示 msg，不触发完成逻辑）。

### 📌 补充 3：屏幕端活跃代码库是 `pingMu-3020`，不是 `cnc-fw`

文档 line 7：「代码依据：当前 `touchpad` Driver/JavaFX 与 **`pingMu-3020`** 小屏源码」。

⇒ 更新认知：我此前查的 `C:/Users/thwan/WorkBuddy/cnc-fw` **不是**当前活跃固件源。
后续核固件行为应以 `pingMu-3020` 为准（该库位置待确认，需向固件索要）。

### 🟠 补充 4：调平不在本期 —— 影响 App 向导 Step5

文档 line 6：「**不包含**：STL、**自动调平**、自动换刀、断点续雕」。

⇒ App 现有雕刻向导 **Step5 = 智能调平**（`setLevelingPlan`）。若调平不在本期，
Step5 的展示与下发需重新定义（隐藏 / 降级为提示 / 保留但固件不响应）。

### 📌 补充 5 / 6
- **artimaker.com 新域名**：我已在 §五 第 5 条问了生产域名，但**不知道 artimaker.com 是新域名** —— 对齐端这条信息我确实没有，已并入待澄清。
- **1.3 建档流程联动**：我实现了 1.3（扫码贴码），但**未考虑它与新雕刻主链路的关系**（建档后才能雕刻）。需一并纳入流程设计。

---

## 五之三、二次交叉核对（2026-09-02 18:2x）—— 对齐端提的 R1-R4 逐条论证

### ✅ R1 成立（且是最危险的一条）：决策字母两边相反

| 来源 | A | B |
|---|---|---|
| 对齐端 | A = **按键触发** | B = 按文档 |
| 本文件 §冲突3 | A = **按文档** | B = 按拍板（按键） |

**确实相反。** 若只回一个字母"选 A"，两个团队会执行成相反方案。
**对策：认同改用中性编号（D1-D8 决策表），本文件后续不再用 A/B/C 指代方案。**
（本文件 §冲突3 的 A/B/C 已作废，以决策表为准。）

### ✅ R2 成立，且比"新增一项"更严重：现有实现要改

文档 §6.12 要求：

```json
{"cmd":"set_work_zero","axes":["x","y"],"reqId":"uuid","source":"mobile","issuedAt":...}
```

App 现状（`hardware_service_real.dart:962-963`）：

```dart
final cmd = {'cmd': 'setWorkZero', 'x': x, 'y': y, 'z': z};
```

差异：**命令名不同**（`setWorkZero` vs `set_work_zero`）、**参数形态不同**（坐标值 vs `axes[]`）、
**缺 `reqId`/`source`/`issuedAt`**、文档要求"必须等待相同 reqId 的 cmd_ack.ok=true"。
→ 不是"新增第 11 项"，是**改造现有置零实现 + 接 ACK**。

### ⚠️ R3 部分成立 —— 结论对，但依据描述不准确

❌ **"60 秒超时机制在阎安文档里完全没有"这句不准确。** 文档有完整的两级超时：

| 位置 | 超时 |
|---|---|
| line 658 | 等待小屏**下载校验 ACK**，当前超时 **120 秒** |
| line 660 | 等待小屏**进入 GRBL streaming**，当前超时 **40 秒** |
| §6.11 (1175-1198) | prepare/confirm ACK 超时的**完整对账策略** |
| line 1295 / 1368 | 最终状态等待超时 → 作业失败；`ETIMEOUT` → 先状态对账 |

✅ **但对齐端的关切是对的**：文档这两级超时是 **App/Driver 等小屏 ACK** 的超时，
不是"机器等待客户按物理键"的超时。**若走按键方案，机器端 `awaitingConfirm` 的等待超时文档确实缺失**，
需固件实现（即 `docs/46` 里我定义的 `confirm_timeout` 事件）。

### 🆕 我发现的第 5 个残留（安全相关，比对端那条更要紧）

文档 §6.11 line 1177 明令：

> **5. 禁止因为 confirm ACK 超时而盲目重复启动。**

**这与我 09-02 刚建的重发队列直接冲突**（`docs/46`）：
`_dispatchCritical` 对关键命令 5 秒无回执重发、最多 3 次。
对于 `job/start`（以及新架构的 `confirm`）**属于明令禁止的"盲目重复启动"**。

⇒ **必须修正**：`confirm` / `start` 类命令**不参与自动重发**，只做"状态对账"
（按 §6.11 推荐：读 status 判断 `downloading/ready/starting/running/paused/completed` 再决定），
`pause/resume/stop` 因幂等可保留重发。

### 🆕 能力清单第 12 项（我补充，对齐端未列）

文档 §6.13：暂停 / 恢复 / 停止**必须携带 `jobId` + `reqId`**：

```json
{"cmd":"job","action":"pause","jobId":"job-uuid","reqId":"uuid","source":"mobile","issuedAt":...}
```

文档原文：「当前小屏对 pause/resume/stop 尚未强制要求 `jobId`，但新移动端必须携带，
后续固件应强制校验，**防止误控制其他作业**」。

App 现状：`{'cmd':'job','action':'pause'}`（什么都不带）→ **安全相关**，必须改造。

### ✅ R4 成立

新链路有下载阶段（文档 `download: 0-100`、`jobState: downloading`），
App 三态横幅（已下发→待确认→加工中）中间确需插入"**准备中（下载 x%）**"。

---

## 五之四、能力清单修正（11 项 → 12 项）

在 §三 的 10 项基础上，追加：

| # | 能力 | 说明 |
|---|---|---|
| 11 | `set_work_zero` 改造 | 命令名改 `set_work_zero`，参数改 `axes[]`，补 `reqId`/`source`/`issuedAt`，等 ACK |
| 12 | pause/resume/stop 带 `jobId`+`reqId` | **防误控制其他作业**（安全） |
| 13 | `confirm`/`start` 禁用自动重发，改状态对账 | 文档明令禁止盲目重复启动 |
| 14 | 下载中态 UI（`download` 0-100） | 三态横幅插入"准备中" |
| 15 | 物理键等待超时（若走按键方案） | 需固件实现 `confirm_timeout` |

---

## 六、App 侧工作量预估（待上面澄清后）

| 模块 | 量 |
|---|---|
| OSS 上传（/file/upload + SHA-256 + multipart） | 中 |
| prepare_job / confirm 两阶段命令 + reqId↔ACK 匹配 | 中 |
| MachineStatus 扩展（jobState / download / jobId / bootId / statusSeq）+ 去重 | 中 |
| 启动前完整门禁 + "只能监控不能覆盖" | 中 |
| clientId 改造 + 短期凭证 | 小（但依赖运维） |
| state 枚举安全加固（未知值不回落 idle） | 小，**建议先做** |

**建议优先级**：
1. **先做 state 安全加固**（风险 1，独立、小、防事故）；
2. 等第 2、3 项拍板后再动主体（否则返工）。

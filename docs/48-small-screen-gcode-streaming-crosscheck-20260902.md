# 48 · 小屏 GRBL 流式传输接入文档 · App 侧对照校核 — 2026-09-02

> 来源：闫安(An.Yan) 2026-09-02 发出两份文档
> - 《网页与移动端通过小屏完成雕刻_开发接入文档.md》（V1，1543 行）
> - 《小屏幕独立GRBL流式传输功能修改说明_20260902.md》（663 行，给固件耿清凯）
>
> 本文 = **App 侧对照校核结果**：文档要求 vs App 现状，列出冲突、风险、新任务与待澄清项。
> ⚠️ **本文是校核结论，不是实施方案** —— 三项 🔴 级问题需 owner 拍板后才动代码。

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

### 风险 1（安全）：`state` 取值越界 → Jog 误解锁

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

**这是必须由 owner 拍板的分歧**，三种走向：
- A. 完全按文档：App 发 confirm（**推翻 08-31 拍板**）
- B. 完全按拍板：机器等物理键，App 不发 confirm
- C. 两者并存：App 发 confirm = "授权/就绪"，物理键 = "最终执行"（文档已有 `awaitingConfirm` 字段，可承载）

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

## 六、App 侧工作量预估（待上面 8 项澄清后）

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

# 58 · App 端开切同网门禁落地 + 跨端待办（2026-09-10）

> 发起方：App 端（Flutter）｜ 影响面：**契约口径 / 固件 / 后端** ｜ commit：`0d7eee8d`
> 一句话：App 侧修复了一个**外网可远程开切动刀**的安全漏口，并明确了开切类命令的契约口径；
> 但要真正闭环，需要**契约补录 + 固件侧来源校验 + 后端未知版本处理**三件事配合。

---

## 1. 背景：开切主路径此前**没有门禁**

| 事实 | 依据 |
|---|---|
| v2 开切流程 = `prepare_job` →（小屏 ACK）→ App **自动** 发 `confirm` | `hardware_service_real.dart` `_handleCmdAck` → `unawaited(confirmJob()…)` |
| 该流程**没有物理键**（D1 纯软件两阶段） | `carve_session.dart` 流程注释 |
| 上一版本门禁**只加在回退路径** `startJob` 上 | `wan_whitelist.forbidden` 含 `startJob`，但 `prepare_job` / `confirm` **未归类** |

⇒ **后果**：拿到 broker 凭据的人，从外网直接下发 `prepare_job`，App 会自动补上 `confirm` ⇒ **机器开始雕刻**（落刀 / 撞刀 / 火灾）。

## 2. App 侧已做的处置（口径）

按 owner 2026-09-10 裁定「**只放行 `wan_whitelist.allowed` 的 7 项，其余一律同网限定**」：

| 命令 | App 侧现在的口径 |
|---|---|
| `prepare_job` | **仅同网**（服务层门禁，非仅 UI 置灰，不可绕过） |
| `confirm` | **仅同网**（与 `prepare_job` 同一道闸门，纵深防御） |
| `startJob` / `jog` / `home` / `setWorkZero` / `startSpindle` | 仅同网（原有） |
| 停机 / 暂停 / 恢复 / 监视 / OTA（`allowed` 7 项） | **外网放行**（保留远程停机能力） |

「同网」判据 = **能发现机器局域网地址 且 TCP 探测 :8899 通过**（不是"看手机连没连 Wi-Fi"；
机器地址是私网地址，公网不可路由 ⇒ 能连上即证明同网）。结果缓存 15s；探测失败会失效缓存并重新发现（可自恢复）。

---

## 3. 需要其他端配合（3 条）

### C-08【契约】`wan_whitelist` 补录 `prepare_job` / `confirm` —— 建议尽快

- **为什么**：App 的门禁是**按"未列即同网限定"这条裁定**实现的，但契约源里这两个命令**既不在 `allowed` 也不在 `forbidden`**。
  契约没写 ⇒ ① 各端读契约会得出"未列 = 不限制"的不同结论；② **后续新客户端（PC 工具 / iOS）不会加这道门禁**，App 的实现成为孤岛。
- **怎么做**：在 `contract/views/app_view.json` 的 `wan_whitelist.forbidden` 补 `prepare_job`、`confirm`；
  或新增一类 `lan_only`（语义"外网禁止、同网允许"更贴切）。同步 `docs/PROTOCOL.md`。
- **验收**：契约里能搜到这两个命令，各端复核后回执。

### F-05【固件】开切命令做**来源校验**（纵深防御）—— 本轮 P0 的收尾必要条件

- **为什么**：客户端门禁只挡"规矩的 App"。改包 / 第三方客户端 / 直接拿凭据发 MQTT 都能绕过。
  而 v2 流程 prepare→自动 confirm、**无物理键** ⇒ 固件是**最后一道也是唯一可靠**的闸门。
- **怎么做**：固件收到 `prepare_job` / `confirm` 时校验来源——MQTT 5 user properties `src`
  （App 已按契约带 `src/dst/seq/v/ts`）若为**云网关 / 外网来源**，回 `cmd_ack`（`ok=false` + 明确 `code`）并**拒绝执行**。
- **验收**：外网（经云网关）发 `prepare_job` → 固件回 `ok=false` 且机器**不动**；同网发起 → 正常 `ready` 并自动 confirm。

### C-09【后端】更新检查接口：把"版本未知"当未知，别当"很旧"

- **为什么**：客户端拿不到当前版本时上报 `version='0.0.0'`。现有逻辑会当作"版本极旧" ⇒ **必然 `update_available=true`** ⇒ 用户看到假更新提示。
  App 侧本轮已改为"外网拿不到机器地址就不发起检查"，但**其他客户端**（PC 工具 / 后续 iOS / 第三方脚本）仍会上报 0.0.0。
- **怎么做**：`POST /api/app/updates/check` 中，`version` 为空 / 缺省 / 等于 `0.0.0` 时**直接返回 `update_available=false`**。
- **验收**：`{"app_key":"android","version":"0.0.0","build_number":0}` → `update_available=false`。

---

## 4. 附：本轮 App 侧其余修复（供各端了解，无需动作）

| 项 | 说明 |
|---|---|
| 固件页 P1-1 | 外网不再用 `0.0.0` 做云端比对，也不再误点亮「有更新」绿点 |
| 固件页 P1-2 | 升级成功后刷新落盘版本缓存（此前会导致"刚升级完又提示有更新"） |
| 发现缓存 P1-3 | `invalidateCache(deviceId)` 同时清 deviceId 槽位与全局槽位；探测失败时调用（此前机器换 IP 会永久锁死 Jog/回零/开切且不自恢复） |
| P2 清理 | 删死配置/死成员、`http.Client` 改共享、**4 处重复的同网提示文案收敛到 `lib/widgets/wan_blocked.dart`** |

> 逐项证据链（含源码行号）见 App 端自审报告；跨端全量清单见《各端工作清单-20260910》。

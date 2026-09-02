# 46 · 雕刻启动两段式（App 侧）— 2026-09-02

> 远程雕刻启动改为 **「App 下发 → 机器待确认 → 客户按物理键动刀」**。
> 本文记录 **App 侧已实现内容** 与 **对固件（屏幕端）的契约要求**。
> 固件侧由屏幕团队并行接线，**本文的契约要求需固件团队确认/答复**。

---

## 一、为什么改两段式

按 2026-08-31 owner 拍板（`docs/44` §七）：

- **App 不远程启动雕刻**。App 只做准备 / 参数下发，**真正动刀必须在机身上物理确认**。
- 原因：App 断链不能影响雕刻；机器旁无人时远程动刀有安全风险。

对应协议门禁 = 状态机里的 `awaitingConfirm`（`docs/PROTOCOL.md:296`）。

---

## 二、App 侧本轮做了什么（commit `24fb2b5`）

### 改动一：关键命令重发队列

**文件**：`lib/services/hardware_service_real.dart`

| 项 | 内容 |
|---|---|
| 现状问题 | `_publish()` 在 MQTT 未连接时 **静默丢弃**，调用方无从知晓，用户"点了没反应" |
| 现在 | 发送失败 → 入队；重连成功 → 自动补发（`_flushCmdQueue()`，接在 MQTT 连接成功路径） |
| 回执超时 | 关键命令下发后 **5 秒** 无机器回执 → 重发（最多 **3 次**，超限判 `failed`） |
| 状态外露 | 新增 `commandDelivery` 流 + `pendingCommand` 快照，UI 显示「指令未送达，正在重试（第 n 次）」 |

**只有关键命令参与重发**（`_criticalLabelOf`）：

| 命令 | 中文名 | 判定"已送达"的机器状态 |
|---|---|---|
| `{"cmd":"job","action":"start"}` | 开始雕刻 | `awaitingConfirm==true` 或 `state==busy` 或 `state==alarm` |
| `{"cmd":"job","action":"pause"}` | 暂停雕刻 | `state==paused` 或 `alarm` |
| `{"cmd":"job","action":"resume"}` | 继续雕刻 | `state==busy` 或 `alarm` |
| `{"cmd":"job","action":"stop"}` | 停止雕刻 | `state==idle` 或 `alarm` |

🔴 **Jog / 回零 / 设原点 / 主轴 等运动指令一律不重发** —— 一次误重发就是一次意外位移。

**两条停止重发的保护**（避免"机器已取消，App 还在重发"）：

1. 收到 `confirm_timeout`（机器明确取消）→ `_settlePendingAcked()` 立即标记已送达并停发。
2. 同类命令只跟踪最后一条 —— 用户连点两次「开始」不会补发两次。

### 改动二：启动三态显示

**新文件**：`lib/features/wizard/job_launch_banner.dart`（共享组件）

| 态 | 文案 | 数据源 |
|---|---|---|
| 已下发（灰，转圈） | 「开始雕刻已下发，等待机器响应…」<br>重试时：「指令未送达，正在重试（第 n 次）…」 | `jobLaunchPhaseProvider` = `dispatched` |
| 待确认（黄） | 「**请在机器上按开始键确认**，确认后才会动刀。」 | `status.awaitingConfirm==true` 或 notify `confirm_required` |
| 加工中（绿） | 横幅隐藏，已由监控页承接 | `status.state==busy` |
| 指令未送达（红） | 「已重试 n 次仍无响应，请检查机器是否联网在线。」 | `delivery==failed` |

**接入位置**：
- 向导确认页（`_ReadyPhase`）：点「开始」后按钮禁用 + 显示「已下发，等待机器响应…」，防连点重复下发。
- 自检页（`self_check_page.dart`）顶部。
- 控制台页（`console_page.dart`）顶部（与原有 `awaitingConfirm` 横幅并存）。

### 新增 notify 事件：`confirm_timeout`

- 处理位置：`hardware_service_real.dart` 的 notify 解析分支。
- 行为：状态回到 `idle`（机器确实取消了）+ 发一次性提示 + **停止重发**。
- **固件后补该事件，App 收到才显示**；老固件不发即无此提示，不会误报。

---

## 三、老固件兼容（无需固件配合，已实测路径）

老固件 `awaitingConfirm` 恒 `false`、收到 start 后直接 `busy`：

```
App 点开始 → dispatched（已下发）
           → 机器直接 busy → running（加工中）
```

中间**不出现**待确认态，`JobLaunchPhase` 从 `dispatched` 直接跳到 `running`。
UI 自然退化为「已下发 → 加工中」，**不报错、不卡住**。

---

## 四、🔴 给固件（屏幕端）的契约要求 —— 需确认

### 必答项 1：重发幂等（**安全红线**）

App 会在"5 秒无回执"时重发 `{"cmd":"job","action":"start"}`，最多 3 次。

**固件必须保证幂等**：

| 场景 | 期望行为 |
|---|---|
| 机器已在加工中，又收到一次 `start` | **忽略**，不重启、不中断当前作业 |
| 机器在待确认态，又收到一次 `start` | **忽略**，不重置确认窗口 |
| 机器已 `confirm_timeout` 取消后收到 `start` | 按新请求处理（App 此时不会自动重发，只会由用户重新触发） |

> 若固件不幂等，请在 `docs/PROTOCOL.md` 明确说明，App 侧改为「重发前先查状态、仅在 idle 时重发」。

### 必答项 2：状态字段与事件

| 契约 | 主题 | 载荷 | 要求 |
|---|---|---|---|
| 待确认 | `cnc/<id>/status` | `{"state":"busy","awaitingConfirm":true}` | 收到 `start` 后、客户按键前持续发 |
| 请求确认 | `cnc/<id>/notify` | `{"type":"confirm_required","msg":"..."}` | 进入待确认时发一次（**非 retain**） |
| 确认超时 | `cnc/<id>/notify` | `{"type":"confirm_timeout","msg":"确认超时已取消"}` | 超时未按键时发，随后状态回 `idle` |

⚠️ `awaitingConfirm` 字段名是**驼峰**（与 `docs/PROTOCOL.md:296` 一致）。
写错会静默失效（App 解析 `j['awaitingConfirm'] == true`）。

### 必答项 3：确认窗口时长

App 侧回执超时是 **5 秒**，但那只是"命令有没有送到"的判定，
**不等于**机器端的确认窗口。请告知机器端确认窗口（建议 30–60 秒），
App 端暂不倒计时，只显示「请在机器上按开始键确认」。

---

## 五、验收方法

### 自测工具

`tools/two_stage_launch_sim.py`（App 仓库内置，需 paho-mqtt）

> 为什么不用 `cnc-control-server/sim/flat_screen_sim.py`：
> 它的 `_cmd_job(start)` **直接 `state=busy`，不发 `awaitingConfirm`、不发
> `confirm_required`/`confirm_timeout`**，复刻的是老固件行为 ——
> 只能验「老固件回归」，验不了「待确认」态。本脚本补上该态，
> 且不侵入 cnc-control-server 项目。

```bash
# 两段式（验收②）
python3 tools/two_stage_launch_sim.py --broker <host> --port 8883 --tls \
    --device cnc-demo-01 --user <u> --password <p> --mode two-stage
# 运行后在控制台输入：key=按下物理键 / timeout=确认超时

# 老固件（验收③）
python3 tools/two_stage_launch_sim.py ... --mode legacy
```

### 三项验收

| # | 场景 | 方法 | 期望 |
|---|---|---|---|
| ① | 断连时点开始 | **手机断网**（飞行模式）→ 点开始 → 恢复网络 | 显示「指令未送达，正在重试」→ 恢复后自动补发并成功 |
| ② | 待确认横幅 | 模拟器 `--mode two-stage` → App 点开始 → 模拟器收到 start | App 显示黄色「请在机器上按开始键确认」；模拟器输入 `key` → 进入加工中 |
| ③ | 老固件回归 | 模拟器 `--mode legacy`（或现有 flat_screen_sim）→ App 点开始 | 直接「已下发 → 加工中」，无待确认态、无报错 |

> 验收 ① 是 **App 侧断网**，模拟器无法模拟，需真机操作。

---

## 六、遗留 / 待 owner 决策

- **确认窗口倒计时**：App 暂不显示倒计时，等固件给出窗口时长再定是否加。
- **`confirm_accepted` 事件**：本模拟器会发，但 `docs/PROTOCOL.md` 尚无此契约；
  若固件要正式化，需补进协议文档（App 目前未消费，不影响）。

# 屏幕 / 固件端（cnc-fw）待办工单 — 2026-08-31 代码实证版

> **本文每一条结论都来自实际读代码，附 `文件:行号`。未读到的不写，推断的标「待固件端确认」。**
> 目的是避免"凭想象列需求"，也避免把已经做完的事再提一遍。

---

## 零、验证基线（请先确认我读的是不是你那份代码）

| 项 | 值 |
|---|---|
| 代码位置 | `C:\Users\thwan\WorkBuddy\cnc-fw` |
| 关键文件最后修改 | `cnc_config.c` 08-15 11:24、`cnc_mqtt.c` 08-15 11:26、`cnc_mqtt.h` 08-15 11:27、`heartbeat.c` 08-13 11:33 |
| **基线快照** | **本地工作区的最后改动是 2026-08-15，已 16 天未变** |

> ⚠️ **若固件端在此之后已有新提交但未同步到这个工作区，请以你的代码为准**，
> 并直接用本文 §五的「自查命令」逐条复核 —— 每条都给了 grep 命令，一分钟就能验完。
> 凡复核后与本文不符的，请直接回一句"第 S-x 条已改"，我这边更新。

---

## 一、P0 — 阻塞（卖第一台机器之前必须解决）

### S-1 🔴🔴 Feed Hold 不该由 App 心跳决定（P0-5 的固件侧落实）

**代码实证**：

| 事实 | 出处 |
|---|---|
| 心跳超时默认 **15 秒** | `components/heartbeat/heartbeat.c:27` `static uint32_t s_timeout_ms = 15000;` |
| **收到任意 App 命令**就刷新心跳（不只 `hello`） | `components/mqtt_client/cnc_mqtt.c:89` `heartbeat_touch();` —— 位于 `cmd` 字段校验通过之后 |
| 超时即调 `gcode_sender_pause()`（Feed Hold） | `heartbeat.c:62-67` |
| **LAN TCP 也会 touch**（与 MQTT 走同一入口，注释无误） | `components/lan_tcp/lan_tcp.c:77` → `cnc_mqtt_dispatch()` → `dispatch_command()` → `heartbeat_touch()` |
| 一旦 armed，**永不自动解除** | `heartbeat_reset()` 全库**零调用**（只有定义与 map 符号） |

**🔑 决定性反证（这一条让结论无可辩驳）**：

```
components/gcode_sender/gcode_sender.c:203
esp_err_t gcode_sender_start(const char *filepath)
```

屏幕的雕刻是**从本地文件路径 fopen 逐行发给 GRBL**（文件在 `sender_task` 里打开，
见 `gcode_sender.c:222-226` 注释）。

> **也就是说：雕刻全过程完全在屏幕本地闭环，根本不需要 App 在场。**
> 那么"App 15 秒没心跳就暂停"这条规则，保护的不是一个真实存在的风险，
> 而是凭空制造了一个报废风险。

**现实伤害（按客户真实操作推演）**：

```
客户用 App 点了一下 Jog 对刀（→ armed = true）
   ↓
客户锁屏 / 切微信 / 家里 Wi-Fi 抖一下
   ↓
15 秒
   ↓
gcode_sender_pause() → 雕刻中断 → 工件报废
```

App 侧心跳周期是 10s（`hardware_service_real.dart:51`），阈值 15s —— **只有 5 秒余量**，
一次普通的手机网络切换就会触发。

**要求（固件侧定，App 不单方决定）**：

1. **默认**：Feed Hold / 急停等运动安全改为**屏幕·主控本地闭环**，网络命令不参与。
2. `heartbeat_touch()` 降级为「App 在线状态」上报，**不再触发任何运动控制**。
3. 若产品上确实要"远端失联停机"，必须是：**显式可选策略 + 默认关闭 + 分钟级阈值**（如 5 分钟），
   且只在「作业由 App 发起」时才可能启用。
4. 顺带修：`heartbeat_reset()` 应能在作业结束/急停后调用，否则 armed 会跨作业残留。

**一句话给固件**：
> 「固件 15s Feed Hold 现在的重置条件是『收到任意 cmd』吗？如果是，
> 请改为屏幕/主控本地喂狗 —— 因为雕刻本身是本地文件闭环（`gcode_sender_start(filepath)`），
> 不依赖 App。现在这个设计会让客户锁屏就把工件废掉。」

---

### S-2 🔴 设备码写不进去（量产统一机器码的硬阻塞）

**代码实证**：

| 事实 | 出处 |
|---|---|
| 设备码默认由 **MAC 派生**为 `LY3020-%02X%02X%02X` | `cnc_config.c:34-42` |
| NVS 里若没有 `device_id`，就用这个 MAC 派生值 | `cnc_config.c:62-64` |
| **`cnc_config_set()` 在整个代码库零调用** | 全库 grep：只有 `cnc_config.h:47` 声明 + `cnc_config.c:124` 定义 |

**后果（三处不一致）**：

| 端 | 设备码来源 | 实际值 |
|---|---|---|
| 屏幕 | MAC 派生 | `LY3020-A1B2C3` |
| 阿里云 | 人工录入 | `cnc-demo-03` |
| 摄像头 | 硬编码 / NVS | `cnc-demo-03` |

→ 屏幕 MQTT 用户名会变成 `screen-LY3020-A1B2C3`（`cnc_config.c:44-47`），
**不在 EMQX `acl.conf` 放行名单内**（目前只放行 `screen-cnc-demo-01/02/03` 与 `3020-2.0`），
机器连上 broker 也会被全部拒绝。

**要求**：提供写入设备码的途径。建议三选一或组合：

1. **产线写入**：NVS `cnc_cfg/device_id`（推荐，配合 S-3 的配网）；
2. **配网写入**：配网成功时云端下发设备码，屏幕 `cnc_config_set()` 落盘；
3. **串口指令**：产线/售后用 `SET:DEVICE:<code>` 之类指令写入（作为保底）。

> ⚠️ 顺带确认：设备码格式必须同时满足
> ① 阿里云绑定表 ② EMQX `acl.conf` 的 `screen-<id>` ③ 摄像头 `cam-<id>` 正则 `^cam-[a-z0-9-]+$`。
> 当前 `LY3020-A1B2C3` **含大写字母**，若最终规范要求小写会直接不匹配。**格式需要现在就定死。**

---

### S-3 🔴 配网功能完全未实现（与 owner 认知冲突，请确认）

> owner 明确答复过：「**配网由屏幕完成**，密码同时下发给屏幕 ESP32 和摄像头芯片，客户只配一次」。
> 但代码里**找不到配网的实现**。

**代码实证**：

| 事实 | 出处 |
|---|---|
| Wi-Fi 只有 **STA 模式**，无 AP / SmartConfig / BlueIF | `wifi_manager.c:142` `esp_wifi_set_mode(WIFI_MODE_STA);` —— 全文件唯一一次 set_mode |
| **`wifi_manager_connect()` 在应用代码零调用** | `main/` 下 grep 只有 `wifi_manager_init()`（main.c:142）与 `wifi_manager_auto_connect()`（main.c:213） |
| 而 `auto_connect()` 是从 NVS **读**已存凭证 | `wifi_manager.c:276` `nvs_get_blob(..., WIFI_NVS_KEY_SSID, ...)` |
| 唯一会**写** NVS 凭证的是 `wifi_manager_connect()`（`:179-180`），但它没被调用 | 死循环 |
| UI 的「WiFi 联网」只是个**开关**，弹 toast 后什么都不做 | `main/ui/user_lv_settings.c:28` `g_kv.wifi = on; karva_toast(...)` |
| 设置页只有 4 项：亮度 / WiFi 开关 / 语音 / 仓盖 | `user_lv_settings.c:44-69` |
| UI 目录里**没有配网页面** | `main/ui/` 共 11 个 `user_lv_*.c`，无 wifi / provision / network |

**后果（连锁失效）**：

```
NVS 里没有 Wi-Fi 凭证
   ↓
wifi_manager_auto_connect() 返回 false
   ↓
main.c:213 的 if 块整个不执行
   ↓
MQTT / LAN TCP :8899 / UDP beacon :45454 / 文件服务器 —— 全部不启动
```

（除非产线预先把凭证烧进 NVS —— 这在量产下同样不可行，客户家里的 Wi-Fi 出厂时不可能知道。）

**要求**：
1. 实现配网：**SoftAP +  captive portal**（推荐，客户手机连机器热点配网）或 SmartConfig；
2. 配网流程里**同时**向摄像头下发「SSID + 密码 + 设备码」（方案 C，见 S-9）；
3. 配网成功后写入 NVS 并重启网络服务（当前 MQTT 只在启动时拉起，配网后需要能重新触发）。

---

### S-4 🔴 没有启动雕刻的路径（`gcode_sender` 没接线）

**代码实证**：

| 事实 | 出处 |
|---|---|
| 启动文件雕刻的 API 是 `gcode_sender_start(const char *filepath)` | `gcode_sender.c:203` |
| **全库零调用** | grep `gcode_sender_start(` → 仅定义一处 |
| UI 只用 `gcode_sender_send_line()` 发单行（jog / home / G28 等） | `main/ui/user_lv_3dprinter_control.c:20,31,36,53,63,70` |
| 作业设置页只展示文件信息，没有启动按钮的调用 | `main/ui/user_lv_jobsetup.c:169-361` 全是 `kv_label()` 渲染 |
| MQTT 命令里 `{"cmd":"job","action":"start"}` 只发 `~`（cycle start） | `cnc_mqtt.c:157` `gcode_sender_send_line("~")` |

**后果**：
- 屏幕端**无法从文件开始一次雕刻**；
- App 的「开始雕刻」发 `job/start`，但屏幕上没有已加载的作业 → `~` 无意义；
- 这是 App 6 步向导走到最后一步落不了地的固件侧原因之一。

**要求**：
1. 在 UI（作业设置 / 雕刻页）把「开始」按钮接到 `gcode_sender_start(g_job.file_path)`；
2. 若需要支持 App 远程启动，需新增命令（如 `{"cmd":"job","action":"load","file":"<path>"}`）
   —— **但这属于产品决策**，先确认「App 能不能远程发起雕刻」再定。

---

## 二、P1 — 功能缺口（本周内）

### S-5 🟠 `cnc/<id>/notify` 从未发布

**实证**：`cnc_mqtt_publish_notify()` 定义于 `cnc_mqtt.c:455`，但**全库零调用**。

**后果**：App 已订阅 `cnc/<deviceId>/notify`（`hardware_service_real.dart:283`），
但固件从不发 → **加工完成、报警、机旁确认这三类提示 App 永远收不到**。

**要求**：在关键事件点调用它：
- 雕刻完成（`sender_task` 的 program_completed 分支）
- GRBL 进入 Alarm
- 需要机旁确认（`s_awaiting_confirm` 置位时）

载荷格式请对齐 App `NotifyEvent`（建议先与 App 侧对齐字段名再实现）。

### S-6 🟠 订阅了 `cnc/broadcast/#` 但从不处理

**实证**：

```c
// cnc_mqtt.c:326
if (strcmp(topic, s_topic_cmd) == 0) {
    dispatch_command(data, dlen);
} else {
    ESP_LOGD(TAG, "ignored topic=%s len=%u", topic, ...);   // ← 广播全落这里
}
```

订阅在 `cnc_mqtt.c:296`，但分发只认 `cnc/<id>/cmd` 这一个精确匹配。

**要求**：补一个 `cnc/broadcast/#` 的处理分支（系统公告、固件升级通知等），
或者明确"屏幕不需要广播"就**取消订阅**（省资源、避免误导排查）。

### S-7 🟠 状态枚举缺 `homing`

**实证**：`map_state()`（`cnc_mqtt.c:199-206`）只返回 `idle` / `busy` / `paused` / `alarm`。
契约状态枚举是 `disconnected | idle | homing | busy | paused | alarm`。

**后果**：回零过程中 App 看到的是 `idle`（`grbl` 的 `Home` 被 `:205` 归到 idle），
客户无法区分「待机」与「正在回零」。

**要求**：GRBL 状态为 `Home` 时映射为 `homing`。

---

## 三、P2 — 缺陷与改进（排期做）

### S-8 UDP beacon 的 IP 只取一次，重连后广播旧 IP

**实证**：`udp_beacon.c:50-63` —— `ip_buf` 在 `while (s_running)` 循环**之外**取值，
`beacon_task` 启动时读一次就固定了。

**后果**：Wi-Fi 断开重连、路由器重新分配 IP 后，广播的仍是旧 IP
→ App 自发现（`CNC-SCREEN|<ip>|8899|screen-<id>`）连到错误地址。

**要求**：把取 IP 挪进循环内，每轮广播前重新读 `esp_netif_get_ip_info()`。

### S-9 🟡 与摄像头之间的 UART 通道不存在（方案 C 的软件前提）

**实证**：

| 事实 | 出处 |
|---|---|
| UART1 = GRBL（TX 16 / RX 15） | `main.c:183` |
| UART2 = **PC 上位机**（TX 19 / RX 20），且是**纯透传** UART2→UART1 | `uart_relay.c:5-6, 39-42` |
| **没有第三条 UART 连摄像头** | 全库 grep `UART_NUM_` 只有 1 和 2 |

> ⚠️ **注意**：`uart_relay` 是「PC ↔ GRBL 直通」，**不是**给摄像头下发配置的 provisioning 通道。
> 摄像头端那个 provisioning UART 在 `esp32s3-cam` 工程（已迁到 GPIO 22/23），
> **屏幕这一侧还没有对应的主机实现** —— 通道目前是单向缺失的。

**✅ 好消息：硬件上可行** —— 屏幕端 GPIO 22 / 23 **空闲**。
LCD 占用的是：3, 46, 5, 7, 14, 38, 18, 17, 10, 39, 0, 45, 48, 47, 21, 1, 2, 42, 41, 40
（`rgb_lcd_port.h:66-95`），UART1 用 16/15，UART2 用 19/20 —— **22/23 未被占用**。

**要求**：
1. 新增一条 UART（建议 GPIO 22/23，与摄像头端对齐）；
2. 协议在 `ssid|pass` 基础上扩展 `device` 字段；
3. **顺带下发摄像头推流 token**（见 `docs/40` §12 —— 与设备码同一次改造，别让摄像头烧两次固件）。

### S-10 状态帧若干字段恒为固定值

**实证**（`build_status_json()`，`cnc_mqtt.c:209-253`）：

| 字段 | 当前值 | 说明 |
|---|---|---|
| `rpm` | 恒 `0` | 注释写着"真实转速需解析 spindle/FS" |
| `feed` / `speed` | 恒 `0` | 契约占位 |
| `etaSec` | 恒 `null` | App 的剩余时间永远不显示 |
| `scIndex` / `scTotal` | 硬编码 `0` / `5` | 自检进度不会动 |

**影响**：App 上转速、进给、剩余时间、自检进度全部无数据。不阻塞，但客户看得到"空"。

### S-11 MQTT 密码 `demo123` 全设备共享

**实证**：`cnc_config.c:29` 默认值 `demo123`。所有屏幕共用同一密码。

**说明**：这条**不单独要求固件改** —— 它与 MQTT 侧的 M-7（量产账号自动创建）是同一件事。
需等 MQTT 侧定方案（HTTP 认证 / 设备自注册）后一起改。此处仅登记，避免遗漏。

---

## 四、已核实正常的项（请勿重复劳动）

| 项 | 结论 | 出处 |
|---|---|---|
| MQTT clientId `screen-<deviceId>` | ✅ 正确 | `cnc_mqtt.c:359` |
| MQTT 用户名派生 `screen-<id>` | ✅ 正确 | `cnc_config.c:44-47` |
| LWT 载荷 `{"state":"disconnected"}`（QoS1 + retain） | ✅ 与 App 契约一致，没用错字符串 | `cnc_mqtt.c:56, 396-400` |
| 订阅 `cnc/<id>/cmd` + `cnc/broadcast/#` | ✅ 与 ACL 一致 | `cnc_mqtt.c:295-296` |
| 主题命名 `cnc/<id>/{cmd,status,notify,telemetry,log}` | ✅ 正确 | `cnc_mqtt.c:64-68` |
| UDP beacon 格式 `CNC-SCREEN\|<ip>\|8899\|screen-<id>` | ✅ 与契约一致 | `udp_beacon.c:63` |
| UDP beacon 端口 45454 / 周期 3s | ✅ 正确 | `udp_beacon.c:21-22` |
| LAN TCP :8899 | ✅ 已启动 | `main.c:240` |
| 摄像头 `{"action":...}` 帧不会误触发心跳 | ✅ 安全（无 `cmd` 字段，在 `:82` 就被拒） | `cnc_mqtt.c:81-89` |
| 雕刻从本地文件读取、本地闭环 | ✅ 正确，这正是 S-1 能安全改的依据 | `gcode_sender.c:203` |
| status 发布频率 | ✅ 由 GRBL 状态回调驱动（轮询 230ms） | `main.c:285`、`cnc_mqtt.c:268-276` |

---

## 五、给固件端的自查命令（一分钟验完，请复核后回我）

```bash
cd C:/Users/thwan/WorkBuddy/cnc-fw

# S-1  心跳阈值与 touch 点
grep -rn "s_timeout_ms = 15000\|heartbeat_touch\|heartbeat_reset" components/ main/

# S-2  设备码写入（若只有定义没有调用 = 写不进去）
grep -rn "cnc_config_set" components/ main/

# S-3  配网（若 wifi_manager_connect 只在 wifi_manager.c 内出现 = 没接线）
grep -rn "wifi_manager_connect\|WIFI_MODE_AP\|WIFI_MODE_APSTA" components/ main/
grep -rn "wifi" main/ui/user_lv_settings.c

# S-4  启动雕刻（若 gcode_sender_start( 只有定义 = 没接线）
grep -rn "gcode_sender_start(" components/ main/

# S-5  notify 发布
grep -rn "cnc_mqtt_publish_notify" components/ main/

# S-6  广播处理
grep -rn "broadcast" components/mqtt_client/cnc_mqtt.c

# S-7  homing 映射
grep -n "map_state" -A 8 components/mqtt_client/cnc_mqtt.c

# S-8  beacon IP 取值位置（在 while 内还是外）
grep -n "ip_buf\|while (s_running)" components/udp_beacon/udp_beacon.c

# S-9  第三条 UART
grep -rn "UART_NUM_" components/ main/
```

> 每条命令的"异常输出特征"都在上文对应小节里写了。
> 复核后请把与本文不符的条目编号告诉我，我这边同步更新。

---

## 六、可直接转发的消息

> @屏幕/固件 我把 `cnc-fw` 的代码逐行读了一遍，列出待办如下（每条都附文件行号，可用文末 grep 命令一分钟复核）。
> **基线说明**：我读的是本地工作区，**最后改动是 08-15**。若你之后有更新，请复核后把不符的条目编号回给我。
>
> **P0（阻塞量产）**
> 1. **S-1 Feed Hold 不该看 App 心跳**。`heartbeat.c:27` 15s、`cnc_mqtt.c:89` 任意命令 touch、超时即 pause。但 `gcode_sender.c:203` 的 `gcode_sender_start(filepath)` 是从**本地文件**逐行发给 GRBL 的，雕刻完全本地闭环、不需要 App 在场。所以这条规则保护的是不存在的风险，却会让客户锁屏 15 秒就废工件。请改成本地喂狗；真要"远端失联停机"必须是可选 + 默认关 + 分钟级。另外 `heartbeat_reset()` 全库零调用，armed 会跨作业残留。
> 2. **S-2 设备码写不进去**。`cnc_config_set()` 全库零调用，设备码只能由 MAC 派生成 `LY3020-A1B2C3`（`cnc_config.c:34-42`）。这跟阿里云的 `cnc-demo-03`、摄像头的码都不一致，MQTT 用户名 `screen-LY3020-XXX` 也不在 ACL 放行名单里。需要产线/配网/串口至少一条写入途径。**设备码格式（大小写、字符集）现在就要定死**，它同时约束屏幕、摄像头正则、阿里云。
> 3. **S-3 配网完全没实现**。`wifi_manager.c:142` 只有 STA，`wifi_manager_connect()` 零调用，设置页的"WiFi 联网"只是个 bool 开关（弹个 toast 就完了，`user_lv_settings.c:28`）。后果：NVS 里永远没凭证 → auto_connect 失败 → MQTT/LAN TCP/UDP beacon/文件服务器**全部不启动**。需要 SoftAP 或 SmartConfig，并在配网时把 SSID+密码+设备码一起下发给摄像头（方案 C）。
> 4. **S-4 没法启动雕刻**。`gcode_sender_start(filepath)` 全库零调用，UI 只用 `send_line()` 发单行。作业设置页也只有展示没有启动。请把"开始"按钮接上，或确认 App 能否远程发起（涉及产品决策）。
>
> **P1（本周内）**
> 5. **S-5 notify 零发布**：`cnc_mqtt_publish_notify()` 没有调用点 → App 收不到加工完成/报警/机旁确认。
> 6. **S-6 订阅了 broadcast 但不处理**：`cnc_mqtt.c:326` 只认 cmd 精确匹配，广播全落 else 被忽略。要么补处理，要么取消订阅。
> 7. **S-7 缺 homing**：`map_state()` 把 GRBL 的 `Home` 归成了 idle，App 分不清"待机"和"正在回零"。
>
> **P2（排期）**
> 8. **S-8 beacon IP 只取一次**：`udp_beacon.c:50-63`，IP 在 while 循环外取，重连换 IP 后广播的还是旧地址。
> 9. **S-9 没有连摄像头的 UART**：cnc-fw 只有 UART1(GRBL,16/15) 和 UART2(PC,19/20)，`uart_relay` 是 PC↔GRBL 透传不是 provisioning。好消息是 **GPIO 22/23 在屏幕端空闲**（LCD 占的是 3,46,5,7,14,38,18,17,10,39,0,45,48,47,21,1,2,42,41,40），硬件可行。建议新增 UART 并对齐摄像头端已改的 22/23，协议加 `device` 字段，**顺带把推流 token 一起下发**（docs/40 §12）。
> 10. **S-10 状态字段恒 0**：rpm/feed/speed 恒 0、etaSec 恒 null、scIndex/scTotal 硬编码 0/5。
>
> **已核实正常（不用改）**：clientId `screen-<id>`、LWT `{"state":"disconnected"}`、订阅 cmd+broadcast、主题命名、beacon 格式与端口、LAN TCP 8899、**摄像头 action 帧不会误触发心跳**（无 cmd 字段会被拒）、雕刻本地文件闭环。
>
> 完整工单：`docs/42-screen-firmware-open-items-20260831.md`（wangalex130-netizen/alexcnc，main）

# 各端未完成事项总表（2026-08-30 15:50 多方核对版）

> **本文只收已落地核实的事实**（每条都给了文件出处），以及由此推导出的未完成事项。
> 凡没有出处的，一律标为「未确认」，不写进结论。
> 目的：让 App / 摄像头 / MQTT / 阿里云(PC工程师) / 固件(屏幕) 五端对同一套事实说话。

---

## 零、已核实的事实基线（可直接引用，勿再争论）

### 0.1 MQTT / broker 侧

| # | 事实 | 出处 |
|---|---|---|
| 1 | `app-demo` ACL 已改为**通配** `cnc/+/...`（发布 + 订阅），`gw/` 已清除 | `cnc-control-server/deploy/acl.conf:22-23` |
| 2 | **线上只有一个授权源**：文件源 `acl.conf` | `acl.conf:4-12` 注释（EMQX API 实锤）+ `deploy/docker-compose.cloud.yml:41` 仅声明 `{"type":"file"}` |
| 3 | 摄像头用**正则**授权 `{re,"^cam-[a-z0-9-]+$"}`，发布限 `cnc/+/cam`（**不是 status**） | `acl.conf:54-55` |
| 4 | `3020-2.0` 是**真实存在的 MQTT username**（生产机器直连，历史遗留），已原样保留 | `acl.conf:43-44` |
| 5 | `cnc-relay` 在仓库侧已无任何规则（只剩一条说明性注释） | `grep cnc-relay deploy/` 无规则输出 |
| 6 | **仓库 compose 写 `DENY_ACTION=disconnect`，线上实际是 `ignore`** —— 两者分叉 | `docker-compose.cloud.yml:43`（仓库）vs MQTT 报告 `docs/48` §6.4（线上） |
| 7 | 服务器部署目录 `/home/ubuntu/cnc-control`，**compose 文件名是 `docker-compose.yml`**（不是仓库里的 `docker-compose.cloud.yml`） | MQTT 报告 `docs/48` §1 |
| 8 | `docker-compose.emqx.yml` 也存在同样的 `DENY_ACTION=disconnect`，**两个文件都要改** | `docker-compose.emqx.yml:40` |

> ⚠️ **关于第 6 条的方向**：必须是**仓库改成 `ignore` 迁就线上**。
> 绝不能反过来把线上改成 `disconnect` —— 那会让被拒的设备直接掉线，而不是"点了没反应"。

### 0.2 App 侧（本次全部读代码核实）

| # | 事实 | 出处 |
|---|---|---|
| 9 | MQTT 默认 `43.154.192.242` / `8883(TLS)` / `app-demo` / `demo123` | `lib/app/config.dart:75-84` |
| 10 | 中继默认 `http://39.106.144.53:8080`，token `lunyee-cnc-relay-7k2p`，兜底设备码 `cnc-demo-01` | `config.dart:30-43` |
| 11 | 设备 ID 来自后端 `/api/machine/list` 的 **`code` 字段**（`sn` 兜底），选中后驱动 7 处 | `lib/services/machines_service.dart:36`、`lib/state/providers.dart:81-83` |
| 12 | **App 没有订阅 `cnc/<id>/cam`** —— 只订阅 status / notify / telemetry / broadcast.msg / broadcast.system（及 v11 的 job、sys） | `lib/services/hardware_service_real.dart:251-262` |
| 13 | `useRealBackend` 默认 **false**（Mock） | `config.dart:47-48` |
| 14 | 未显式设置 MQTT 协议版本，走 `mqtt_client` 库默认（v3.1） | `hardware_service_real.dart:237`（用 `MqttConnectMessage()`） |
| 15 | `mqtt_client 10.5.0` **不支持 MQTT 5**（官方 API 只有 `setProtocolV31()` / `setProtocolV311()`） | pub.dev API 文档 |
| 16 | `isDefault` 字段解析了但**代码里没有任何地方使用** → 登录后不会自动选中机器 | 全库 grep 仅出现在 `machines_service.dart` 定义/解析/序列化 |
| 17 | `relay_url` / `cam_device` 解析了但**拉流不用** —— 中继基址固定用 `AppConfig.cameraRelayBaseUrl` | `machines_service.dart:68-72`（注释说明是有意为之） |

### 0.3 ✅ 已闭环：测试账号同时绑定 03 / 02 / 01（2026-08-30 17:05 App 截图证实）

用户手机登录 `Lunyee@517788.xyz` 后「我的机器」列表实际显示：

| 机器名 | 设备码 | 状态 |
|---|---|---|
| 3020 Nova | **`cnc-demo-03`** | 不在线（周日屏幕未开） |
| 3020 Nova | `cnc-demo-02` | 不在线 |
| 3020 New | **未配置机器码** | 未配置 |
| 3020 Nova | `cnc-demo-01` | 不在线 |

**结论**：

1. **摄像头切 `cnc-demo-03` 方向正确** —— `docs/36` 的判断成立。
2. `machines_service.dart:122` 那条「测试账号 `3020 Nova` 已预绑定 `cnc-demo-01`」的注释**过期且误导**，需改为「该账号下有多台测试机器，以用户选中者为准」。
3. **新增证据**：列表里有一台「未配置机器码」，`code`/`sn` 为空 → 点播放会生成 `/stream/?token=...` 这类无效 URL。这是 **A-1 必须做的直接证据**。

> 备注：此前我尝试直接调后端接口实测，被 `037123.xyz` 的 **Cloudflare 1010（反爬拦截）**挡住；
> 最终由用户在真机上截图闭环。**凡涉及线上后端返回值，一律以真机实测为准，不以代码注释为准。**

---

## 一、各端未完成事项

### 1.1 App 端（本轨）

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| A-1 | 清除硬编码 `cnc-demo-01` 兜底 + 空设备码防护 | ✅ **已确认要做** | 方案 C：不换数字，而是删掉 `console_page._resolvedRelayUrl` 的兜底（与全屏页对齐，真实模式未选机器返回空 + 提示），并把 `AppConfig.deviceId` / `cameraRelayDevice` 的默认值整体清除。**新增**：`streamUrl()` 里 `sn` 与 `camDevice` 皆空时（"未配置机器码"那台）会拼出 `/stream/?token=...`，必须拦住 |
| A-2 | 加 `onSubscribeFail` 回调 | ⏳ 待拍板 | 订阅被拒（SUBACK 0x80）时提示，把"静默 Jog 锁死"变成可见错误。**v3.1.1 就能用，不需要换包**。当前 ACL 已通配，优先级低于 A-1/A-3/A-6 |
| A-3 | 订阅 `cnc/<id>/cam` | ✅ **已确认要做** | App 目前**收不到**摄像头的 `{"streaming":true}` / `{"online":true}`（只订阅了 status/notify/telemetry/broadcast）。实测"点播放后要等一二十秒才出画面"正是缺这个状态确认 |
| A-4 | 显式 `setProtocolV311()` | 💡 建议 | 现在走库默认 v3.1；零风险补齐。**但不要改投 MQTT 5**（见 0.2 第 15 条，需换包） |
| A-5 | `isDefault` 自动选中默认机器 | 💡 建议 | 目前登录后必须手点机器才生效；若后端会返回 `isDefault`，可补自动选中 |
| **A-6** | **App 侧 30s 续租** | 🔴 **必须与 C-2 配套** | 见下方「⚠️ C-2 硬冲突」。App 目前**只在打开预览和 MQTT 重连时发一次 `stream_start`，没有任何周期性续租**（`fullscreen_preview_page.dart:98/100-106/111`）。**若摄像头先加 90s 看门狗，画面会在 90 秒时断掉** |

> **调试前必读**：`useRealBackend` 默认 **false**。接真机调试必须在「联调设置」里打开「真实后端」，
> 或出包时带 `--dart-define=USE_REAL_BACKEND=true`。**不开就是 Mock，什么都连不上。**

### 1.2 摄像头端

| # | 事项 | 状态 |
|---|---|---|
| C-1 | 确认**心跳容忍**：继续忽略非 `action` 字段的帧 | ✅ **可以催，且现在正是时机** |
| C-2 | 加 **90s 看门狗**（无续租自动停推） | ⛔ **有硬冲突，必须先做 A-6** |
| C-3 | 固件加 **token 默认值**（`lunyee-cnc-relay-7k2p`） | 💡 建议（它自己在考虑） |
| C-4 | 设备码目前**硬编码三处** → 量产须改 NVS / 自注册 | 📅 量产前 |
| C-5 | **认知纠正**：「`cnc-demo-03` 在 `app-demo` 枚举白名单内」已过时 | ⚠️ 需同步 |

> C-5 的准确说法：`app-demo` 已于 2026-08-30 13:35 改为**通配** `cnc/+/...` 并上线。
> **任意新增设备码都已放行**，不是"03 正好在名单里"。结论对但理由错，会在讨论新机器时误导判断。

### ⚠️ C-2 硬冲突（必须一起做，且 App 先做）

**事实链**（全部读代码得出）：

1. 摄像头看门狗的语义是「**一定时间内没收到续租信号就停止推流**」。
2. App 目前**没有任何周期性续租** —— `stream_start` 只在两个时刻发一次：
   - 打开全屏预览时（`fullscreen_preview_page.dart:98 → 111`）
   - MQTT 连接状态变为 connected 时补发一次（同文件 `:100-106`）
3. 退出预览才发 `stream_stop`（`:130`）。

**推论**：若摄像头现在单独上线 90s 看门狗，用户打开预览后**第 90 秒画面会断**，
而且 App 不会自动补发 —— 这是一次**倒退**（当前连续观看是正常的）。

**正确顺序**：

```
① App 先加 30s 周期性续租（A-6）
        ↓ 双方确认续租信号格式（建议沿用 {"action":"stream_start"}，幂等即可）
② 摄像头再加 90s 看门狗（C-2）
        ↓
③ 联调验证：连续观看 3 分钟不断流；杀掉 App 后 90s 内自动停推
```

> **给摄像头的话要改**：不要说「加 90s 看门狗」，要说
> 「看门狗需要和 App 的续租配套上线，App 那边还没做续租，请先别单独上；
> 或者你先告诉我要用什么帧做续租信号（沿用 `stream_start` 还是新增 `stream_ping`），我们对齐后再一起上。」

### ✅ C-1 现在正是验证时机

App 每 **10 秒**往 `cnc/<deviceId>/cmd` 发一次心跳 `{"cmd":"hello"}`
（`hardware_service_real.dart:638-640`，用于重置机器主控 15s Feed Hold）。
摄像头订阅的是**同一个主题** `cnc/cnc-demo-03/cmd`。

→ 摄像头**每秒钟级别地**会收到非 `action` 帧。它必须：
- 只认 `action` 字段；
- 收到 `{"cmd":"hello"}` 时**不做任何动作、不回任何状态帧**。

若它有任何"收到消息就唤醒/重置"的逻辑，都会被这个心跳触发。推流既然已跑通，现在正是验证窗口。

### 1.3 MQTT / broker 端

| # | 事项 | 状态 |
|---|---|---|
| M-1 | 确认 `cam-cnc-demo-01` **客户端**是否已自动消失（摄像头重刷成 03 后应已掉线），如仍在请踢除 | ✅ 可以发。（账号建议**暂不删**，留作回退；只清理在线客户端） |
| M-2 | ~~预备：若为 01 则补 `cam-cnc-demo-01` 账号~~ | ✅ **已作废** —— 0.3 已确认绑的是 03，不需要回退到 01 |
| M-3 | 仓库 `DENY_ACTION` 改 `ignore`（对齐线上） | ✅ 可以发。**两个文件都要改**：`docker-compose.cloud.yml:43` 与 `docker-compose.emqx.yml:40`，两处都是 `disconnect`。`docker-compose.mosquitto.yml` 不涉及（它用 mosquitto 的 acl.conf，不是 EMQX 环境变量） |
| M-4 | 把 `svc-bridge-aliyun-api` 的密码**通过单独安全渠道**给用户（不要发群/仓库） | ⏳ |

### 1.4 阿里云 / PC 工程师

| # | 事项 | 状态 |
|---|---|---|
| P-1 | ~~决定性：后端 `code` 是 03 还是 01~~ | ✅ **已闭环**（0.3 截图证实绑的是 03，且同时还有 02/01） |
| P-1b | 🆕 「未配置机器码」那台机器为何没 `code`？是否应自动补、或禁止绑定 | 💡 可问（不阻塞） |
| P-2 | A3：登录后下发按账号签发的中继 token + 有权拉流标记（App 现硬编码） | ❓ 未回 |
| P-3 | A4：刀仓 `bit-config` 的 `slot1~4` 语义，及更新后是否下发 MQTT | ❓ 未回 |
| P-4 | 云网关从 `admin`（全权限）切到 `svc-bridge-aliyun-api` | ⏳ 依赖 M-4 |
| P-5 | 建议：后端别再返回 `cam_device` / `cameraId`，或让它等于 `code` | 💡 |

### 1.5 固件 / 屏幕端

| # | 事项 | 状态 |
|---|---|---|
| F-1 | `3020-2.0` 等历史机器码迁移到 `screen-<deviceId>` | 📅 量产统一命名时 |

---

## 二、阻塞依赖顺序（不能颠倒）

```
【已解除】P-1 后端 code = cnc-demo-03  ✅ 摄像头方向正确，无需回退

【必须串行】A-6（App 30s 续租） → C-2（摄像头 90s 看门狗）
           ↑ 反过来做会让画面在第 90 秒断掉，是倒退

【必须串行】M-4（取 svc-bridge 密码） → P-4（云网关从 admin 切过去）

【可并行、互不依赖】
  A-1 / A-3 / A-4 / A-5（App）
  C-1 / C-5（摄像头）
  M-1 / M-3（MQTT）
  P-2 / P-3 / P-5（阿里云）
```

---

## 三、五端状态速查

| 端 | 关键阻塞 | 能否自行推进 |
|---|---|---|
| App | 无硬阻塞（登录态链路已通） | ✅ 可推进 A-1~A-5（待拍板） |
| 摄像头 | 等 P-1 结论确认方向对不对 | ⚠️ 方向未定前勿再改设备码 |
| MQTT | 等 P-1 决定是否补 `cam-cnc-demo-01` 账号 | ✅ M-1/M-3/M-4 可并行 |
| 阿里云 | **P-1 是全局第一优先** | ❌ 必须由它回答 |
| 固件/屏幕 | 无 | 📅 不急 |

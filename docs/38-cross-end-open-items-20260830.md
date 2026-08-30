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

### 0.3 ⚠️ 唯一未确认、且具决定性的事实

| 项 | 矛盾内容 |
|---|---|
| 测试账号 `Lunyee@517788.xyz` 绑定的设备码 | `lib/services/machines_service.dart:122` 注释写 **`cnc-demo-01`**<br>`docs/36` §十四 A1 / §十五 写 **`cnc-demo-03`** |

**为什么这是决定性的**：摄像头已按"测试账号绑 03"刷成 `cnc-demo-03`。
若实际是 `cnc-demo-01`，则登录后会：拉 `/stream/cnc-demo-01`（空）+ 控 `cnc/cnc-demo-01/cmd`（摄像头收不到），
**两边都没坏，就是对不上**。

**我已尝试实测，失败**：`POST https://037123.xyz/api/auth/android/login` 返回
**HTTP 403 / Cloudflare `error code: 1010`**（反爬拦截，非服务端逻辑错误），沙箱内无法绕过。

---

## 一、各端未完成事项

### 1.1 App 端（本轨）

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| A-1 | 清除硬编码 `cnc-demo-01` 兜底 | ⏳ **待你拍板** | 方案 C：不换数字，而是删掉 `console_page._resolvedRelayUrl` 的兜底（与全屏页对齐，真实模式未选机器返回空 + 提示），并把 `AppConfig.deviceId` / `cameraRelayDevice` 的默认值整体清除 |
| A-2 | 加 `onSubscribeFail` 回调 | ⏳ **待你拍板** | 订阅被拒（SUBACK 0x80）时提示，把"静默 Jog 锁死"变成可见错误。**v3.1.1 就能用，不需要换包** |
| A-3 | 订阅 `cnc/<id>/cam` | 🆕 本次新发现 | App 目前**收不到**摄像头的 `{"streaming":true}` / `{"online":true}`。影响：发完 `stream_start` 后无法确认摄像头是否真的启动了，只能等拉流超时 |
| A-4 | 显式 `setProtocolV311()` | 💡 建议 | 现在走库默认 v3.1；零风险补齐。**但不要改投 MQTT 5**（见 0.2 第 15 条，需换包） |
| A-5 | `isDefault` 自动选中默认机器 | 💡 建议 | 目前登录后必须手点机器才生效；若后端会返回 `isDefault`，可补自动选中 |

> **调试前必读**：`useRealBackend` 默认 **false**。接真机调试必须在「联调设置」里打开「真实后端」，
> 或出包时带 `--dart-define=USE_REAL_BACKEND=true`。**不开就是 Mock，什么都连不上。**

### 1.2 摄像头端

| # | 事项 | 状态 |
|---|---|---|
| C-1 | 确认**心跳容忍**：继续忽略非 `action` 字段的帧 | ❓ 未回报 |
| C-2 | 加 **90s 看门狗**（无续租自动停推） | ❓ 未回报 |
| C-3 | 固件加 **token 默认值**（`lunyee-cnc-relay-7k2p`） | 💡 建议（它自己在考虑） |
| C-4 | 设备码目前**硬编码三处** → 量产须改 NVS / 自注册 | 📅 量产前 |
| C-5 | **认知纠正**：「`cnc-demo-03` 在 `app-demo` 枚举白名单内」已过时 | ⚠️ 需同步 |

> C-5 的准确说法：`app-demo` 已于 2026-08-30 13:35 改为**通配** `cnc/+/...` 并上线。
> **任意新增设备码都已放行**，不是"03 正好在名单里"。结论对但理由错，会在讨论新机器时误导判断。

### 1.3 MQTT / broker 端

| # | 事项 | 状态 |
|---|---|---|
| M-1 | 确认 `cam-cnc-demo-01` 客户端是否已自动消失（重刷后应掉线），如还在请清理 | ⏳ |
| M-2 | **预备项**：若 0.3 查出是 `cnc-demo-01`，需确认 `cam-cnc-demo-01` 账号是否仍在、密码是否 `demo123`（仓库 `users.json` 里已无此账号） | ⏳ 待 0.3 结论 |
| M-3 | 仓库 `docker-compose.cloud.yml` **和** `docker-compose.emqx.yml` 的 `DENY_ACTION` 改为 `ignore`（对齐线上） | ⏳ |
| M-4 | 把 `svc-bridge-aliyun-api` 的密码**通过单独安全渠道**给用户（不要发群/仓库） | ⏳ |

### 1.4 阿里云 / PC 工程师

| # | 事项 | 状态 |
|---|---|---|
| P-1 | 🔴 **决定性**：`GET /api/machine/list` 里 `3020 Nova` 的 **`code`** 是 `cnc-demo-03` 还是 `cnc-demo-01` | ❓ **未回** |
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
P-1（后端 code 是 01 还是 03）   ← 唯一的硬分叉
   ├─ 若 = cnc-demo-03 ──→ 现状即正确，直接联调
   └─ 若 = cnc-demo-01 ──→ ① 摄像头端切回 01
                            ② MQTT 确认/补建 cam-cnc-demo-01 账号
                            ③ 重新端到端验证

M-4（取密码） → P-4（云网关切 svc-bridge）   ← 安全项，独立并行
M-3（仓库对齐 ignore）                        ← 独立并行，务必方向正确
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

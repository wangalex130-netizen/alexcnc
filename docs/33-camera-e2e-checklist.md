# 摄像头按需推流 · 各端落地清单（E2E Checklist）

> 目标流（已与 Gordon 对齐，正确）：
> **登录 → App 读阿里云账户 + 机器码（机器码 = 摄像头 ID）→ 点播放 → App 经 MQTT 向 `cnc/<机器码>/cmd` 下发 `stream_start` → 摄像头开始推流到中继 → 中继转发 MJPEG 到 App → 退出即 `stream_stop` 停推**。
>
> 原则：**按需推流**（不 24/7 常推），解决传感器/Wi-Fi 常满负荷发热老化、带宽浪费、隐私暴露。
> 五端全部由本项目（AI）负责：阿里云 037123.xyz（数据）、EMQX HK broker（MQTT）、relay.py（中继）、esp32s3-cam（固件）、alexcnc（App）。

---

## 一、分工总表

| 端 | 负责人 | 状态 | 本轮要做的事 |
|---|---|---|---|
| ① 阿里云 037123.xyz | **pc 工程师（Myers）** | ⚠️ 量产待做 / demo 可跳过 | 实现 `/api/auth/stream` 按账号绑定鉴权（demo 期不必；见 §二） |
| ② MQTT broker（EMQX HK） | **本项目（AI/运维）** | ✅ demo 已放行 / ⚠️ 量产待加 | app-demo→cnc-demo-0X/cmd 已放行（第 5 行）；生产加 `app-<userId>` 正则（见 §三） |
| ③ 中继 relay.py（北京/HK） | **本项目（AI）** | ✅ 框架已就绪 | 部署时开 `REQUIRE_BINDING=1`（见 §四步骤） |
| ④ 摄像头固件 esp32s3-cam | **本项目（AI）** | ✅ 本轮已改 | 补 `online`/`streaming` 状态发布（见 §五） |
| ⑤ App alexcnc | **本项目（AI）** | ✅ 本轮已改 | 拉流带 `user` + 未登录拦截（见 §六） |

---

## 二、① 阿里云 037123.xyz 要做的事（⬇️ 可直接转发给 pc 工程师）

> 中继 `relay.py` 已预留对接点：`BIND_AUTH_URL = https://037123.xyz/api/auth/stream`，
> 打开 `REQUIRE_BINDING=1` 后，每次 App 拉流/截图，中继都会调这个接口校验「这个用户有没有绑定这台设备」。
> **阿里云只差把这个接口实现出来**，鉴权逻辑（账户→设备绑定关系）你们已有（`/api/machine/list`）。
>
> ⚠️ **是否必须做？**
> - **Demo 期（当前）：可跳过。** `REQUIRE_BINDING=0` 时中继 fail-open，演示机本就公开，接口不上线也能拉。
> - **量产期：必须做**——除非改成「登录下发 per-account relay token」替代写死共享 token（见 §二可选增强）。
>   理由：App 登录+设备列表只是**客户端侧**绑定（只管 UI），中继是公网服务器、唯一闸门是写进 APK 的共享 token，
>   任何人反编译 APK 拿到 token 后直连中继即可拉任意设备流，App 的 UI 过滤被完全绕过。中继层必须有自己的服务端鉴权。
> - **上线顺序铁律**：先上 `/api/auth/stream`，再翻 `REQUIRE_BINDING=1`。顺序反了（先翻开关后端没好）→ 中继 fail-closed，**全员拉不到流**。

**需求原文（转发用）：**

```
【摄像头拉流鉴权接口】
GET /api/auth/stream
Query 参数：
  device : 机器码（同时也是摄像头 ID，同一字符串，如 cnc-demo-01）
  user   : App 登录用户的 userId（即 MQTT clientId 去掉 "app-" 前缀）
鉴权逻辑：
  查该 user 的账户下是否绑定了 device 这台机器（复用 /api/machine/list 的绑定关系）
  - 已绑定 -> 返回 HTTP 200
  - 未绑定 -> 返回 HTTP 403
请求头：Bearer <登录 token>（与现有 /api/auth/* 一致）
超时：中继侧 3s；接口请控制在 200ms 内返回
备注：
  - 摄像头 device_id = 机器码，已在「量产统一机器码」决策定稿，无需新字段。
  - 中继调用时 user 来自 App 拉流 URL 的 ?user= 参数（App 已透传 AppConfig.appUserId）。
  - 现有 /api/machine/list 返回的 code 字段即机器码，App 已用其拼流地址，无需改动返回结构。
```

**可选增强（量产前，非阻塞）：** 登录接口 `/api/auth/android/login` 下发的机器信息中携带**按账号签发的 relay token**（替代 App 写死的共享 token）。当前共享 token + 上面的绑定校验已能满足「未绑定拒绝拉流」，token 按账号签发是后续防共享 token 泄露的加固。

---

## 三、② MQTT broker（EMQX HK 43.154.192.242）要做的事

摄像头订阅 `cnc/<device>/cmd`（`cam-<device>` 客户端）；App 以 `app-<userId>` 客户端 PUBLISH 启停命令。

**现状核实（2026-08-28，基于工程师提供的最新 acl.conf）：**
- ✅ 第 5 行 `app-demo` 的 publish 列表**已含** `cnc/cnc-demo-01/cmd`、`cnc/cnc-demo-02/cmd`、`cnc/cnc-demo-03/cmd`。
  即：用 `app-demo` 联调 `cnc-demo-01` 时，摄像头**已经能收到** `stream_start`，**无需改 ACL 即可测**。
- ✅ 第 6 行 `app-demo` 的 subscribe 列表已含 `cnc/cnc-demo-01/status`（及 notify/telemetry/job/sys 等），
  固件 §五 发的 `online`/`streaming` 状态 App 订阅得到。
- ❌ 生产模式 `app-<userId>`（按真实 userId 动态 clientId）**没有**对应规则，仅字面放了 `app-demo`。
  上轮 checklist 称「缺 `cnc/<id>/cmd` 放行」是**看漏了 demo 字面量**，在此更正。

**生产要加（mirror 第 29 行 cam 正则，贴到 `deny, all.` 之前）：**

```erlang
%%% App 客户端（终局方案 2026-08-28：clientId=android-<deviceId>，命令直发 cnc/+/cmd）
{allow, {username, {re, "^app-[a-z0-9-]+$"}}, publish, ["cnc/+/cmd"]}.
{allow, {username, {re, "^app-[a-z0-9-]+$"}}, subscribe, ["cnc/+/status", "cnc/+/notify", "cnc/+/telemetry", "cnc/+/log", "cnc/+/job", "cnc/+/sys", "cnc/broadcast/#"]}.
```

> **2026-08-28 变更说明**：`gw/+/cmd` 与 `gw/+/ack` 已从规则中移除（网关转发废弃），
> 心跳 `{"cmd":"hello"}` 现经 `cnc/+/cmd` 下发，故该主题必须允许 App PUBLISH。
> ACL 主体仍按 `username` 正则，不依赖 `${clientid}`，因此带前缀的
> `android-<deviceId>` 不会导致匹配失败。

> ⚠️ 跨租户风险：`cnc/+/cmd` 通配允许任意 app 用户给**任意设备**发 cmd（含非法开启他人摄像头）。
> demo 无所谓；**量产须改为按绑定关系下发的 ACL**（EMQX HTTP authz webhook 接 037123 `/api/auth/stream` 同一套绑定），否则不能封板。

> 摄像头 `cam-<device>` 的发布/订阅权限保持现状（第 29–30 行）即可。LWT 可选。

---

## 四、③ 中继 relay.py 部署步骤（AI 负责）

框架已就绪（`_binding_allowed` + `REQUIRE_BINDING` + `BIND_AUTH_URL` 已写）。
- **Demo 期（当前）：** `REQUIRE_BINDING=0`（默认），`cnc-demo-01` + `lunyee-cnc-relay-7k2p` 放行，所有人可拉演示流。
- **量产前：** 启动 relay 时设环境变量 `REQUIRE_BINDING=1`，对接阿里云 §二 接口生效。
- **摄像头推流端（/publish）加固（可选，量产前）：** 增加 device↔token 绑定校验，防别设备冒用 token 推流。当前仅校验 token。
- 北京 `39.106.144.53:8080` 与 HK `43.154.192.242:8080` 同源部署，HK 为蜂窝网拉流出口。

---

## 五、④ 摄像头固件 esp32s3-cam（本轮已改 ✅）

`cam_mqtt.c` 本轮新增：
- 订阅 `cnc/<device>/cmd`，`stream_start`/`stream_stop` 控制 WAN 推流（**原有已实现**）。
- **新增状态发布**（本轮）：
  - MQTT 连上 → 发 `{"online":true}` 到 `cnc/<device>/status`
  - 收到 `stream_start` → 发 `{"streaming":true}`
  - 收到 `stream_stop` → 发 `{"streaming":false}`
- 默认模型已是「上电只连 MQTT 控制通道、等 stream_start 才推」（按需推流，解决老化顾虑）。需确认 demo 机 `cnc-demo-01` 当前烧录为按需模型而非常推。

---

## 六、⑤ App alexcnc（本轮已改 ✅）

- `machines_service.dart`：`streamUrl(token, [userId])` 拉流地址透传 `?user=<userId>`（对接中继绑定鉴权）。
- `fullscreen_preview_page.dart`：
  - 进入/自动播放 → 经 MQTT 发 `stream_start` 到 `cnc/<机器码>/cmd`；退出 → 发 `stream_stop`（**上轮已实现**）。
  - 右上状态药丸「启动中 / 已连接 / 无信号」由 MJPEG 帧到达驱动；固件 §五 发 `streaming` 状态后可升级为订阅 `cnc/<device>/status` 精确指示（下一步）。
  - **本轮新增：** 真实后端模式（`useRealBackend=true`）下，未登录/未选机器**不拉硬编码演示流、不发启停命令**，显示「请先登录并选择绑定机器」；demo 模式保留兜底默认地址联调。
- `config.dart`：token `lunyee-cnc-relay-7k2p`、device `cnc-demo-01` 仍为 demo 默认值；量产前改为后端下发（见 §二可选增强）。

---

## 七、演示联调验证顺序（demo 期）

1. 确认 `cnc-demo-01` 摄像头固件为按需模型 + 已烧入本轮状态发布。
2. HK broker acl.conf 加 §三 片段并 `docker restart`。
3. App 装本轮新包：点机器 → 预览 → 应发 `stream_start` → 摄像头推流 → 中继转发 → App 出画面（demo 未登录也能看，因 `REQUIRE_BINDING=0`）。
4. 退出预览 → 发 `stream_stop` → 摄像头停推（验证按需/老化模型）。
5. 量产前：阿里云上线 §二 接口 → relay 设 `REQUIRE_BINDING=1` → 未绑定账户拉流返回 403。

## 八、Q1 安全复核结论（2026-08-28 工程师第 3 轮）

工程师两点：① 随机 12 位设备 ID 下，"A 拉 B 摄像头"需先知道 B 的 ID，评估该风险可行性；② 中继 token 能否由 App 登录后凭 user+设备列表本地生成含 `devices:[...]` 的 token。

**① 风险可行性（结论：穷举不可行，但 ID 在本架构下不保密，不能作唯一防线）**
- 12 位随机字母数字 ≈ 62^12 ≈ 3.2e21，暴力猜 ID 不可行（工程师此点正确）。
- 但安全不能建立在 ID 保密上（违反 Kerckhoffs），本架构 ID 非秘密，有两条披露路径：
  - **共享 token 写在 APK**（`relay.py:31` 默认 `lunyee-cnc-relay-7k2p`；App `config.dart:34` 同值）。反编译 APK 即提取 → 任何人持共享 token，只差任意有效 deviceId。
  - **MQTT 通配订阅泄露 ID**：§三 生产 acl 片段 subscribe 含 `cnc/+/status` 通配 → 任意 App 订阅即收到全量 `online`/`streaming` 广播，deviceId 直接暴露在 topic 路径。恶意 App 一订阅即 harvest 全量 ID。
  - ID 还见于 App 机器列表 UI / 绑定表 / broadcast topic —— 它是标识符非能力密钥。
- 结论：保留随机 ID（防穷举很好），但**真正控制权放 token scope + MQTT ACL scope，不在 ID 保密**。demo/单信任域可接受；量产 B2C 多租户不可接受。

**② App 本地生成 devices token（结论：方向对，但"本地签名"致命，须服务端签发）**
- 设备级作用域 token 确实能跳过 `/api/auth/stream` 回调（中继本地验 scope，无状态）——方向正确。
- 但若 token 由 App 本地签名（HMAC/签名密钥在 APK）→ 攻击者提取同密钥 → 伪造任意 devices 列表 → 安全归零且更隐蔽。**"App 算签名"不行。**
- 正确做法（docs/33 §二 path B）：`037123` 登录响应或新 `/api/relay/token` 返回**服务端签发 JWT**，claims=`{sub:userId, devices:[cnc-xx,...]}`；App 透传塞 `?token=`。中继 `relay.py` 用**公钥**验签 + 校验"本次设备 ∈ devices[]"。语义是"服务器签发、App 透传"，非"App 生成"。
- 中继落地改动（本项目负责）：`_ok_token` 从"==共享串"扩成 JWT 验签 + devices 包含该 device（PyJWT + 公钥，约 15 行）；`REQUIRE_BINDING` 回调可作兜底。
- **仍须补**：MQTT ACL 也要设备级（`cnc/<自己设备>/cmd`、`cnc/<自己设备>/status`），不能 `cnc/+/cmd` 通配，否则恶意 App 仍能开/订阅他人设备（即 §三 webhook 方案）。

## 九、测试期风险接受 + 量产前加强方案（2026-08-28 决策）

工程决策：本批以共享 `app-demo` 推进测试。在以下三前提**同时成立**时，测试期可接受忽略越权风险：
- **(A)** deviceID 为 12 位随机（抗穷举 ≈ 62^12）；
- **(B)** ACL **不配置 wildcard**（即 `cnc/<具体设备>/cmd`、`cnc/<具体设备>/status`，不出现 `cnc/+`）；
- **(C)** 假定 App 不可被破解（共享 token 不泄露）。
在此前提下：攻击者既无法猜 ID(A)、也无法经 MQTT 通配订阅 harvest ID(B)、也无法取共享 token(C) → 越权所需"token+特定 ID"二者不可兼得；测试期设备少、同信任域，风险可忽略。
⚠️ **唯一承重假设是 (C)**。一旦 (C) 破（规模上线/真实产品必然面临），仍有 (A)(B) 兜底，但"共享 token + 已知 ID = 全权限"，故量产前**必须**移除共享 token（见 P0）。

### 9.1 量产前加强方案（按优先级）

**P0 — 去共享 token（根治 (C) 破防，本项目负责）**
1. `037123` 登录回包或新增 `GET /api/relay/token` 签发**设备级作用域 JWT**（claims `{sub:userId, devices:[cnc-xx,...]}`，建议短时效可轮换）；
2. App `cameraRelayToken` 改为登录后接 `relayToken`，不再写死（`config.dart:34`）；
3. `relay.py` `_ok_token` 改为 JWT 验签 + 校验"本次请求设备 ∈ devices[]"（PyJWT + 公钥，约 15 行）；`REQUIRE_BINDING` 回调保留作兜底。
   → 效果：即便 App 被破解，攻击者只拿到自己账号名下 devices 的 token，无法跨设备。

**P1 — MQTT ACL 设备级 + 动态（根治通配/共享用户名）**
4. 弃用固定 `app-demo` 共享用户名 → 每 App 用 `app-<userId>`（clientId 已支持）；
5. EMQX **HTTP authz webhook** 调 `037123` 绑定关系，按 `user↔device` 动态 allow/deny 每次 publish/subscribe（与 `/api/auth/stream` 同源数据）；
6. acl 文件留最小通配或置空，隔离由 webhook 保证，零运维、随用户扩展。
   → 效果：规模上线新增用户零 acl 改动；任意 App 只能 cmd/subscribe 自己绑定设备。

**P2 — 规模/异常**
7. relay 限流：每 token 并发拉流数、每 IP QPS；异常拉流告警；
8. relay 审计日志：who(用户) pull which(device) when，供事后溯源；
9. 固件保持按需推流（已落地），缩小暴露窗口；
10. 设备 ID 仅作标识符（不依赖其保密）；密钥/令牌一律服务端签发、客户端不落长期密钥。

### 9.2 测试期须守住的红线
- ACL **严禁再加** `cnc/`、`gw/` 类 wildcard（一旦加，9 (B) 失效、ID 重泄露）；
- 共享 token 仅测试期使用，出 P0 前不得用于任何面向客户的包；
- 测试设备数保持小、同信任域（不混入外部客户）。
